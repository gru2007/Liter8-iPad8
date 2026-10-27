// csprobe - does the kernel let a running process modify its own code?
//
// This is the operation a runtime function hook performs: make an executable
// page writable (a private copy), overwrite an instruction, make the page
// executable again, and run it. On a stock A12/T8020 boot the process is
// killed with CODESIGNING / Invalid Page, or the re-protect is refused. With
// the code-signing-invalid kernel patches (kernel boot-jit) it should succeed.
//
//   stage 1  vm_protect RW + copy-on-write -> a private writable copy
//   stage 2  overwrite the instruction
//   stage 3  vm_protect back to RX         -> fails if execute is refused for
//                                             a page that was written
//   stage 4  execute the modified function -> killed if vm_fault_enter and
//                                             the PPL allow-invalid patch
//                                             are missing
//
// A second test then asks ElleKit itself (MSHookFunction from
// /var/jb/usr/lib/libsubstrate.dylib) to hook another isolated function, the
// way a C-hooking tweak does. It runs even when the raw kernel test fails:
// that is the answer that matters for tweaks.
//
// The target lives alone on its own page (its own section, padded to the page
// size), so making that page RW never touches main() or the stubs. A
// single-step RWX request is tried afterwards for information only: hooks do
// not need it, and a refusal there says nothing about the patches above.
//
// Output is unbuffered so the last line printed before a kill survives SSH.
// Watch the kernel log on the Mac while it runs:
//
//   idevicesyslog | grep -iE "CODE ?SIGNING|Invalid Page|cs_invalid|pmap"
//
// "[csprobe] PASS" means self-modified code ran. No entitlement is used: the
// point is to measure what a stock process is allowed to do.
//
// Build: device/csprobe/build.sh (ad-hoc, no get-task-allow).

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Returns 0x11. Alone on a 16 KB page (the A12 page size, and a multiple of
// 4 KB): the section is page aligned and padded to the next page boundary.
__asm__(
    ".section __TEXT,__csprobe,regular,pure_instructions\n"
    ".p2align 14\n"
    ".globl _csprobe_target\n"
    "_csprobe_target:\n"
    "    mov w0, #0x11\n"
    "    ret\n"
    ".p2align 14\n"
    ".text\n");
extern int csprobe_target(void);

// Second isolated target for the ElleKit test; returns 0x33.
__asm__(
    ".section __TEXT,__csprobe2,regular,pure_instructions\n"
    ".p2align 14\n"
    ".globl _csprobe_hook_target\n"
    "_csprobe_hook_target:\n"
    "    mov w0, #0x33\n"
    "    ret\n"
    ".p2align 14\n"
    ".text\n");
extern int csprobe_hook_target(void);

static int hook_replacement(void) { return 0x44; }

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);

// 0 = hooked and verified, 1 = hook did not take, 2 = ElleKit unavailable.
static int ellekit_test(void) {
    const char *path = "/var/jb/usr/lib/libsubstrate.dylib";
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    MSHookFunction_t hook = handle ? (MSHookFunction_t)dlsym(handle, "MSHookFunction") : NULL;
    if (hook == NULL) {
        printf("[csprobe] ellekit: MSHookFunction unavailable (%s)\n", dlerror());
        return 2;
    }
    printf("[csprobe] ellekit: baseline hook_target() = 0x%x (expected 0x33)\n",
           csprobe_hook_target());
    void *original = NULL;
    printf("[csprobe] ellekit: MSHookFunction...\n");
    hook((void *)csprobe_hook_target, (void *)hook_replacement, &original);
    int value = csprobe_hook_target();
    printf("[csprobe] ellekit: hook_target() = 0x%x (expected 0x44), original=%p\n",
           value, original);
    if (value == 0x44) {
        printf("[csprobe] ellekit PASS: C function hook works\n");
        return 0;
    }
    printf("[csprobe] ellekit FAIL: the hook did not take\n");
    return 1;
}

// mov w0, #0x22 ; ret
static const uint32_t kReplacement[2] = { 0x52800440u, 0xD65F03C0u };

// The code address of the target, without the arm64e pointer signature.
static void *code_address(void) {
    void *fn = (void *)csprobe_target;
#if __has_feature(ptrauth_calls)
    fn = ptrauth_strip(fn, ptrauth_key_function_pointer);
#endif
    return fn;
}

static int kernel_test(void) {
    void *fn = code_address();
    size_t span = (size_t)getpagesize();
    uintptr_t page = (uintptr_t)fn & ~((uintptr_t)span - 1);
    mach_port_t task = mach_task_self();

    printf("[csprobe] baseline target() = 0x%x (expected 0x11), page 0x%lx size %zu\n",
           csprobe_target(), (unsigned long)page, span);
    if ((uintptr_t)fn != page) {
        printf("[csprobe] FAIL setup: target is not page aligned\n");
        return 1;
    }

    kern_return_t kr = vm_protect(task, (vm_address_t)page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    printf("[csprobe] stage1 vm_protect RW|COPY -> %d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL stage1: no writable copy of the code page\n");
        return 1;
    }

    memcpy(fn, kReplacement, sizeof(kReplacement));
    printf("[csprobe] stage2 instruction rewritten\n");

    kr = vm_protect(task, (vm_address_t)page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    printf("[csprobe] stage3 vm_protect RX -> %d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL stage3: execute refused for the written page\n");
        return 1;
    }
    sys_icache_invalidate(fn, sizeof(kReplacement));

    printf("[csprobe] stage4 calling the modified function...\n");
    int patched = csprobe_target();
    printf("[csprobe] stage4 target() = 0x%x (expected 0x22)\n", patched);
    if (patched != 0x22) {
        printf("[csprobe] FAIL: the call returned the original value\n");
        return 1;
    }
    printf("[csprobe] PASS: self-modified code executed\n");

    // Information only; not needed by hooks.
    kr = vm_protect(task, (vm_address_t)page, span, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    printf("[csprobe] info: single-step RWX -> %d (%s)\n", kr, mach_error_string(kr));
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[csprobe] pid %d\n", getpid());
    int kernel = kernel_test();
    int elle = ellekit_test();
    printf("[csprobe] summary: kernel=%s ellekit=%s\n", kernel == 0 ? "PASS" : "FAIL",
           elle == 0 ? "PASS" : elle == 1 ? "FAIL" : "unavailable");
    return kernel == 0 && elle == 0 ? 0 : 1;
}
