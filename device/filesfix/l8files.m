// Process-local compatibility view for the already mounted single-user volume.
// This does not allocate a kernel persona or enable Shared iPad.
// UM current-persona objects must agree with the fallback volume attributes.
// EXPersona encodes its ivar directly, so getter hooks alone cannot remove the
// fallback UUID from the launch request. A separate empty encoding launches
// the extension normally; the extension then gets the same local UM view.
// Only LocalStorage is admitted. CloudDocs does not have this compatibility
// view and otherwise shuts down the daemon on a persona mismatch.
// Verified root lookup, FPCreateFolderOperation, and Files UI on 2026-10-07.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
static NSString *const identity=@"4C38534E-5045-5253-4F4E-414C00000501";
static id (*oldCurrent)(id,SEL),(*oldClassCurrent)(id,SEL);
static id (*oldType)(id,SEL,NSUInteger,NSError **);
static id (*oldString)(id,SEL,id,NSError **);
static BOOL (*oldLegit)(id,SEL);
static BOOL enabled(void){struct stat s;return !lstat("/var/jb/.liter8-files",&s)&&S_ISREG(s.st_mode)&&s.st_uid==0&&!(s.st_mode&022);}
static void set(id object,const char *name,id value){SEL s=sel_registerName(name);if([object respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(object,s,value);}
static void number(id object,const char *name,NSUInteger value){SEL s=sel_registerName(name);if([object respondsToSelector:s])((void(*)(id,SEL,NSUInteger))objc_msgSend)(object,s,value);}
static id attributes(NSUInteger type){
    id a=[objc_lookUpClass("UMUserPersonaAttributes") new];
    set(a,"setUserPersonaUniqueString:",identity);set(a,"setPersonaLayoutPathURL:",[NSURL fileURLWithPath:@"/private/var/mobile" isDirectory:YES]);
    number(a,"setUserPersonaType:",type);number(a,"setUserPersona_id:",501);
    number(a,"setIsPersonalPersona:",type==0);number(a,"setIsSystemPersona:",type==2);number(a,"setIsDefaultPersona:",type==5);return a;
}
static id localPersona(void){
    static id p;static dispatch_once_t once;
    dispatch_once(&once,^{p=class_createInstance(objc_lookUpClass("UMUserPersona"),0);
        set(p,"setUserPersonaUniqueString:",identity);number(p,"setUserPersonaType:",0);
        number(p,"setUid:",501);number(p,"setGid:",501);number(p,"setIsPersonalPersona:",YES);});
    return p;
}
static id current(id self,SEL cmd){id p=oldCurrent(self,cmd);if(enabled()&&(!p||!((id(*)(id,SEL))objc_msgSend)(p,sel_registerName("userPersonaUniqueString"))))return localPersona();return p;}
static id classCurrent(id self,SEL cmd){id p=oldClassCurrent(self,cmd);if(enabled()&&(!p||!((id(*)(id,SEL))objc_msgSend)(p,sel_registerName("userPersonaUniqueString"))))return localPersona();return p;}
static id type(id self,SEL cmd,NSUInteger t,NSError **error){
    id a=oldType(self,cmd,t,error);if(a||!enabled()||(t!=0&&t!=2&&t!=5))return a;
    if(error)*error=nil;os_log_error(OS_LOG_DEFAULT,"l8files: local volume attributes for role %{public}lu",(unsigned long)t);return attributes(t);
}
static id unique(id self,SEL cmd,id name,NSError **error){id a=oldString(self,cmd,name,error);if(a||!enabled()||![name isEqual:identity])return a;if(error)*error=nil;return attributes(0);}
static void (*oldEXEncode)(id,SEL,id);
static void exEncode(id self,SEL cmd,id coder){
    Ivar ivar=class_getInstanceVariable(objc_lookUpClass("_EXPersona"),"_personaUniqueString");
    id value=ivar?object_getIvar(self,ivar):nil;
    if(enabled() && [value isEqual:identity]){
        id empty=class_createInstance(objc_lookUpClass("_EXPersona"),0);
        os_log_error(OS_LOG_DEFAULT,"l8files: encoding extension launch with no kernel persona");
        oldEXEncode(empty,cmd,coder);return;
    }oldEXEncode(self,cmd,coder);
}
static id (*oldLaunch)(id,SEL),(*oldHostLaunch)(id,SEL),(*oldEXString)(id,SEL);
static id exString(id self,SEL cmd){id value=oldEXString(self,cmd);if(enabled()&&[value isEqual:identity]){os_log_error(OS_LOG_DEFAULT,"l8files: stripped synthetic persona from extension identity");return nil;}return value;}
static id withoutSyntheticLaunch(id p){
    if(enabled() && [p respondsToSelector:sel_registerName("personaUniqueString")] &&
       [((id(*)(id,SEL))objc_msgSend)(p,sel_registerName("personaUniqueString")) isEqual:identity]){
        os_log_error(OS_LOG_DEFAULT,"l8files: launch local extension without synthetic kernel persona");return nil;
    }return p;
}
static id launch(id self,SEL cmd){return withoutSyntheticLaunch(oldLaunch(self,cmd));}
static id hostLaunch(id self,SEL cmd){return withoutSyntheticLaunch(oldHostLaunch(self,cmd));}
static BOOL legit(id self,SEL cmd){if(!enabled())return oldLegit(self,cmd);return [((id(*)(id,SEL))objc_msgSend)(self,sel_registerName("identifier")) isEqual:@"com.apple.FileProvider.LocalStorage"];}
static BOOL hook(Class c,const char *name,IMP replacement,void *saved){
    Method m=class_getInstanceMethod(c,sel_registerName(name));if(!m)return NO;
    *(IMP*)saved=method_getImplementation(m);method_setImplementation(m,replacement);return YES;
}
__attribute__((constructor)) static void load(void){@autoreleasepool {
    if(!enabled())return;
    char machine[64]={0},build[64]={0};size_t length=sizeof(machine);
    if(sysctlbyname("hw.machine",machine,&length,NULL,0)||strcmp(machine,"iPad11,6"))return;
    length=sizeof(build);
    if(sysctlbyname("kern.osversion",build,&length,NULL,0)||strcmp(build,"23H30")||geteuid()!=501)return;
    dlopen("/System/Library/PrivateFrameworks/UserManagement.framework/UserManagement",RTLD_NOW);
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation",RTLD_NOW);
    BOOL enc=hook(objc_lookUpClass("_EXPersona"),"encodeWithCoder:",(IMP)exEncode,&oldEXEncode);
    os_log_error(OS_LOG_DEFAULT,"l8files: EX encode hook=%{public}d",enc);
    BOOL z=hook(objc_lookUpClass("_EXPersona"),"personaUniqueString",(IMP)exString,&oldEXString);
    os_log_error(OS_LOG_DEFAULT,"l8files: EX persona identity hook=%{public}d",z);
    BOOL x=hook(objc_lookUpClass("_EXLaunchConfiguration"),"launchPersona",(IMP)launch,&oldLaunch);
    BOOL y=hook(objc_lookUpClass("_EXHostConfiguration"),"launchPersona",(IMP)hostLaunch,&oldHostLaunch);
    os_log_error(OS_LOG_DEFAULT,"l8files: extension launch hooks=%{public}d/%{public}d",x,y);
    BOOL a=hook(objc_lookUpClass("UMUserManager"),"currentPersona",(IMP)current,&oldCurrent);
    BOOL b=hook(object_getClass(objc_lookUpClass("UMUserPersonaAttributes")),"personaAttributesForPersonaType:withError:",(IMP)type,&oldType);
    BOOL c=hook(object_getClass(objc_lookUpClass("UMUserPersonaAttributes")),"personaAttributesForPersonaUniqueString:withError:",(IMP)unique,&oldString);
    BOOL d=hook(objc_lookUpClass("FPDProviderDescriptor"),"isPersonaLegit",(IMP)legit,&oldLegit);
    BOOL e=hook(object_getClass(objc_lookUpClass("UMUserPersona")),"currentPersona",(IMP)classCurrent,&oldClassCurrent);
    os_log_error(OS_LOG_DEFAULT,"l8files: installed current=%{public}d type=%{public}d unique=%{public}d descriptor=%{public}d class=%{public}d pid=%{public}d",a,b,c,d,e,getpid());
}}
