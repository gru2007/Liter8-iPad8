// Data-volume spawn propagation for Liter8. Never patches executable memory.
#include <spawn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <ptrauth.h>
#include <os/log.h>
#define SELF "/var/jb/usr/lib/Liter8SpawnBridge.dylib"
#define LOADER "/var/jb/usr/lib/TweakLoader.dylib"
#define ENABLE "/var/jb/.spawnbridge_enabled"
#define KEY "DYLD_INSERT_LIBRARIES="
#define INTERPOSE(replacement,original) __attribute__((used)) static const struct{const void*r,*o;} ip_##original __attribute__((section("__DATA,__interpose")))={(const void*)replacement,(const void*)original};
typedef int(*spawn_fn)(pid_t*,const char*,const posix_spawn_file_actions_t*,const posix_spawnattr_t*,char*const*,char*const*);
static spawn_fn real_spawn,real_spawnp;
static void trace(const char*fmt,...){if(access("/var/jb/.spawnbridge_debug",F_OK))return;char b[1024];va_list a;va_start(a,fmt);vsnprintf(b,sizeof(b),fmt,a);va_end(a);os_log_error(OS_LOG_DEFAULT,"Liter8SpawnBridge: %{public}s",b);char path[128];snprintf(path,sizeof(path),"/var/tmp/Liter8SpawnBridge-%u.log",getuid());int fd=open(path,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW,0600);if(fd>=0){dprintf(fd,"%s\n",b);close(fd);}}
static int denied(const char *path){const char*b=strrchr(path?path:"",'/');b=b?b+1:path;if(!b)return 1;const char*names[]={"launchd","amfid","trustd","securityd","configd","notifyd","logd","opendirectoryd","keybagd","watchdogd","dropbear","sshd","restored_external","mobile_obliterator",NULL};for(int i=0;names[i];i++)if(!strcmp(b,names[i]))return 1;FILE*f=fopen("/var/jb/etc/lhook.deny","r");if(f){char line[256];while(fgets(line,sizeof(line),f)){line[strcspn(line,"\r\n")]=0;if(!strcmp(b,line)){fclose(f);return 1;}}fclose(f);}return 0;}
static int ours(const char*p){return !strcmp(p,SELF)||!strcmp(p,LOADER)||!strcmp(p,"/usr/lib/lhook");}
static char**environment(char*const*env,int inject){size_t n=0,len=inject?strlen(SELF)+strlen(LOADER)+2:1;const char*old=NULL;while(env&&env[n]){if(!strncmp(env[n],KEY,sizeof(KEY)-1)&&!old)old=env[n]+sizeof(KEY)-1;n++;}if(old)len+=strlen(old)+1;char*libs=calloc(1,len);char**out=calloc(n+2,sizeof(char*));if(!libs||!out){free(libs);free(out);return NULL;}if(inject)snprintf(libs,len,"%s:%s",SELF,LOADER);char*copy=old?strdup(old):NULL;if(old&&!copy){free(libs);free(out);return NULL;}char*save=NULL;for(char*t=copy?strtok_r(copy,":",&save):NULL;t;t=strtok_r(NULL,":",&save)){if(ours(t))continue;if(*libs)strcat(libs,":");strcat(libs,t);}free(copy);size_t j=0;for(size_t i=0;i<n;i++)if(strncmp(env[i],KEY,sizeof(KEY)-1))out[j++]=env[i];if(*libs&&asprintf(&out[j],"%s%s",KEY,libs)<0){free(out);out=NULL;}free(libs);return out;}
static void freeenv(char**out){if(!out)return;for(size_t i=0;out[i];i++)if(!strncmp(out[i],KEY,sizeof(KEY)-1)){free(out[i]);break;}free(out);}
static int common(spawn_fn real,pid_t*pid,const char*path,const posix_spawn_file_actions_t*fa,const posix_spawnattr_t*at,char*const*av,char*const*ev){if(!real)return ENOSYS;int enabled=!access(ENABLE,F_OK);int inject=enabled&&!denied(path)&&!access(SELF,R_OK)&&!access(LOADER,R_OK);char**env=environment(ev,inject);if(!env)return ENOMEM;short flags=0;if(at)posix_spawnattr_getflags(at,&flags);trace("spawn pid=%d target=%s inject=%d setexec=%d",getpid(),path?path:"(null)",inject,!!(flags&POSIX_SPAWN_SETEXEC));int rc=real(pid,path,fa,at,av,env);freeenv(env);trace("spawn returned target=%s rc=%d",path?path:"(null)",rc);return rc;}
static int wrap_spawn(pid_t*p,const char*s,const posix_spawn_file_actions_t*f,const posix_spawnattr_t*a,char*const*v,char*const*e){return common(real_spawn,p,s,f,a,v,e);}
static int wrap_spawnp(pid_t*p,const char*s,const posix_spawn_file_actions_t*f,const posix_spawnattr_t*a,char*const*v,char*const*e){return common(real_spawnp,p,s,f,a,v,e);}
INTERPOSE(wrap_spawn,posix_spawn)
INTERPOSE(wrap_spawnp,posix_spawnp)
// In xpcproxy the System-volume interposer takes precedence over a second
// DYLD_INTERPOSE table. Rebind only its raw __got spawn imports. The caller
// PAC-signs these raw addresses before BLRAAZ. Do not overwrite __auth_got.
static int rebind_proxy(void){
 const struct mach_header_64*h=NULL;intptr_t slide=0;
 for(unsigned z=0;z<_dyld_image_count();z++){const struct mach_header*m=_dyld_get_image_header(z);if(m->filetype==MH_EXECUTE){h=(const void*)m;slide=_dyld_get_image_vmaddr_slide(z);break;}}
 if(!h||h->magic!=MH_MAGIC_64)return 0;
 const struct symtab_command*st=NULL;const struct dysymtab_command*dt=NULL;const struct segment_command_64*le=NULL;const uint8_t*c=(const void*)(h+1);
 for(unsigned i=0;i<h->ncmds;i++){const struct load_command*l=(const void*)c;if(l->cmdsize<sizeof(*l)||c+l->cmdsize>(const uint8_t*)(h+1)+h->sizeofcmds)return 0;if(l->cmd==LC_SYMTAB)st=(const void*)c;if(l->cmd==LC_DYSYMTAB)dt=(const void*)c;if(l->cmd==LC_SEGMENT_64&&!strcmp(((const struct segment_command_64*)c)->segname,"__LINKEDIT"))le=(const void*)c;c+=l->cmdsize;}
 if(!st||!dt||!le)return 0;uintptr_t lb=slide+le->vmaddr-le->fileoff;const struct nlist_64*sy=(const void*)(lb+st->symoff);const char*str=(const void*)(lb+st->stroff);const uint32_t*ind=(const void*)(lb+dt->indirectsymoff);int count=0;c=(const void*)(h+1);
 for(unsigned i=0;i<h->ncmds;i++){const struct load_command*l=(const void*)c;if(l->cmd==LC_SEGMENT_64){const struct segment_command_64*g=(const void*)c;const struct section_64*s=(const void*)(g+1);for(unsigned j=0;j<g->nsects;j++,s++){if(strcmp(s->sectname,"__got")||(s->flags&SECTION_TYPE)!=S_NON_LAZY_SYMBOL_POINTERS)continue;for(unsigned k=0;k<s->size/8;k++){if(s->reserved1+k>=dt->nindirectsyms)break;uint32_t idx=ind[s->reserved1+k];if(idx>=st->nsyms||sy[idx].n_un.n_strx>=st->strsize)continue;const char*n=str+sy[idx].n_un.n_strx;void*replacement=!strcmp(n,"_posix_spawn")?(void*)wrap_spawn:!strcmp(n,"_posix_spawnp")?(void*)wrap_spawnp:NULL;if(!replacement)continue;void**slot=(void**)(slide+s->addr+8*k);vm_address_t page=(uintptr_t)slot&~((uintptr_t)vm_page_size-1);kern_return_t rc=vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);if(rc){trace("rebind %s vm_protect=%d",n,rc);continue;}*slot=ptrauth_strip(replacement,ptrauth_key_function_pointer);rc=vm_protect(mach_task_self(),page,vm_page_size,FALSE,g->initprot);trace("rebind %s done restore=%d",n,rc);count++;}}}c+=l->cmdsize;}return count;
}
#include "exports.h"
__attribute__((constructor)) static void init(void){real_spawn=(spawn_fn)original_export("/usr/lib/system/libsystem_kernel.dylib","_posix_spawn");real_spawnp=(spawn_fn)original_export("/usr/lib/system/libsystem_c.dylib","_posix_spawnp");Dl_info ds={0},dp={0};dladdr(ptrauth_strip((void*)real_spawn,ptrauth_key_function_pointer),&ds);dladdr(ptrauth_strip((void*)real_spawnp,ptrauth_key_function_pointer),&dp);trace("original spawn=%s:%s spawnp=%s:%s",ds.dli_fname,ds.dli_sname,dp.dli_fname,dp.dli_sname);trace("loaded pid=%d uid=%d executable=%s",getpid(),getuid(),getprogname());if(getpid()!=1&&!strcmp(getprogname(),"xpcproxy")&&real_spawn&&real_spawnp)trace("xpcproxy rebound=%d",rebind_proxy());}
