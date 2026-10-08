#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stddef.h>

extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);

// Read the current process's decrypted pages. Never obtains another process's
// task port or alters the original executable. Output is binary-only: no
// preferences, accounts, databases or application data are copied.
static BOOL dumpImage(uint32_t index, NSString *bundle, NSString *output) {
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(index);
    const char *name = _dyld_get_image_name(index);
    if (!header || header->magic != MH_MAGIC_64 || !name) return NO;
    NSString *path = [[NSString stringWithUTF8String:name] stringByResolvingSymlinksInPath];
    NSString *prefix = [bundle stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return NO;
    NSString *relative = [path substringFromIndex:prefix.length];
    if ([relative.pathComponents containsObject:@".."]) return NO;
    const uint8_t *commands = (const uint8_t *)(header + 1);
    uint64_t consumed = 0;
    const struct encryption_info_command_64 *encryption = NULL;
    const struct segment_command_64 *segment = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (consumed + sizeof(struct load_command) > header->sizeofcmds) return NO;
        const struct load_command *command = (const void *)(commands + consumed);
        if (command->cmdsize < sizeof(*command) || consumed + command->cmdsize > header->sizeofcmds) return NO;
        if (command->cmd == LC_ENCRYPTION_INFO_64 && command->cmdsize >= sizeof(*encryption)) encryption = (const void *)command;
        consumed += command->cmdsize;
    }
    if (!encryption || !encryption->cryptid || !encryption->cryptsize) return NO;
    consumed = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const void *)(commands + consumed);
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(*segment)) {
            const struct segment_command_64 *s = (const void *)command;
            if (encryption->cryptoff >= s->fileoff &&
                (uint64_t)encryption->cryptoff + encryption->cryptsize <= s->fileoff + s->filesize) segment = s;
        }
        consumed += command->cmdsize;
    }
    if (!segment) { NSLog(@"l8selfdump: no file-backed encrypted segment: %@", relative); return NO; }
    NSString *destination = [output stringByAppendingPathComponent:relative];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *temporary = [destination stringByAppendingString:@".partial"];
    int source = open(path.fileSystemRepresentation, O_RDONLY);
    int target = open(temporary.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0700);
    BOOL ok = source >= 0 && target >= 0;
    struct mach_header_64 disk;
    if (ok) ok = pread(source, &disk, sizeof(disk), 0) == sizeof(disk) &&
        disk.magic == MH_MAGIC_64 && disk.cputype == header->cputype && disk.ncmds == header->ncmds && disk.sizeofcmds == header->sizeofcmds;
    uint8_t buffer[16384];
    ssize_t bytes;
    if (ok) {
        while ((bytes = read(source, buffer, sizeof(buffer))) > 0) {
            ssize_t done = 0;
            while (done < bytes) {
                ssize_t w = write(target, buffer + done, bytes - done);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) { ok = NO; break; }
                done += w;
            }
            if (!ok) break;
        }
        if (bytes < 0) ok = NO;
    }
    mach_vm_address_t address = (mach_vm_address_t)(_dyld_get_image_vmaddr_slide(index) + segment->vmaddr + encryption->cryptoff - segment->fileoff);
    for (uint64_t done = 0; ok && done < encryption->cryptsize;) {
        mach_vm_size_t size = MIN(sizeof(buffer), encryption->cryptsize - done), received = 0;
        kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), address + done, size, (mach_vm_address_t)buffer, &received);
        if (kr != KERN_SUCCESS || received != size || pwrite(target, buffer, size, encryption->cryptoff + done) != (ssize_t)size) { ok = NO; break; }
        done += size;
    }
    uint32_t zero = 0;
    off_t cryptidOffset = (const uint8_t *)encryption - (const uint8_t *)header + offsetof(struct encryption_info_command_64, cryptid);
    if (ok) ok = pwrite(target, &zero, sizeof(zero), cryptidOffset) == sizeof(zero) && fsync(target) == 0;
    if (source >= 0) close(source);
    if (target >= 0) close(target);
    if (ok) ok = rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
    if (!ok) unlink(temporary.fileSystemRepresentation);
    NSLog(@"l8selfdump: %@ %@", ok ? @"decrypted" : @"FAILED (thin Mach-O required)", relative);
    return ok;
}

__attribute__((constructor)) static void start(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] ||
            access("/var/jb/.liter8-selfdump-telegram", F_OK)) return;
        NSLog(@"l8selfdump: loaded pid=%d", getpid());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSString *bundle = [NSBundle.mainBundle.bundlePath stringByResolvingSymlinksInPath];
                NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString *output = [documents stringByAppendingPathComponent:@"Liter8Decrypted/Telegram.app"];
                int count = 0;
                for (uint32_t i = 0; i < _dyld_image_count(); i++) count += dumpImage(i, bundle, output);
                NSLog(@"l8selfdump: finished images=%d output=%@", count, output);
            }
        });
    }
}
