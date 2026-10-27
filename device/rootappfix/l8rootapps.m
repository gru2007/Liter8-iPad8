/* Experimental: let RunningBoard submit iCleaner's real UI process as root.
 * Verified ABI on RunningBoard 1015.160.2: jobWithPlist:domain: accepts XPC data.
 * Never change jobs for any other executable. */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
// The bundled SDK omits XPC headers; these declarations match the inspected ABI.
typedef void *xpc_object_t;
struct _xpc_type_s;
typedef const struct _xpc_type_s *xpc_type_t;
extern const struct _xpc_type_s _xpc_type_dictionary, _xpc_type_array;
#define XPC_TYPE_DICTIONARY (&_xpc_type_dictionary)
#define XPC_TYPE_ARRAY (&_xpc_type_array)
extern xpc_type_t xpc_get_type(xpc_object_t);
extern const char *xpc_dictionary_get_string(xpc_object_t,const char *);
extern xpc_object_t xpc_dictionary_get_value(xpc_object_t,const char *);
extern size_t xpc_array_get_count(xpc_object_t);
extern const char *xpc_array_get_string(xpc_object_t,size_t);
extern xpc_object_t xpc_copy(xpc_object_t);
extern void xpc_dictionary_set_string(xpc_object_t,const char *,const char *);
extern void xpc_release(xpc_object_t);
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <os/log.h>

static id (*originalDomain)(id,SEL,xpc_object_t,id);
static id (*originalSimple)(id,SEL,xpc_object_t);
static xpc_object_t (*originalGenerate)(id,SEL,id,id,id *,NSError **);
static BOOL enabled(void){struct stat st;return !stat("/var/jb/.liter8-rootapps",&st)&&S_ISREG(st.st_mode)&&st.st_uid==0&&(st.st_mode&0777)==0600;}
static void adjust(xpc_object_t plist){
 if(!enabled() || !plist || xpc_get_type(plist)!=XPC_TYPE_DICTIONARY)return;
 const char *path=xpc_dictionary_get_string(plist,"Program");
 if(!path){xpc_object_t args=xpc_dictionary_get_value(plist,"ProgramArguments");if(args&&xpc_get_type(args)==XPC_TYPE_ARRAY&&xpc_array_get_count(args))path=xpc_array_get_string(args,0);}
 const char *label=xpc_dictionary_get_string(plist,"Label");
 if(label && strstr(label,"com.ivanobilenchi.icleaner"))os_log_error(OS_LOG_DEFAULT,"l8rootapps: iCleaner job program=%{public}s",path?path:"(none)");
 if(!path || (strcmp(path,"/var/jb/Applications/iCleaner.app/iCleaner")&&strcmp(path,"/private/var/jb/Applications/iCleaner.app/iCleaner")))return;
 xpc_dictionary_set_string(plist,"UserName","root");xpc_dictionary_set_string(plist,"GroupName","wheel");
 os_log_error(OS_LOG_DEFAULT,"l8rootapps: requesting native root launch for iCleaner");
}
static id domainJob(id self,SEL cmd,xpc_object_t plist,id domain){xpc_object_t copy=plist?xpc_copy(plist):NULL;adjust(copy);id result=originalDomain(self,cmd,copy?copy:plist,domain);if(copy)xpc_release(copy);return result;}
static id simpleJob(id self,SEL cmd,xpc_object_t plist){xpc_object_t copy=plist?xpc_copy(plist):NULL;adjust(copy);id result=originalSimple(self,cmd,copy?copy:plist);if(copy)xpc_release(copy);return result;}
static xpc_object_t generate(id self,SEL cmd,id identity,id context,id *actual,NSError **error){xpc_object_t data=originalGenerate(self,cmd,identity,context,actual,error);adjust(data);return data;}
__attribute__((constructor))static void start(void){
 char machine[64]={0},build[64]={0};size_t n=sizeof(machine);
 if(geteuid()!=0||sysctlbyname("hw.machine",machine,&n,0,0))return;
 n=sizeof(build);if(sysctlbyname("kern.osversion",build,&n,0,0)||strcmp(machine,"iPad11,6")||strcmp(build,"23H30"))return;
 Method m=class_getInstanceMethod(objc_lookUpClass("RBLaunchdInterface"),sel_registerName("jobWithPlist:domain:"));
 if(m && method_getNumberOfArguments(m)==4)originalDomain=(void *)method_setImplementation(m,(IMP)domainJob);
 m=class_getInstanceMethod(objc_lookUpClass("RBLaunchdInterface"),sel_registerName("jobWithPlist:"));
 if(m && method_getNumberOfArguments(m)==3)originalSimple=(void *)method_setImplementation(m,(IMP)simpleJob);
 m=class_getInstanceMethod(objc_lookUpClass("RBLaunchdJobManager"),sel_registerName("_generateDataWithIdentity:context:actualIdentity:error:"));
 if(m && method_getNumberOfArguments(m)==6)originalGenerate=(void *)method_setImplementation(m,(IMP)generate);
 os_log_error(OS_LOG_DEFAULT,"l8rootapps: root launch hooks domain=%d simple=%d generate=%d",originalDomain!=NULL,originalSimple!=NULL,originalGenerate!=NULL);
}
