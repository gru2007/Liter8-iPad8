// csprobe - does the kernel let a running process modify its own code?
//
// This is the exact operation a runtime function hook performs (ElleKit's
// MSHookFunction): make an executable page writable, overwrite an instruction,
// and run it. On a stock A12/T8020 boot the process is killed with
// CODESIGNING / Invalid Page. With the code-signing-invalid kernel patches
// (kernel boot-jit) it should succeed.
//
//   stage 1  vm_protect RWX (copy-on-write) -> fails if vm_map_protect refuses
//                                              write+execute
//   stage 2  overwrite the instruction      -> the next instruction fetched
//                                              from that page is validated
//   stage 3  vm_protect back to RX          -> fails if new exec is refused
//   stage 4  execute the modified function  -> killed if vm_fault_enter and
//                                              the PPL allow-invalid patch
//                                              are missing
//
// Stage 1 asks for RWX in one step, as hooks do, rather than RW then RX: if
// main() shares the page with probe_target, an RW-only page would kill main
// itself on its next instruction and say nothing about the kernel.
//
// Output is unbuffered so the last line printed before a kill survives SSH.
// Run it on the booted device while watching the kernel log on the Mac:
//
//   idevicesyslog | grep -iE "CODE ?SIGNING|Invalid Page|cs_invalid|pmap"
//
// "[csprobe] PASS" means self-modified code ran. No entitlement is used: the
// point is to measure what a stock process is allowed to do.
//
// Build: device/csprobe/build.sh (ad-hoc, no get-task-allow).

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

// Returns 0x11. Its first two instructions are replaced so that a correctly
// executed patch is visible in the return value instead of being inferred.
__attribute__((noinline, aligned(16)))
static int probe_target(void) {
    return 0x11;
}

// mov w0, #0x22 ; ret
static const uint32_t kReplacement[2] = { 0x52800440u, 0xD65F03C0u };

// The code address of probe_target, without the arm64e pointer signature.
static void *code_address(void) {
    void *fn = (void *)probe_target;
#if __has_feature(ptrauth_calls)
    fn = ptrauth_strip(fn, ptrauth_key_function_pointer);
#endif
    return fn;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[csprobe] pid %d\n", getpid());

    void *fn = code_address();
    uintptr_t page = (uintptr_t)fn & ~((uintptr_t)getpagesize() - 1);
    size_t span = (size_t)getpagesize();
    mach_port_t task = mach_task_self();

    printf("[csprobe] baseline probe_target() = 0x%x (expected 0x11)\n", probe_target());

    kern_return_t kr = vm_protect(task, (vm_address_t)page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY);
    printf("[csprobe] stage1 vm_protect RWX -> %d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL stage1: vm_map_protect refused write+execute\n");
        return 1;
    }

    memcpy(fn, kReplacement, sizeof(kReplacement));
    sys_icache_invalidate(fn, sizeof(kReplacement));
    printf("[csprobe] stage2 instruction rewritten\n");

    kr = vm_protect(task, (vm_address_t)page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    printf("[csprobe] stage3 vm_protect RX -> %d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) {
        printf("[csprobe] FAIL stage3: execute permission refused after the write\n");
        return 1;
    }

    printf("[csprobe] stage4 calling the modified function...\n");
    int patched = probe_target();
    printf("[csprobe] stage4 probe_target() = 0x%x (expected 0x22)\n", patched);
    if (patched == 0x22) {
        printf("[csprobe] PASS: self-modified code executed\n");
        return 0;
    }
    printf("[csprobe] FAIL: the call returned the original value\n");
    return 1;
}
