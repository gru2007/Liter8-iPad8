#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Only replace this app's executable; preserve ownership and mode. */
int main(int argc, char **argv) {
    if (argc != 2 || strlen(argv[1]) != 36) return 2;
    for (int i = 0; i < 36; i++) {
        int dash = i == 8 || i == 13 || i == 18 || i == 23;
        if (dash ? argv[1][i] != '-' : !strchr("0123456789abcdefABCDEF", argv[1][i])) return 2;
    }
    char path[256], temp[280];
    snprintf(path, sizeof(path), "/var/containers/Bundle/Application/%s/TrollDecrypt.app/TrollDecrypt", argv[1]);
    snprintf(temp, sizeof(temp), "%s.liter8-new", path);
    struct stat st;
    if (lstat(path, &st) || !S_ISREG(st.st_mode)) return 3;
    int in = open("/var/tmp/l8-TrollDecrypt.launch", O_RDONLY | O_NOFOLLOW);
    int out = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0700);
    if (in < 0 || out < 0) { perror("open"); return 4; }
    char buf[65536]; ssize_t count;
    while ((count = read(in, buf, sizeof(buf))) != 0) {
        if (count < 0) { if (errno == EINTR) continue; goto fail; }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t wrote = write(out, buf + offset, count - offset);
            if (wrote < 0 && errno == EINTR) continue;
            if (wrote <= 0) goto fail;
            offset += wrote;
        }
    }
    if (fchown(out, st.st_uid, st.st_gid) || fchmod(out, st.st_mode & 0777) || fsync(out)) goto fail;
    if (close(out)) { out = -1; goto fail; }
    out = -1; close(in);
    if (rename(temp, path)) { unlink(temp); return 6; }
    return 0;
fail:
    perror("replace"); close(in); if (out >= 0) close(out); unlink(temp); return 5;
}
