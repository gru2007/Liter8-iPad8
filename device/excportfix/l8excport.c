/*
 * l8excport.dylib - keeps apps alive when every binary runs with platform trust.
 *
 * WHY THIS EXISTS.
 * The PPL trust-cache patch makes every CDHash lookup succeed, so every binary, App
 * Store apps included, gets trust level 9 and the kernel sets TFRO_PLATFORM on its task.
 * Crash reports show it as codeSigningTrustLevel 9, codeSigningValidationCategory 1 and
 * is_first_party 1. ipc_policy_for_task() then gives the task IPC_SPACE_POLICY_PLATFORM
 * plus IPC_POLICY_ENHANCED_V2, and set_exception_behavior_allowed()
 * (osfmk/kern/ipc_tt.c) only lets such a task install an exception handler whose
 * behavior is EXCEPTION_STATE, EXCEPTION_IDENTITY_PROTECTED or
 * EXCEPTION_STATE_IDENTITY_PROTECTED. Third-party crash reporters (Meta's, KSCrash,
 * PLCrashReporter, Sentry, ...) ask for EXCEPTION_DEFAULT or EXCEPTION_STATE_IDENTITY,
 * and the kernel answers with EXC_GUARD / GUARD_TYPE_MACH_PORT / SET_EXCEPTION_BEHAVIOR.
 * Facebook 581 dies that way in METARunPreApplicationMain, before UIApplicationMain.
 *
 * WHAT IT DOES.
 * A call the kernel would refuse is not forwarded. The set variants return KERN_SUCCESS
 * and change nothing; the swap variants report the current handlers, exactly as a
 * successful swap would, and also change nothing. The app's own crash reporter is
 * therefore off and crashes go to ReportCrash like any system process. Everything the
 * kernel accepts passes through untouched, and so does anything it would reject for a
 * different reason (bad mask, bad flavor, missing MACH_EXCEPTION_CODES).
 *
 * Downgrading the behavior instead would keep the handler installed, but the handler
 * would then receive a message layout it was not written for. Handlers that parse the
 * raw message rather than going through mach_exc_server() would misread it in the middle
 * of a crash. Not installing them is the predictable choice.
 *
 * WHY GOT REBINDING AND NOT MSHookFunction OR DYLD_INTERPOSE.
 * Patching __TEXT dies with CODESIGNING / Invalid Page here (see launchdhook/lhook.c),
 * and ElleKit's TweakLoader dlopen()s tweaks, which dyld does not honour __interpose
 * for. So the symbol pointers (__got, __auth_got, __la_symbol_ptr) of every image
 * outside the shared cache are rewritten instead: data pages only, nothing executable
 * changes. Images loaded later are handled through _dyld_register_func_for_add_image().
 * The shared cache is left alone: Apple's own code already uses the hardened behaviors.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

/* Older SDKs lack some of these. Values are from osfmk/mach/exception_types.h and
 * EXTERNAL_HEADERS/mach-o/loader.h. */
#ifndef EXCEPTION_IDENTITY_PROTECTED
#define EXCEPTION_IDENTITY_PROTECTED 4
#endif
#ifndef EXCEPTION_STATE_IDENTITY_PROTECTED
#define EXCEPTION_STATE_IDENTITY_PROTECTED 5
#endif
#ifndef MACH_EXCEPTION_ERRORS
#define MACH_EXCEPTION_ERRORS 0x40000000
#endif
#ifndef MACH_EXCEPTION_BACKTRACE_PREFERRED
#define MACH_EXCEPTION_BACKTRACE_PREFERRED 0x20000000
#endif
#define L8_EXCEPTION_FLAGS \
    (MACH_EXCEPTION_CODES | MACH_EXCEPTION_ERRORS | MACH_EXCEPTION_BACKTRACE_PREFERRED)
#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000
#endif

/* A process holding this entitlement may set any behavior, so it is left alone. */
#define SET_EXCEPTION_ENTITLEMENT "com.apple.private.set-exception-port"

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
                                                CFErrorRef *error);

typedef kern_return_t (*set_ports_fn)(mach_port_t, exception_mask_t, mach_port_t,
                                      exception_behavior_t, thread_state_flavor_t);
typedef kern_return_t (*swap_ports_fn)(mach_port_t, exception_mask_t, mach_port_t,
                                       exception_behavior_t, thread_state_flavor_t,
                                       exception_mask_array_t, mach_msg_type_number_t *,
                                       exception_handler_array_t, exception_behavior_array_t,
                                       exception_flavor_array_t);
typedef kern_return_t (*get_ports_fn)(mach_port_t, exception_mask_t, exception_mask_array_t,
                                      mach_msg_type_number_t *, exception_handler_array_t,
                                      exception_behavior_array_t, exception_flavor_array_t);

static set_ports_fn real_task_set;
static set_ports_fn real_thread_set;
static swap_ports_fn real_task_swap;
static swap_ports_fn real_thread_swap;
static get_ports_fn real_task_get;
static get_ports_fn real_thread_get;

static os_log_t log_handle(void)
{
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.liter8.excport", "shim");
    });
    return handle;
}

/* Mirrors behavior_is_identity_protected() for the two behaviors that fail it. Anything
 * else, including behaviors the kernel rejects as invalid, goes to the kernel so the
 * caller sees the kernel's own answer. */
static bool kernel_would_refuse(mach_port_t port, exception_behavior_t behavior)
{
    if (!MACH_PORT_VALID(port)) {
        return false;
    }
    switch (behavior & ~L8_EXCEPTION_FLAGS) {
    case EXCEPTION_DEFAULT:
    case EXCEPTION_STATE_IDENTITY:
        return true;
    default:
        return false;
    }
}

static void note_dropped(const char *call, exception_mask_t mask, exception_behavior_t behavior)
{
    os_log(log_handle(), "dropped %{public}s mask=0x%x behavior=0x%x", call,
           (unsigned)mask, (unsigned)behavior);
}

static kern_return_t l8_task_set_exception_ports(mach_port_t task, exception_mask_t mask,
                                                 mach_port_t port, exception_behavior_t behavior,
                                                 thread_state_flavor_t flavor)
{
    if (kernel_would_refuse(port, behavior)) {
        note_dropped("task_set_exception_ports", mask, behavior);
        return KERN_SUCCESS;
    }
    return real_task_set(task, mask, port, behavior, flavor);
}

static kern_return_t l8_thread_set_exception_ports(mach_port_t thread, exception_mask_t mask,
                                                   mach_port_t port,
                                                   exception_behavior_t behavior,
                                                   thread_state_flavor_t flavor)
{
    if (kernel_would_refuse(port, behavior)) {
        note_dropped("thread_set_exception_ports", mask, behavior);
        return KERN_SUCCESS;
    }
    return real_thread_set(thread, mask, port, behavior, flavor);
}

static kern_return_t l8_task_swap_exception_ports(
    mach_port_t task, exception_mask_t mask, mach_port_t port, exception_behavior_t behavior,
    thread_state_flavor_t flavor, exception_mask_array_t masks, mach_msg_type_number_t *count,
    exception_handler_array_t handlers, exception_behavior_array_t behaviors,
    exception_flavor_array_t flavors)
{
    if (kernel_would_refuse(port, behavior)) {
        note_dropped("task_swap_exception_ports", mask, behavior);
        return real_task_get(task, mask, masks, count, handlers, behaviors, flavors);
    }
    return real_task_swap(task, mask, port, behavior, flavor, masks, count, handlers, behaviors,
                          flavors);
}

static kern_return_t l8_thread_swap_exception_ports(
    mach_port_t thread, exception_mask_t mask, mach_port_t port, exception_behavior_t behavior,
    thread_state_flavor_t flavor, exception_mask_array_t masks, mach_msg_type_number_t *count,
    exception_handler_array_t handlers, exception_behavior_array_t behaviors,
    exception_flavor_array_t flavors)
{
    if (kernel_would_refuse(port, behavior)) {
        note_dropped("thread_swap_exception_ports", mask, behavior);
        return real_thread_get(thread, mask, masks, count, handlers, behaviors, flavors);
    }
    return real_thread_swap(thread, mask, port, behavior, flavor, masks, count, handlers,
                            behaviors, flavors);
}

struct target {
    const char *name;     /* without the leading underscore */
    void *replacement;
    void **original;      /* where the real implementation is stored */
};

static struct target targets[] = {
    {"task_set_exception_ports", (void *)l8_task_set_exception_ports, (void **)&real_task_set},
    {"thread_set_exception_ports", (void *)l8_thread_set_exception_ports,
     (void **)&real_thread_set},
    {"task_swap_exception_ports", (void *)l8_task_swap_exception_ports,
     (void **)&real_task_swap},
    {"thread_swap_exception_ports", (void *)l8_thread_swap_exception_ports,
     (void **)&real_thread_swap},
};
#define TARGET_COUNT (sizeof(targets) / sizeof(targets[0]))

static const struct mach_header *self_header;

static void *strip(void *pointer)
{
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_asia);
#else
    return pointer;
#endif
}

/* Writes one pointer-sized slot, making its page writable only for as long as needed.
 * __DATA_CONST and __AUTH_CONST are read-only after dyld has applied fixups. */
static bool write_slot(void **slot, void *value)
{
    mach_port_t self = mach_task_self();
    vm_address_t page = (vm_address_t)slot & ~((vm_address_t)vm_page_size - 1);

    vm_address_t region = (vm_address_t)slot;
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(self, &region, &region_size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &info_count, &object) != KERN_SUCCESS ||
        region > (vm_address_t)slot) {
        return false;
    }

    vm_prot_t original = info.protection;
    if (!(original & VM_PROT_WRITE)) {
        if (vm_protect(self, page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE) !=
                KERN_SUCCESS &&
            vm_protect(self, page, vm_page_size, false,
                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
            return false;
        }
    }

    __atomic_store_n(slot, value, __ATOMIC_RELEASE);

    if (!(original & VM_PROT_WRITE)) {
        (void)vm_protect(self, page, vm_page_size, false, original);
    }
    return true;
}

/* Returns the value to store so the slot calls `target->replacement`, signed the same
 * way the slot's current value is, or NULL when the slot is not one to touch. */
static void *replacement_for(void **slot, const struct target *target, bool lazy)
{
    void *current = *slot;
    void *raw = strip(current);
    void *real = strip(*target->original);
    void *mine = strip(target->replacement);

    if (raw == mine) {
        return NULL; /* already rebound */
    }

#if __has_feature(ptrauth_calls)
    (void)lazy;
    /* arm64e has no lazy binding, so the slot must already hold the real function.
     * Anything else was bound elsewhere on purpose and is left as is. The signing
     * scheme is then learned from the slot itself rather than assumed: __auth_got
     * entries are IA with address diversity, plain __got entries are unsigned. */
    if (raw != real) {
        return NULL;
    }
    if (current == raw) {
        return mine;
    }
    if (current == ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, slot)) {
        return ptrauth_sign_unauthenticated(mine, ptrauth_key_asia, slot);
    }
    if (current == ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, 0)) {
        return ptrauth_sign_unauthenticated(mine, ptrauth_key_asia, 0);
    }
    os_log_error(log_handle(), "unknown pointer signing for %{public}s, slot left alone",
                 target->name);
    return NULL;
#else
    /* An unbound lazy pointer still points at the stub helper, and binding it later
     * would overwrite us, so it is pre-bound to the replacement. */
    if (raw != real && !lazy) {
        return NULL;
    }
    return mine;
#endif
}

static void rebind_section(const struct section_64 *section, intptr_t slide,
                           const struct nlist_64 *symbols, uint32_t symbol_count,
                           const char *strings, uint32_t string_size,
                           const uint32_t *indirect, uint32_t indirect_count)
{
    uint32_t type = section->flags & SECTION_TYPE;
    if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) {
        return;
    }
    bool lazy = type == S_LAZY_SYMBOL_POINTERS;

    void **slots = (void **)((uintptr_t)slide + section->addr);
    uint64_t count = section->size / sizeof(void *);
    for (uint64_t i = 0; i < count; i++) {
        uint64_t at = (uint64_t)section->reserved1 + i;
        if (at >= indirect_count) {
            return;
        }
        uint32_t symbol = indirect[at];
        if (symbol & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL) || symbol >= symbol_count) {
            continue;
        }
        uint32_t offset = symbols[symbol].n_un.n_strx;
        if (offset >= string_size || strings[offset] != '_') {
            continue;
        }
        const char *name = strings + offset + 1;

        for (size_t t = 0; t < TARGET_COUNT; t++) {
            if (!*targets[t].original || strcmp(name, targets[t].name) != 0) {
                continue;
            }
            void *value = replacement_for(&slots[i], &targets[t], lazy);
            if (value && !write_slot(&slots[i], value)) {
                os_log_error(log_handle(), "could not write the %{public}s slot",
                             targets[t].name);
            }
            break;
        }
    }
}

static void rebind_image(const struct mach_header *header, intptr_t slide)
{
    if (header == self_header || header->magic != MH_MAGIC_64 ||
        (header->flags & MH_DYLIB_IN_CACHE)) {
        return;
    }

    const struct mach_header_64 *image = (const struct mach_header_64 *)header;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const uint8_t *cursor = (const uint8_t *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64 &&
            strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)command;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
        cursor += command->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab || dysymtab->nindirectsyms == 0) {
        return;
    }

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    cursor = (const uint8_t *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            const struct section_64 *sections = (const struct section_64 *)(segment + 1);
            for (uint32_t s = 0; s < segment->nsects; s++) {
                rebind_section(&sections[s], slide, symbols, symtab->nsyms, strings,
                               symtab->strsize, indirect, dysymtab->nindirectsyms);
            }
        }
        cursor += command->cmdsize;
    }
}

static bool may_set_any_behavior(void)
{
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        return false;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR(SET_EXCEPTION_ENTITLEMENT), NULL);
    bool entitled = value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                    CFBooleanGetValue((CFBooleanRef)value);
    if (value) {
        CFRelease(value);
    }
    CFRelease(task);
    return entitled;
}

__attribute__((constructor)) static void l8excport_init(void)
{
    if (may_set_any_behavior()) {
        os_log(log_handle(), "process is entitled to set exception ports, not shimming");
        return;
    }

    Dl_info self;
    if (dladdr((const void *)l8excport_init, &self) && self.dli_fbase) {
        self_header = (const struct mach_header *)self.dli_fbase;
    }

    real_task_get = (get_ports_fn)dlsym(RTLD_DEFAULT, "task_get_exception_ports");
    real_thread_get = (get_ports_fn)dlsym(RTLD_DEFAULT, "thread_get_exception_ports");
    for (size_t t = 0; t < TARGET_COUNT; t++) {
        *targets[t].original = dlsym(RTLD_DEFAULT, targets[t].name);
    }
    /* The swap fallbacks need the matching get. Without it the swap stays unhooked. */
    if (!real_task_get) {
        real_task_swap = NULL;
    }
    if (!real_thread_get) {
        real_thread_swap = NULL;
    }

    /* Runs for every image already loaded, then for each one loaded later. */
    _dyld_register_func_for_add_image(rebind_image);
}
