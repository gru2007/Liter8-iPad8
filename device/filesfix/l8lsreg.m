/*
 * l8lsreg - inspect and repair LaunchServices plug-in registration.
 *
 * Files' "On My iPad" is the LocalStorage File Provider extension,
 * com.apple.FileProvider.LocalStorage, which ships inside
 * FileProvider.framework/PlugIns rather than inside an app. A normal first boot
 * registers framework plug-ins with LaunchServices; the Liter8 boot never ran
 * that, and uicache only registers app bundles. With the extension missing,
 * fileproviderd reports "returning 0 providers" and Files shows no locations.
 *
 *   l8lsreg list [substring]     registered plug-ins (id, extension point, path)
 *   l8lsreg framework <path>     rebuild LaunchServices content for a framework
 *                                (registers the plug-ins it carries)
 *   l8lsreg plugin <path>        register one .appex
 *
 * Uses LSApplicationWorkspace, as uicache does, with uicache's entitlements.
 * Registration is LaunchServices data only: no file on disk is changed.
 * Build: device/filesfix/build.sh.
 */

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdio.h>

static id workspace(void) {
    Class cls = objc_lookUpClass("LSApplicationWorkspace");
    SEL shared = sel_registerName("defaultWorkspace");
    return cls ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
}

static id value(id object, NSString *key) {
    return [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil;
}

static int list(NSString *filter) {
    id ws = workspace();
    SEL installed = sel_registerName("installedPlugins");
    if (![ws respondsToSelector:installed]) {
        fprintf(stderr, "installedPlugins unavailable\n");
        return 1;
    }
    NSArray *plugins = ((id (*)(id, SEL))objc_msgSend)(ws, installed);
    unsigned shown = 0;
    for (id plugin in plugins) {
        NSString *identifier = value(plugin, @"pluginIdentifier");
        NSString *point = value(plugin, @"protocol");
        NSURL *url = value(plugin, @"bundleURL");
        NSString *line = [NSString stringWithFormat:@"%@  %@  %@", identifier, point, url.path];
        if (filter.length && [line rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        printf("%s\n", line.UTF8String);
        shown++;
    }
    printf("[l8lsreg] %u of %lu registered plug-ins shown\n", shown, (unsigned long)plugins.count);
    return 0;
}

static int framework(NSString *path) {
    id ws = workspace();
    SEL rebuild = sel_registerName("rebuildDatabaseContentForFrameworkAtURL:completionHandler:");
    if (![ws respondsToSelector:rebuild]) {
        fprintf(stderr, "rebuildDatabaseContentForFrameworkAtURL: unavailable\n");
        return 1;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    void (^handler)(NSError *) = ^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, NSURL *, id))objc_msgSend)(ws, rebuild, [NSURL fileURLWithPath:path], handler);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "[l8lsreg] timed out waiting for LaunchServices\n");
        return 1;
    }
    if (failure) {
        fprintf(stderr, "[l8lsreg] framework rebuild failed: %s\n", failure.description.UTF8String);
        return 1;
    }
    printf("[l8lsreg] rebuilt LaunchServices content for %s\n", path.UTF8String);
    return 0;
}

static int plugin(NSString *path) {
    id ws = workspace();
    SEL reg = sel_registerName("registerPlugin:");
    if (![ws respondsToSelector:reg]) {
        fprintf(stderr, "registerPlugin: unavailable\n");
        return 1;
    }
    BOOL ok = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(ws, reg, [NSURL fileURLWithPath:path]);
    printf("[l8lsreg] registerPlugin %s -> %s\n", path.UTF8String, ok ? "YES" : "NO");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!workspace()) {
            fprintf(stderr, "LSApplicationWorkspace unavailable\n");
            return 1;
        }
        if (argc >= 2 && !strcmp(argv[1], "list")) {
            return list(argc >= 3 ? @(argv[2]) : nil);
        }
        if (argc == 3 && !strcmp(argv[1], "framework")) return framework(@(argv[2]));
        if (argc == 3 && !strcmp(argv[1], "plugin")) return plugin(@(argv[2]));
        fprintf(stderr, "usage: l8lsreg list [substring] | framework <path> | plugin <path.appex>\n");
        return 2;
    }
}
