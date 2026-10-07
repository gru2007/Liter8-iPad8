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

#define TOKEN_ENV "LITER8_SANDBOX_READ_TOKEN"
#define BRIDGE "/var/jb/usr/lib/Liter8SpawnBridge.dylib"
#define LOADER "/var/jb/usr/lib/TweakLoader.dylib"

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
    void *bridge = dlopen(BRIDGE, RTLD_NOW | RTLD_GLOBAL);
    if (!bridge) {
        os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: bridge load failed pid=%d %{public}s", getpid(), dlerror());
        return -2;
    }
    /* xpcproxy only propagates launch state. It is not a tweak target. */
    if (!strcmp(getprogname(), "xpcproxy")) return 1;
    void *loader = dlopen(LOADER, RTLD_NOW | RTLD_GLOBAL);
    if (!loader) {
        os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: ElleKit load failed pid=%d %{public}s", getpid(), dlerror());
        return -3;
    }
    os_log_error(OS_LOG_DEFAULT, "Liter8Stage0: ElleKit loaded pid=%d executable=%{public}s", getpid(), getprogname());
    return 2;
}

#ifndef LITER8_STAGE0_TEST
__attribute__((constructor)) static void stage0_init(void) {
    (void)liter8_stage0_load();
}
#endif
