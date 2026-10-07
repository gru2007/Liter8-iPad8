// csprobe - does the kernel let a running process modify its own code?
//
// This is the exact operation a runtime function hook performs (ElleKit's
// MSHookFunction): make an executable page writable, overwrite an instruction,
// restore execute, and run it. On a stock A12/T8020 boot the process is killed
// with CODESIGNING / Invalid Page. After the code-signing-invalid kernel
// patches (kernel boot-jit) it should succeed.
//
// It isolates the three layers so a failure says which patch is missing:
//
//   stage 1  vm_protect to RW            -> fails if vm_map_protect blocks RW->?
//   stage 2  write an instruction        -> the store itself
//   stage 3  vm_protect back to RX       -> fails if map_disallow_new_exec bites
//   stage 4  execute the modified code   -> faults/kills if vm_fault_enter +
//                                           PPL allow-invalid are missing
//
// Run it over SSH on the booted device. Watch the kernel log in parallel:
//
//   idevicesyslog | grep -iE "CODE ?SIGNING|csproc|Invalid Page|cs_invalid"
//
// A clean run prints "[csprobe] PASS". A kill before stage 4 completes means
// the matching kernel patch did not take. No entitlement grants this; the
// point is to measure the stock-process case.
//
// Build: device/csprobe/build.sh (ad-hoc, no get-task-allow).

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// A tiny function that returns 0x11. We rewrite its first instruction to
// return 0x22 instead, so a correct, executed patch is observable in the
// return value rather than inferred.
__attribute__((noinline, aligned(16)))
static int probe_target(void) {
    return 0x11;
}

// mov w0, #0x22 ; ret  — what we write over the prologue.
static const uint32_t kReplacement[2] = { 0x52800440u, 0xD65F03C0u };

int main(void) {
    printf("[csprobe] pid %d\n", getpid());

    void *fn = (void *)probe_target;
    // Page containing the function; vm_protect works on page granularity.
    uintptr_t page = (uintptr_t)fn & ~((uintptr_t)getpagesize() - 1);
    size_t span = (size_t)getpagesize();
    mach_port_t task = mach_task_self();

    int baseline = probe_target();
    printf("[csprobe] baseline probe_target() = 0x%x\n", baseline);

    // Stage 1: make the code page writable (copy-on-write).
    kern_return_t kr = vm_protect(task, (vm_address_t)page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    printf("[csprobe] stage1 vm_protect RW -> %d (%s)\n", kr,
           kr == KERN_SUCCESS ? "ok" : mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL at stage1 (vm_map_protect blocks write on code)\n");
        return 1;
    }

    // Stage 2: overwrite the prologue.
    memcpy(fn, kReplacement, sizeof(kReplacement));
    printf("[csprobe] stage2 wrote replacement instructions\n");

    // Stage 3: restore execute. This is where map_disallow_new_exec bites.
    kr = vm_protect(task, (vm_address_t)page, span, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    printf("[csprobe] stage3 vm_protect RX -> %d (%s)\n", kr,
           kr == KERN_SUCCESS ? "ok" : mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL at stage3 (map_disallow_new_exec / RX refused)\n");
        return 1;
    }

    // Keep the instruction cache coherent with the write before executing.
    sys_icache_invalidate(fn, sizeof(kReplacement));

    // Stage 4: execute. If vm_fault_enter flags the modified page, or PPL
    // rejects it on A12, the process is killed here rather than returning.
    printf("[csprobe] stage4 calling modified probe_target()...\n");
    fflush(stdout);
    int patched = probe_target();
    printf("[csprobe] stage4 probe_target() = 0x%x (expected 0x22)\n", patched);

    if (patched == 0x22) {
        printf("[csprobe] PASS: self-modified code executed\n");
        return 0;
    }
    printf("[csprobe] FAIL: executed but returned the old value\n");
    return 1;
}
