// Resolve the actual shared-cache export, before dyld's interpose mapping.
// dlsym (including RTLD_NEXT) returns our replacement on this iPadOS build.
static int read_uleb(const uint8_t **p,const uint8_t*end,uint64_t*out){uint64_t v=0;unsigned shift=0;while(*p<end&&shift<64){uint8_t b=*(*p)++;if(shift==63&&(b&0x7e))return 0;v|=(uint64_t)(b&127)<<shift;if(!(b&128)){*out=v;return 1;}shift+=7;}return 0;}
static void *original_export(const char *path,const char *symbol){
 const struct mach_header_64*h=NULL;intptr_t slide=0;
 for(unsigned i=0;i<_dyld_image_count();i++)if(!strcmp(_dyld_get_image_name(i),path)){h=(const void*)_dyld_get_image_header(i);slide=_dyld_get_image_vmaddr_slide(i);break;}
 if(!h||h->magic!=MH_MAGIC_64)return NULL;
 const struct segment_command_64*le=NULL;uint32_t off=0,size=0;const uint8_t*c=(const void*)(h+1),*limit=c+h->sizeofcmds;
 for(unsigned i=0;i<h->ncmds;i++){if(c+sizeof(struct load_command)>limit)return NULL;const struct load_command*l=(const void*)c;if(l->cmdsize<sizeof(*l)||l->cmdsize>(size_t)(limit-c))return NULL;if(l->cmd==LC_SEGMENT_64&&!strcmp(((const struct segment_command_64*)c)->segname,"__LINKEDIT"))le=(const void*)c;if(l->cmd==LC_DYLD_EXPORTS_TRIE){const struct linkedit_data_command*d=(const void*)c;off=d->dataoff;size=d->datasize;}if(l->cmd==LC_DYLD_INFO_ONLY&&!size){const struct dyld_info_command*d=(const void*)c;off=d->export_off;size=d->export_size;}c+=l->cmdsize;}
 if(!le||!size||off<le->fileoff||off+size>le->fileoff+le->filesize)return NULL;
 const uint8_t*start=(const void*)(slide+le->vmaddr-le->fileoff+off),*end=start+size,*p=start;const char*remaining=symbol;
 for(unsigned depth=0;depth<128;depth++){uint64_t terminal=0;if(!read_uleb(&p,end,&terminal)||terminal>(uint64_t)(end-p))return NULL;const uint8_t*children=p+terminal;
 if(!*remaining&&terminal){uint64_t flags=0,address=0;if(!read_uleb(&p,children,&flags)||flags!=0||!read_uleb(&p,children,&address))return NULL;void*raw=(void*)((uintptr_t)h+address);return ptrauth_sign_unauthenticated(raw,ptrauth_key_function_pointer,0);}
 if(children>=end)return NULL;unsigned n=*children++;int found=0;for(unsigned i=0;i<n;i++){const char*edge=(const void*)children;const uint8_t*zero=memchr(children,0,end-children);if(!zero)return NULL;size_t len=zero-children;children=zero+1;uint64_t target=0;if(!read_uleb(&children,end,&target)||target>=size)return NULL;if(!strncmp(remaining,edge,len)){remaining+=len;p=start+target;found=1;break;}}if(!found)return NULL;
 }return NULL;
}
