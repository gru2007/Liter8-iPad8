/* Explicit, build-scoped disk edit for the experimentally booted iPad 8.
 * Reads the current plist; changes only the seven tested domain answers.
 * No region/account input rewriting, immutable flags, or eligibilityd hooks.
 */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <string.h>
#ifndef L8_ELIGIBILITY_TARGET
#define L8_ELIGIBILITY_TARGET "/private/var/db/os_eligibility/eligibility.plist"
#endif
static NSString *const target=@L8_ELIGIBILITY_TARGET;
static BOOL supported(void) {
#ifdef LITER8_ELIGIBILITY_HOST_TEST
    return YES;
#else
    char build[64]={0},machine[64]={0};size_t n=sizeof(build);
    if(sysctlbyname("kern.osversion",build,&n,NULL,0))return NO;
    n=sizeof(machine);
    return !sysctlbyname("hw.machine",machine,&n,NULL,0) &&
        !strcmp(build,"23H30") && !strcmp(machine,"iPad11,6");
#endif
}
static BOOL write_verified(NSData *data,NSString *path,NSError **error) {
    struct stat st;
    if(stat(path.fileSystemRepresentation,&st))return NO;
    if(![data writeToFile:path options:NSDataWritingAtomic error:error])return NO;
    return chown(path.fileSystemRepresentation,st.st_uid,st.st_gid)==0 &&
        chmod(path.fileSystemRepresentation,st.st_mode&0777)==0 &&
        [[NSData dataWithContentsOfFile:path] isEqualToData:data];
}
int main(int argc,char **argv) { @autoreleasepool {
    if(!supported()){fputs("Only iPad11,6 / 23H30 is validated\n",stderr);return 2;}
    if(argc==2 && !strcmp(argv[1],"check")){puts("Device guard passed");return 0;}
    if(argc!=3 || (strcmp(argv[1],"apply") && strcmp(argv[1],"restore")))return 2;
    NSError *error=nil;NSString *backup=@(argv[2]);
    NSData *original=[NSData dataWithContentsOfFile:target];
    if(!original)return 3;
    NSData *output=nil;
    if(!strcmp(argv[1],"restore")) {
        output=[NSData dataWithContentsOfFile:backup];
        if(!output || ![NSPropertyListSerialization propertyListWithData:output options:0 format:NULL error:&error])return 4;
    } else {
        id plist=[NSPropertyListSerialization propertyListWithData:original options:NSPropertyListMutableContainers format:NULL error:&error];
        if(![plist isKindOfClass:[NSMutableDictionary class]])return 4;
        for(NSString *domain in @[@"HYDROGEN",@"HELIUM",@"LITHIUM",@"CARBON",@"ARGON",@"POTASSIUM",@"SEARCH_MARKETPLACES"]) {
            NSString *key=[@"OS_ELIGIBILITY_DOMAIN_" stringByAppendingString:domain];
            id entry=plist[key];
            if(![entry isKindOfClass:[NSMutableDictionary class]] || !entry[@"os_eligibility_answer_t"] || !entry[@"os_eligibility_answer_source_t"])return 4;
            entry[@"os_eligibility_answer_t"]=@4;
            entry[@"os_eligibility_answer_source_t"]=@2;
        }
        output=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        if(!output)return 4;
        // Never replace an earlier rollback point.
        if(![original writeToFile:backup options:NSDataWritingWithoutOverwriting error:&error])return 5;
        if(chmod(backup.fileSystemRepresentation,0600))return 5;
    }
    if(!write_verified(output,target,&error)) {
        fprintf(stderr,"Write/readback failed: %s\n",error.description.UTF8String?:"metadata or I/O failure");return 6;
    }
    puts("Eligibility written; disk readback verified");return 0;
}}
