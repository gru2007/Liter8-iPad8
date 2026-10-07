/* Live SEP-less workaround for build 23H30. Scoped to the Marketplace UI.
 * Keep explicit user consent and let the UI's existing no-passcode branch run
 * only after the observed ACM-context failure of LAPolicyOslo (1005).
 * No coreauthd, SpringBoard, executable-page or system-volume modifications.
 */
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#include <os/log.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <string.h>
typedef void (^Reply)(NSDictionary *, NSError *);
typedef void (*Evaluate)(id, SEL, NSInteger, NSDictionary *, Reply);
static Evaluate original;
typedef BOOL (*CanEvaluate)(id,SEL,NSInteger,NSError **);
static CanEvaluate originalCan;
static NSError *translated(NSInteger policy, NSError *error) {
    NSString *detail=error.userInfo[NSDebugDescriptionErrorKey];
    if(policy==1005 && [error.domain isEqualToString:LAErrorDomain] && error.code==-1000 &&
       [detail containsString:@"ACM verification of Oslo on ACMContext 0 failed: -3"]) {
        os_log_error(OS_LOG_DEFAULT,"Liter8MarketplaceConsent: using no-passcode branch after SEP-less ACM failure");
        return [NSError errorWithDomain:LAErrorDomain code:LAErrorPasscodeNotSet userInfo:nil];
    }
    return error;
}
static BOOL canEvaluate(id self, SEL sel, NSInteger policy, NSError **error) {
    NSError *nativeError=nil;
    BOOL result=originalCan(self,sel,policy,&nativeError);
    if(error)*error=result?nativeError:translated(policy,nativeError);
    return result;
}
static void evaluate(id self, SEL sel, NSInteger policy, NSDictionary *options, Reply reply) {
    if(policy!=1005 || !reply) { original(self,sel,policy,options,reply); return; }
    original(self,sel,policy,options,^(NSDictionary *result,NSError *error){reply(result,translated(policy,error));});
}
#ifndef LITER8_CONSENT_TEST
__attribute__((constructor)) static void install(void) {
    @autoreleasepool {
        char build[64]={0};size_t size=sizeof(build);
        if(strcmp(getprogname(),"AppDistributionLaunchAngel") || sysctlbyname("kern.osversion",build,&size,NULL,0) || strcmp(build,"23H30"))return;
        Class cls=NSClassFromString(@"LAContext");
        SEL sel=sel_registerName("evaluatePolicy:options:reply:");
        Method m=class_getInstanceMethod(cls,sel);
        if(!m || method_getNumberOfArguments(m)!=5)return;
        SEL canSel=sel_registerName("canEvaluatePolicy:error:");
        Method can=class_getInstanceMethod(cls,canSel);
        if(!can || method_getNumberOfArguments(can)!=4)return;
        originalCan=(CanEvaluate)method_setImplementation(can,(IMP)canEvaluate);
        original=(Evaluate)method_setImplementation(m,(IMP)evaluate);
        os_log_error(OS_LOG_DEFAULT,"Liter8MarketplaceConsent: installed pid=%d encoding=%{public}s",getpid(),method_getTypeEncoding(m));
    }
}
#else
int main(void) { @autoreleasepool {
 NSError *acm=[NSError errorWithDomain:LAErrorDomain code:-1000 userInfo:@{NSDebugDescriptionErrorKey:@"ACM verification of Oslo on ACMContext 0 failed: -3"}];
 NSError *cancel=[NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil];
 NSError *other=[NSError errorWithDomain:LAErrorDomain code:-1000 userInfo:nil];
 if(translated(1005,acm).code!=LAErrorPasscodeNotSet || translated(2,acm)!=acm || translated(1005,cancel)!=cancel || translated(1005,other)!=other || translated(1005,nil)!=nil)return 1;
 puts("PASS: exact Oslo failure translated; cancellation, other policies/errors and success preserved");return 0;
}}
#endif
