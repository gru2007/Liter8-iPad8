/* Issue a boot-scoped bearer grant for Karing's app-group directory only. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdint.h>
int main(int argc,char **argv) {
    char machine[64]={0},build[64]={0};size_t n=sizeof(machine);
    if(argc!=2 || geteuid()!=0 || sysctlbyname("hw.machine",machine,&n,NULL,0))return 2;
    n=sizeof(build);
    if(sysctlbyname("kern.osversion",build,&n,NULL,0) || strcmp(machine,"iPad11,6") || strcmp(build,"23H30"))return 2;
    const char *path=argv[1];
    const char *prefix="/private/var/mobile/Containers/Shared/AppGroup/";
    if(strncmp(path,prefix,strlen(prefix)))return 2;
    const char *tail=path+strlen(prefix);
    if(strncmp(path,prefix,strlen(prefix)) || strlen(tail)!=36 || strspn(tail,"0123456789ABCDEFabcdef-")!=36)return 2;
    struct stat st;if(stat(path,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=501)return 3;
    char *(*issue)(const char *,const char *,uint32_t)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_file");
    char *token=issue ? issue("com.apple.app-sandbox.read-write",path,0) : NULL;
    if(!token || !strchr(token,';')){fputs("Could not issue app-group token\n",stderr);return 4;}
    const char *box="/private/var/jb/etc/liter8-vpn/karing.token";
    int fd=open(box,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0640);
    if(fd<0){perror("open token mailbox");free(token);return 5;}
    size_t len=strlen(token),offset=0;
    if(fchown(fd,0,501) || fchmod(fd,0640)){close(fd);free(token);return 5;}
    while(offset<len){ssize_t w=write(fd,token+offset,len-offset);if(w<0 && errno==EINTR)continue;if(w<=0){close(fd);free(token);return 5;}offset+=(size_t)w;}
    int result=fsync(fd);close(fd);free(token);
    if(result)return 5;
    puts("Karing app-group token refreshed (valid for current boot).");return 0;
}
