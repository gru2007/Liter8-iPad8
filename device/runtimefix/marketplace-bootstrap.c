/* System-volume entry point. No jailbreak library is a dyld dependency:
 * dyld must be able to map this image before its constructor obtains access
 * to the Data-volume bootstrap. */
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <os/log.h>
#include <stdio.h>
#include <mach-o/dyld.h>

#define TOKEN_ENV "LITER8_SANDBOX_READ_TOKEN"
#define BRIDGE "/var/jb/usr/lib/Liter8SpawnBridge.dylib"
#define LOADER "/var/jb/usr/lib/TweakLoader.dylib"

/* Same six-domain behavior as installed aintuitweaks (function at 0x40fc).
 * Binding-time interposition avoids its unavailable MSHookFunction text patch.
 * Other domains retain the native implementation and all five arguments. */
extern int os_eligibility_get_domain_answer(uint64_t,uint64_t*,uint64_t*,void**,void**);
static int eligibility_answer(uint64_t domain,uint64_t *answer,uint64_t *source,void **status,void **context) {
    if(domain<=20 && ((UINT64_C(0x18009c)>>domain)&1)) {
        if(answer)*answer=4;
        if(source)*source=2;
        os_log_error(OS_LOG_DEFAULT,"Liter8Marketplace: eligibility domain=%llu answer=4",(unsigned long long)domain);
        return 0;
    }
    return os_eligibility_get_domain_answer(domain,answer,source,status,context);
}
__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement,*original; } eligibility_interpose={
    (const void*)eligibility_answer,(const void*)os_eligibility_get_domain_answer
};

typedef int64_t (*consume_fn)(const char *);

/* Exported so a sandboxed test harness can exercise the exact production
 * implementation without modifying the System volume. Never print tokens. */
int liter8_stage0_load(void) {
    if (getpid() == 1) return 0;
    const char *token = getenv(TOKEN_ENV);
    if (!token || !*token) return 0;
    consume_fn consume = (consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!consume || consume(token) < 0) {
        os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: sandbox grant rejected pid=%d errno=%d", getpid(), errno);
        return -1;
    }
    if (access("/var/jb/.spawnbridge_enabled", F_OK)) return 0;
    /* xpcproxy only propagates launch state. It is not a tweak target. */
    if (!strcmp(getprogname(), "xpcproxy")) return 1;
    void *loader = dlopen(LOADER, RTLD_NOW | RTLD_GLOBAL);
    if (!loader) {
        os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: ElleKit load failed pid=%d %{public}s", getpid(), dlerror());
        return -3;
    }
    os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: ElleKit loaded pid=%d executable=%{public}s", getpid(), getprogname());
    FILE *proof=fopen("/var/mobile/Library/Caches/com.apple.AppleMediaServices/Liter8/loaded.log","a");
    if(proof) {
        fprintf(proof,"pid=%d process=%s ElleKit loaded\n",getpid(),getprogname());
        for(uint32_t i=0;i<_dyld_image_count();i++) {
            const char *name=_dyld_get_image_name(i);
            if(strstr(name,"ellekit")||strstr(name,"TweakInject")) fprintf(proof,"image=%s\n",name);
        }
        fclose(proof);
    }
    return 2;
}

#ifndef LITER8_STAGE0_TEST
__attribute__((constructor)) static void stage0_init(void) {
    (void)liter8_stage0_load();
}
#endif
