/* Read-only probe. Run as a standalone executable with the target sandbox
 * profile, before considering a Data-volume location for the bootstrap. */
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) { fputs("usage: sandbox-path-probe PATH...\n", stderr); return 2; }
    for (int i = 1; i < argc; i++) {
        errno = 0;
        FILE *f = fopen(argv[i], "rb");
        int saved = errno;
        int byte = f ? fgetc(f) : EOF;
        if (f) fclose(f);
        printf("path=%s opened=%d readable=%d errno=%d\n", argv[i], f != NULL,
               byte != EOF, saved);
    }
    return 0;
}
