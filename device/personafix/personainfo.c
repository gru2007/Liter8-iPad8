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
//   - every persona the kernel currently knows (id, type, name, uid/gid)
//   - the calling process's persona id
//   - whether the personal-persona id Setup normally creates (100) exists
//   - the data-volume paths a personal persona and File Provider need
//   - the relevant daemons present on the System volume
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
typedef int (*self_t)(void);

static const char *tname(int t) {
    switch (t) {
        case 1: return "GUEST";
        case 2: return "MANAGED";
        case 3: return "PRIV";
        case 4: return "SYSTEM";
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

    self_t kself = (self_t)dlsym(RTLD_DEFAULT, "kpersona_get");
    if (kself) {
        uid_t id = 0;
        // kpersona_get takes a uid_t* on this ABI; call defensively.
        int (*getfn)(uid_t *) = (int (*)(uid_t *))kself;
        if (getfn(&id) == 0) {
            printf("  current persona id = %u\n", id);
        } else {
            printf("  current persona id = (none, errno=%d %s)\n", errno, strerror(errno));
        }
    }

    info_t kinfo = (info_t)dlsym(RTLD_DEFAULT, "kpersona_info");
    printf("\n=== persona table (ids 0..200) ===\n");
    if (!kinfo) {
        printf("  kpersona_info unavailable\n");
    } else {
        int found = 0;
        for (uid_t id = 0; id <= 200; id++) {
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
        // 100 is the id Setup assigns the first personal (owner) persona.
        struct kpersona_info personal;
        memset(&personal, 0, sizeof(personal));
        personal.persona_info_version = 1;
        printf("\n  personal persona (id 100): %s\n",
               kinfo(100, &personal) == 0 ? "PRESENT" : "ABSENT");
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
    report_path("/usr/libexec/mobiledistributiond");
    report_path("/System/Library/PrivateFrameworks/MobileInstall.framework");
    report_path("/usr/libexec/installcoordinationd");
    report_path("/usr/libexec/fileproviderd");

    printf("\n[personainfo] done. Send this whole output back.\n");
    return 0;
}
