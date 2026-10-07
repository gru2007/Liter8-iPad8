#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
extern char**environ;
int main(int argc,char**argv){setbuf(stdout,NULL);if(argc>1){printf("child pid=%d PASS\n",getpid());return 0;}pid_t pid=-1;char*args[]={argv[0],"child",NULL};posix_spawnattr_t attr;posix_spawnattr_init(&attr);if(strstr(argv[0],"setexec"))posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETEXEC);int rc=posix_spawn(&pid,argv[0],NULL,&attr,args,environ);printf("spawn rc=%d pid=%d\n",rc,pid);if(rc)return 1;int status=0;waitpid(pid,&status,0);return status!=0;}
