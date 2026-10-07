/* NewTerm uses a root login by the device owner's explicit request.
 * Other login commands retain their original behavior. */
#include <spawn.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <os/log.h>
#include <errno.h>
extern char **environ;
int main(int argc,char **argv){
 const char *original="/var/jb/usr/bin/login.liter8-real";
 if(argc>2 && !strcmp(argv[1],"--liter8-root-stage")){
  if(getuid()!=0 || geteuid()!=0)return 2;
  if(setgid(0)||setuid(0))return 2;
  argv[1]="login";execve(original,argv+1,environ);perror("login exec");return 1;
 }
 os_log_error(OS_LOG_DEFAULT,"l8login: uid=%d euid=%d argc=%d a1=%{public}s a2=%{public}s a3=%{public}s",getuid(),geteuid(),argc,argc>1?argv[1]:"",argc>2?argv[2]:"",argc>3?argv[3]:"");
 int match=argc==6 && (!strcmp(argv[1],"-fp")||!strcmp(argv[1],"-fpq")) && !strcmp(argv[2],"mobile") && (!strcmp(argv[3],"/var/jb/Applications/NewTerm.app/NewTermLoginHelper") || !strcmp(argv[3],"/private/var/jb/Applications/NewTerm.app/NewTermLoginHelper"));
 if(!match || geteuid()==0){execve(original,argv,environ);return 1;}
 char machine[64]={0},build[64]={0};size_t n=sizeof(machine);
 if(sysctlbyname("hw.machine",machine,&n,0,0))return 2;
 n=sizeof(build);if(sysctlbyname("kern.osversion",build,&n,0,0)||strcmp(machine,"iPad11,6")||strcmp(build,"23H30"))return 2;
 int (*persona)(posix_spawnattr_t *,uid_t,uint32_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
 int (*uid)(posix_spawnattr_t *,uid_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
 int (*gid)(posix_spawnattr_t *,gid_t)=dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
 if(!persona||!uid||!gid)return 3;
 posix_spawnattr_t attr;int r=posix_spawnattr_init(&attr);
 if(!r)r=persona(&attr,99,1);
 if(!r)r=uid(&attr,0);
 if(!r)r=gid(&attr,0);
 char *args[9]={"/var/jb/usr/bin/login","--liter8-root-stage",argv[1],"root",argv[3],"/var/root",argv[5],NULL};
 pid_t child=0;if(!r)r=posix_spawn(&child,args[0],NULL,&attr,args,environ);
 if(r){os_log_error(OS_LOG_DEFAULT,"l8login: spawn failed=%d",r);return 1;}
 os_log_error(OS_LOG_DEFAULT,"l8login: root terminal login child=%d",child);
 int status=0;pid_t w;do{w=waitpid(child,&status,0);}while(w<0&&errno==EINTR);if(w<0)return 1;return WIFEXITED(status)?WEXITSTATUS(status):1;
}
