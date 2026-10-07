#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void report(void*unused){(void)unused;char p[128];snprintf(p,sizeof(p),"/var/tmp/Liter8InjectionProof-%u.log",getuid());int fd=open(p,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);if(fd<0)return;dprintf(fd,"pid=%d process=%s constructor=PASS\n",getpid(),getprogname());for(unsigned i=0;i<_dyld_image_count();i++){const char*n=_dyld_get_image_name(i);if(strstr(n,"ellekit")||strstr(n,"TweakInject")||strstr(n,"SpawnBridge")||strstr(n,"TweakLoader"))dprintf(fd,"image=%s\n",n);}close(fd);os_log_error(OS_LOG_DEFAULT,"Liter8InjectionProof pid=%d process=%{public}s PASS",getpid(),getprogname());}
__attribute__((constructor))static void loaded(void){dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,1000000000),dispatch_get_global_queue(0,0),NULL,report);}
