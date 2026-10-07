// 23H30 SEP-less integration: repair the cached contract inside PosterBoard.
// Avoids a privileged task port and changes no executable pages.
#define main unused_pfruntimeprobe_main
#include "../photoforce/pfruntimeprobe.m"
#undef main
#include <sys/sysctl.h>

__attribute__((constructor)) static void posterfix_start(void) {
    @autoreleasepool {
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"PosterBoard"])
            return;
        char build[64] = {0}; size_t size = sizeof(build);
        if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "23H30"))
            return;
        void *handle = dlopen(kPFPath, RTLD_NOW | RTLD_LOCAL);
        PFValuesFn fn = handle ? (PFValuesFn)dlsym(handle, "PFPosterPathURLResourceValues") : NULL;
        if (!fn) { NSLog(@"Liter8PosterFix: missing contract"); return; }
        NSDictionary *values = fn();
        uintptr_t once = 0, slot = 0;
        if (!resolve_poster_globals(fn, &once, &slot) ||
            *(NSDictionary **)slot != values || *(uint64_t *)once != UINT64_MAX ||
            run_local_mutation_selftest() != 0) {
            NSLog(@"Liter8PosterFix: contract guard failed"); return;
        }
        uint64_t *words = (__bridge void *)values;
        if (malloc_size((__bridge const void *)values) != 0x40 ||
            words[1] != 0x0400000000000002ULL ||
            words[2] != (uintptr_t)NSURLFileProtectionKey ||
            words[3] != (uintptr_t)NSURLFileProtectionNone || words[4] || words[5] ||
            words[6] != (uintptr_t)NSURLIsReadableKey ||
            words[7] != (uintptr_t)[NSNumber numberWithBool:YES]) {
            NSLog(@"Liter8PosterFix: dictionary guard failed"); return;
        }
        // Constructor executes before PosterBoard's main; preserve the readability entry.
        words[1] = 0x0400000000000001ULL;
        words[2] = 0; words[3] = 0;
        BOOL ok = values.count == 1 && [values[NSURLIsReadableKey] isEqual:@YES] &&
                  values[NSURLFileProtectionKey] == nil && fn() == values;
        NSLog(@"Liter8PosterFix: pid=%d cached contract %@", getpid(), ok ? @"PASS" : @"FAIL");
    }
}
