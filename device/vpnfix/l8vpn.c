/* Consume only the grant issued for Karing's verified app-group directory.
 * No auth bypass, no app binary or container-metadata changes.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <os/log.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
static long long grant=-1;
__attribute__((constructor)) static void load(void) {
    struct stat st;
    if(lstat("/private/var/jb/.liter8-vpn",&st) || !S_ISREG(st.st_mode) || st.st_uid!=0 || (st.st_mode&022))return;
    int fd=open("/private/var/jb/etc/liter8-vpn/karing.token",O_RDONLY|O_NOFOLLOW);
    if(fd<0){os_log_error(OS_LOG_DEFAULT,"l8vpn: token mailbox unavailable");return;}
    if(fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=0 || (st.st_mode&022) || st.st_size<=0 || st.st_size>32768){close(fd);return;}
    char *token=calloc((size_t)st.st_size+1,1);if(!token){close(fd);return;}
    size_t done=0;
    while(done<(size_t)st.st_size){ssize_t r=read(fd,token+done,(size_t)st.st_size-done);if(r<=0)break;done+=(size_t)r;}
    close(fd);
    long long (*consume)(const char *)=dlsym(RTLD_DEFAULT,"sandbox_extension_consume");
    if(done==(size_t)st.st_size && consume)grant=consume(token);
    free(token);
    os_log_error(OS_LOG_DEFAULT,"l8vpn: Karing app-group grant consumed=%{public}d pid=%{public}d",grant>=0,getpid());
}
