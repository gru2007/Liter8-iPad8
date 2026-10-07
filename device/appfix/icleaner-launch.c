/* Root launch of this app only using the existing Liter8 persona 99.
 * No daemon, arbitrary command interface, or setuid binary is introduced. */
#include <spawn.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <os/log.h>
#include <sys/wait.h>
#include <errno.h>
extern char **environ;
int main(int argc,char **argv){
 os_log_error(OS_LOG_DEFAULT,"l8icleaner: entry uid=%d euid=%d",getuid(),geteuid());
 char machine[64]={0},build[64]={0};size_t n=sizeof(machine);
 if(sysctlbyname("hw.machine",machine,&n,0,0))return 2;
 n=sizeof(build);if(sysctlbyname("kern.osversion",build,&n,0,0)||strcmp(machine,"iPad11,6")||strcmp(build,"23H30"))return 2;
 const char *target="/var/jb/Applications/iCleaner.app/iCleaner.liter8-real";
 if(argc==2 && !strcmp(argv[1],"--stage")){if(getuid()!=0 || geteuid()!=0 || setgid(0) || setuid(0)) return 2;os_log_error(OS_LOG_DEFAULT,"l8icleaner: root stage ready");char *args[]={(char *)target,NULL};execve(target,args,environ);return 1;}
 argv[0]=(char *)target;
 if(geteuid()==0 || argc!=1){execve(target,argv,environ);perror("execve");return 1;}
 int (*persona)(posix_spawnattr_t *,uid_t,uint32_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
 int (*uid)(posix_spawnattr_t *,uid_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
 int (*gid)(posix_spawnattr_t *,gid_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
 if(!persona||!uid||!gid)return 3;
 posix_spawnattr_t attr;int r=posix_spawnattr_init(&attr);
 if(!r)r=persona(&attr,99,1);
 if(!r)r=uid(&attr,0);
 if(!r)r=gid(&attr,0);
 pid_t child=0;
 char *stage[]={"/var/jb/Applications/iCleaner.app/iCleaner","--stage",NULL};
 if(!r)r=posix_spawn(&child,stage[0],NULL,&attr,stage,environ);
 if(!r){int status=0;pid_t w;do{w=waitpid(child,&status,0);}while(w<0&&errno==EINTR);if(w<0)return 1;return WIFEXITED(status)?WEXITSTATUS(status):1;}
 os_log_error(OS_LOG_DEFAULT,"l8icleaner: root launch error=%d",r);
 return 1;
}
