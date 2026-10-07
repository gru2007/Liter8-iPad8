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
#include <ptrauth.h>
static void logline(const char *fmt,...) {int fd=open("/var/tmp/Liter8SpawnProbe.log",O_WRONLY|O_CREAT|O_APPEND,0644);if(fd<0)return;va_list ap;va_start(ap,fmt);vdprintf(fd,fmt,ap);va_end(ap);close(fd);}
__attribute__((constructor)) static void start(void){
 unsigned mainIndex=0;for(unsigned z=0;z<_dyld_image_count();z++){const struct mach_header*mh=_dyld_get_image_header(z);if(z<5)logline("pid=%d prog=%s index=%u type=%u path=%s\n",getpid(),getprogname(),z,mh->filetype,_dyld_get_image_name(z));if(mh->filetype==MH_EXECUTE)mainIndex=z;}
 const struct mach_header_64*h=(const void*)_dyld_get_image_header(mainIndex);intptr_t slide=_dyld_get_image_vmaddr_slide(mainIndex);
 const struct symtab_command*st=NULL;const struct dysymtab_command*dt=NULL;const struct segment_command_64*le=NULL;
 const uint8_t*c=(const void*)(h+1);
 logline("pid=%d image=%s\n",getpid(),_dyld_get_image_name(mainIndex));
 for(unsigned i=0;i<h->ncmds;i++){const struct load_command*l=(const void*)c;if(l->cmd==LC_SYMTAB)st=(const void*)c;if(l->cmd==LC_DYSYMTAB)dt=(const void*)c;if(l->cmd==LC_SEGMENT_64&&!strcmp(((const struct segment_command_64*)c)->segname,"__LINKEDIT"))le=(const void*)c;c+=l->cmdsize;}
 if(!st||!dt||!le)return;
 uintptr_t lb=slide+le->vmaddr-le->fileoff;const struct nlist_64*sy=(const void*)(lb+st->symoff);const char*str=(const void*)(lb+st->stroff);const uint32_t*ind=(const void*)(lb+dt->indirectsymoff);
 c=(const void*)(h+1);
 for(unsigned i=0;i<h->ncmds;i++){const struct load_command*l=(const void*)c;if(l->cmd==LC_SEGMENT_64){const struct segment_command_64*g=(const void*)c;const struct section_64*s=(const void*)(g+1);for(unsigned j=0;j<g->nsects;j++,s++){if((s->flags&SECTION_TYPE)!=S_NON_LAZY_SYMBOL_POINTERS)continue;for(unsigned k=0;k<s->size/8;k++){if(s->reserved1+k>=dt->nindirectsyms)break;uint32_t idx=ind[s->reserved1+k];if(idx>=st->nsyms||sy[idx].n_un.n_strx>=st->strsize)continue;const char*n=str+sy[idx].n_un.n_strx;if(strcmp(n,"_posix_spawn")&&strcmp(n,"_posix_spawnp"))continue;void**slot=(void**)(slide+s->addr+8*k);void*p=ptrauth_strip(*slot,ptrauth_key_function_pointer);Dl_info d={0};dladdr(p,&d);logline("pid=%d section=%s name=%s slot=%p value=%p image=%s symbol=%s\n",getpid(),s->sectname,n,slot,p,d.dli_fname?d.dli_fname:"?",d.dli_sname?d.dli_sname:"?");}}}c+=l->cmdsize;}
}
