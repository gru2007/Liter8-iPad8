#import <Foundation/Foundation.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
 @autoreleasepool {
  if (argc == 2 && !strcmp(argv[1], "mg-write")) {
   NSString *path=@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
   NSData *data=[NSData dataWithContentsOfFile:@"/var/tmp/l8-mobilegestalt-new.plist"];
   NSError *error=nil;
   if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) { NSLog(@"MG write: %@",error); return 4; }
   chown(path.fileSystemRepresentation,501,501); chmod(path.fileSystemRepresentation,0644);
   return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "airdrop")) {
   if (setgid(501) || setuid(501)) return 1;
   CFStringRef app=CFSTR("com.apple.sharingd");
   CFPreferencesSetValue(CFSTR("DiscoverableMode"), CFSTR("Everyone"), app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
   CFPreferencesSetValue(CFSTR("OverrideTimeLimitEveryoneMode"), kCFBooleanTrue, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
   if (!CFPreferencesSynchronize(app,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) return 2;
   CFPropertyListRef value=CFPreferencesCopyValue(CFSTR("DiscoverableMode"),app,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
   NSLog(@"AirDrop mode: %@", (__bridge id)value);
   if(value) CFRelease(value);
   return 0;
  }
  void *h=dlopen("/usr/lib/libMobileGestalt.dylib",RTLD_NOW);
  bool (*get)(CFStringRef)=h?dlsym(h,"MGGetBoolAnswer"):NULL;
  if(!get) return 3;
  printf("SecurityResearchDevice=%d\n",get(CFSTR("IsSecurityResearchDevice")));
  return 0;
 }
}
