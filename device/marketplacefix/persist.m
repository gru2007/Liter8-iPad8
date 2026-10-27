/* Reversible protection for the complete eligibility cache on iPad11,6/23H30.
 * File protection blocks writes; directory protection also blocks atomic replace.
 * Other cached feature eligibility answers will not refresh while locked.
 */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <errno.h>
static NSString *const file=@"/private/var/db/os_eligibility/eligibility.plist";
static NSString *const folder=@"/private/var/db/os_eligibility";
static BOOL supported(void) {
    char build[64]={0},machine[64]={0};size_t n=sizeof(build);
    if(sysctlbyname("kern.osversion",build,&n,NULL,0))return NO;
    n=sizeof(machine);
    return !sysctlbyname("hw.machine",machine,&n,NULL,0) &&
           !strcmp(build,"23H30") && !strcmp(machine,"iPad11,6");
}
int main(int argc,char **argv) { @autoreleasepool {
    if(!supported() || geteuid()!=0){fputs("Only root on iPad11,6/23H30 is supported\n",stderr);return 2;}
    struct stat f,d;
    if(lstat(file.fileSystemRepresentation,&f) || lstat(folder.fileSystemRepresentation,&d) ||
       !S_ISREG(f.st_mode) || !S_ISDIR(d.st_mode))return 3;
    if(argc==2 && !strcmp(argv[1],"status")) {
        printf("file_flags=%u directory_flags=%u file_locked=%d directory_locked=%d\n",
               f.st_flags,d.st_flags,!!(f.st_flags&UF_IMMUTABLE),!!(d.st_flags&UF_IMMUTABLE));return 0;
    }
    if(argc!=3)return 2;
    NSString *manifest=@(argv[2]);
    if(!strcmp(argv[1],"lock")) {
        if((f.st_flags|d.st_flags)&(UF_IMMUTABLE|SF_IMMUTABLE)){fputs("Existing immutable flag: refusing to replace its rollback state\n",stderr);return 4;}
        NSDictionary *state=@{@"file":file,@"folder":folder,@"file_flags":@(f.st_flags),@"folder_flags":@(d.st_flags)};
        NSError *error=nil;
        NSData *data=[NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        if(!data || ![data writeToFile:manifest options:NSDataWritingWithoutOverwriting error:&error] || chmod(manifest.fileSystemRepresentation,0600))return 5;
        if(chflags(file.fileSystemRepresentation,f.st_flags|UF_IMMUTABLE)) {perror("lock file");return 6;}
        if(chflags(folder.fileSystemRepresentation,d.st_flags|UF_IMMUTABLE)) {
            perror("lock directory");chflags(file.fileSystemRepresentation,f.st_flags);return 6;
        }
        puts("File and directory locked with UF_IMMUTABLE; rollback state saved.");return 0;
    }
    if(!strcmp(argv[1],"unlock")) {
        NSData *data=[NSData dataWithContentsOfFile:manifest];
        id state=data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
        if(![state isKindOfClass:[NSDictionary class]] || ![state[@"file"] isEqual:file] ||
           ![state[@"folder"] isEqual:folder] || ![state[@"file_flags"] isKindOfClass:[NSNumber class]] ||
           ![state[@"folder_flags"] isKindOfClass:[NSNumber class]])return 5;
        if(chflags(folder.fileSystemRepresentation,[state[@"folder_flags"] unsignedIntValue]) ||
           chflags(file.fileSystemRepresentation,[state[@"file_flags"] unsignedIntValue])){perror("unlock");return 6;}
        puts("Original flags restored.");return 0;
    }
    return 2;
}}
