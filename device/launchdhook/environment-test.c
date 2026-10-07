/* Standalone on-device regression tests for environment ownership and policy. */
#define LHOOK_NO_CONSTRUCTOR
#include "lhook.c"
#include <assert.h>
static const char *find(char **env, const char *key) {
    size_t n = strlen(key);
    for (size_t i=0;env[i];i++) if(!strncmp(env[i],key,n)) return env[i]+n;
    return NULL;
}
int main(void) {
    char *input[]={"UNCHANGED=hello","DYLD_INSERT_LIBRARIES=/usr/lib/lhook:/custom/a.dylib:/var/jb/usr/lib/Liter8SpawnBridge.dylib:/var/jb/usr/lib/TweakLoader.dylib", "DYLD_INSERT_LIBRARIES=/duplicate.dylib", "LITER8_SANDBOX_READ_TOKEN=old",NULL};
    for(int enabled=0;enabled<=1;enabled++) {
        struct child_env e={0};
        assert(!make_child_env(input,enabled,&e));
        assert(e.values[0]==input[0]);
        const char *libs=find(e.values,kInsertKey);
        assert(libs && !strstr(libs,"SpawnBridge") && !strstr(libs,"TweakLoader") && !strstr(libs,"duplicate"));
        assert(!strcmp(libs,enabled?"/usr/lib/lhook:/custom/a.dylib":"/custom/a.dylib"));
        assert(enabled || !find(e.values,kTokenKey));
        unsigned inserts=0,tokens=0;
        for(size_t i=0;e.values[i];i++) { inserts+=!strncmp(e.values[i],kInsertKey,INSERT_KEY_LEN); tokens+=!strncmp(e.values[i],kTokenKey,TOKEN_KEY_LEN); }
        assert(inserts==1 && tokens<2);
        free_child_env(&e);
    }
    struct child_env empty={0};assert(!make_child_env(NULL,0,&empty));assert(!empty.values[0]);free_child_env(&empty);
    assert(denied("/usr/sbin/sshd"));assert(denied("/sbin/launchd"));
    puts("PASS: enable/disable, duplicate keys, foreign libraries, ownership, deny policy");
    return 0;
}
