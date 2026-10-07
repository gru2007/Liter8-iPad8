// personainfo - read-only dump of the persona and user-session state that
// alternative app stores (mobiledistributiond / AltStore / SideStore) and the
// Files "On My iPad" provider depend on.
//
// This never changes anything. The SEP-less boot never completed Setup, so the
// persona table and the per-user session are not what a normal boot produces,
// and an install that writes eligibility and injects mobiledistributiond still
// fails. Before writing a fix that runs at boot, we need to see exactly what is
// and is not present. Run this over SSH and send the full output back:
//
//   scp device/personafix/personainfo root@DEVICE:/var/jb/usr/bin/
//   ssh root@DEVICE /var/jb/usr/bin/personainfo
//
// It reports:
//   - every persona the kernel currently knows, ids 0..4999 (id, type, name)
//   - the calling process's persona id
//   - the data-volume paths a personal persona and File Provider need
//   - the relevant daemons present on the System volume
//
// The persona id Setup gives the device owner is not assumed: the scan shows
// what exists, and the types say which persona is the personal one.
//
// No entitlement is required to read this; kpersona_info and the path checks
// are available to any process.

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct kpersona_info {
    unsigned int persona_info_version;
    uid_t        persona_id;
    int          persona_type;
    gid_t        persona_gid;
    unsigned int persona_ngroups;
    gid_t        persona_groups[16];
    uid_t        persona_gmuid;
    char         persona_name[257];
};

typedef int (*info_t)(uid_t, struct kpersona_info *);
typedef int (*get_t)(uid_t *);

// Persona types from XNU bsd/sys/persona.h. 1-4 are long-standing; 5-8 were
// added later and are labelled for reading convenience only.
static const char *tname(int t) {
    switch (t) {
        case 1: return "GUEST";
        case 2: return "MANAGED";
        case 3: return "PRIV";
        case 4: return "SYSTEM";
        case 5: return "DEFAULT";
        case 6: return "SYSTEM_PROXY";
        case 7: return "SYS_EXT";
        case 8: return "ENTERPRISE";
        default: return "?";
    }
}

static void report_path(const char *path) {
    struct stat st;
    if (lstat(path, &st) == 0) {
        printf("  present  %s  (uid=%u gid=%u mode=%o)\n",
               path, st.st_uid, st.st_gid, st.st_mode & 07777);
    } else {
        printf("  MISSING  %s  (%s)\n", path, strerror(errno));
    }
}

int main(void) {
    printf("=== identity ===\n");
    printf("  uid=%d euid=%d gid=%d pid=%d\n", getuid(), geteuid(), getgid(), getpid());

    get_t kget = (get_t)dlsym(RTLD_DEFAULT, "kpersona_get");
    if (kget) {
        uid_t id = 0;
        if (kget(&id) == 0) {
            printf("  current persona id = %u\n", id);
        } else {
            printf("  current persona id = (none, errno=%d %s)\n", errno, strerror(errno));
        }
    }

    info_t kinfo = (info_t)dlsym(RTLD_DEFAULT, "kpersona_info");
    printf("\n=== persona table (ids 0..4999) ===\n");
    if (!kinfo) {
        printf("  kpersona_info unavailable\n");
    } else {
        int found = 0;
        for (uid_t id = 0; id < 5000; id++) {
            struct kpersona_info c;
            memset(&c, 0, sizeof(c));
            c.persona_info_version = 1;
            errno = 0;
            if (kinfo(id, &c) == 0) {
                printf("  id=%-4u type=%-8s gid=%-5u name=\"%s\"\n",
                       c.persona_id, tname(c.persona_type), c.persona_gid, c.persona_name);
                found++;
            }
        }
        if (!found) {
            printf("  (empty: the kernel knows no personas)\n");
        }
    }

    printf("\n=== data-volume state a personal persona / File Provider needs ===\n");
    report_path("/private/var/mobile");
    report_path("/private/var/mobile/Library");
    report_path("/private/var/mobile/Containers");
    report_path("/private/var/mobile/Library/UserConfigurationProfiles");
    report_path("/private/var/db/MobileIdentityData");
    report_path("/private/var/containers/Shared/SystemGroup");
    report_path("/private/var/MobileSoftwareUpdate");

    printf("\n=== daemons on the System volume ===\n");
    report_path("/usr/libexec/usermanagerd");
    report_path("/usr/libexec/installd");
    report_path("/System/Library/PrivateFrameworks/InstallCoordination.framework/Support/installcoordinationd");
    report_path("/System/Library/Frameworks/ManagedAppDistribution.framework/Support/managedappdistributiond");
    report_path("/private/var/keybags/usersession.kb");
    report_path("/private/var/keybags/persona.kb");

    printf("\n[personainfo] done. Send this whole output back.\n");
    return 0;
}
