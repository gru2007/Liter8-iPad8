/* Run only as a standalone diagnostic, never in a system daemon. */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
extern int liter8_load_tweaks(void);
int main(void) {
    if(!getenv("LITER8_SANDBOX_READ_TOKEN")) { puts("missing test token"); return 1; }
    int rc;
    FILE *before=fopen("/private/var/jb/usr/lib/TweakLoader.dylib","rb");
    printf("before grant read=%d errno=%d\n",before!=NULL,errno);
    if(before) { fclose(before); puts("FAIL: profile did not restrict access"); return 4; }
    rc=liter8_load_tweaks();
    FILE *after=fopen("/private/var/jb/usr/lib/TweakLoader.dylib","rb");
    printf("lhook=%d after grant read=%d errno=%d\n",rc,after!=NULL,errno);
    if(after) fclose(after);
    return rc==1&&after?0:5;
}
