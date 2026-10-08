#include <mach/mach.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

// These MIG APIs are exported on iOS; the public iPhoneOS SDK omits the header.
extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t,
    mach_msg_type_number_t);

// Only reads/writes the child this diagnostic creates. No external PID, task
// zero, task termination or kernel memory access is attempted.
int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "--child")) {
        int report = atoi(argv[2]), release = atoi(argv[3]);
        volatile uint64_t witness = 0x4c385441534b5244ULL;
        uint64_t address = (uint64_t)(uintptr_t)&witness;
        if (report < 3 || release < 3 || write(report, &address, sizeof(address)) != sizeof(address)) return 2;
        char byte;
        if (read(release, &byte, 1) != 1) return 2;
        return witness == 0x4c385441534b5752ULL ? 0 : 3;
    }
    if (argc == 2 && !strcmp(argv[1], "--mobile")) {
        if (setgid(501) || setuid(501)) { perror("setuid"); return 2; }
        // Re-exec a non-setid image before creating the target. A mere UID
        // drop marks the forked target P_SUGID, which the POSIX task policy
        // deliberately rejects for non-root callers regardless of MACF hooks.
        char *worker[] = {argv[0], "--mobile-worker", NULL};
        execv(argv[0], worker);
        perror("exec mobile worker"); return 2;
    } else if (argc == 2 && !strcmp(argv[1], "--mobile-worker")) {
        if (getuid() != 501 || geteuid() != 501) return 2;
    } else if (argc != 1) { fprintf(stderr, "usage: taskprobe [--mobile]\n"); return 2; }
    setbuf(stdout, NULL);
    printf("caller uid=%u gid=%u issetugid=%d\n", getuid(), getgid(), issetugid());
    int report[2], release[2];
    if (pipe(report) || pipe(release)) return 2;
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        close(report[0]); close(release[1]);
        // Exec makes this a normal IPC-initialized target, rather than a
        // pre-exec fork child. It also clears the inherited set-id state.
        char report_fd[24], release_fd[24];
        snprintf(report_fd, sizeof report_fd, "%d", report[1]);
        snprintf(release_fd, sizeof release_fd, "%d", release[0]);
        char *target[] = {argv[0], "--child", report_fd, release_fd, NULL};
        execv(argv[0], target);
        _exit(2);
    }
    close(report[1]); close(release[0]);
    uint64_t address = 0, value = 0;
    mach_port_t task = MACH_PORT_NULL;
    int failed = 0;
    if (read(report[0], &address, sizeof(address)) != sizeof(address)) { failed = 1; goto done; }
    kern_return_t kr = task_for_pid(mach_task_self(), child, &task);
    printf("uid=%u child=%d task_for_pid=%d (%s) port=%u\n", getuid(), child, kr, mach_error_string(kr), task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) { failed = 1; goto done; }
    pid_t resolved = -1;
    kr = pid_for_task(task, &resolved);
    printf("pid_for_task=%d pid_matches=%d\n", kr, resolved == child);
    // Keep recording independent memory stages even if task-to-PID policy
    // rejects the port. The witness and child confirmation still identify it.
    if (kr != KERN_SUCCESS || resolved != child) failed = 1;
    mach_vm_size_t received = 0;
    kr = mach_vm_read_overwrite(task, address, sizeof(value), (mach_vm_address_t)&value, &received);
    printf("mach_vm_read=%d bytes=%llu witness_matches=%d\n", kr, received, value == 0x4c385441534b5244ULL);
    if (kr != KERN_SUCCESS || received != sizeof(value) || value != 0x4c385441534b5244ULL) { failed = 1; goto done; }
    value = 0x4c385441534b5752ULL;
    kr = mach_vm_write(task, address, (vm_offset_t)&value, sizeof(value));
    printf("mach_vm_write=%d (%s)\n", kr, mach_error_string(kr));
    if (kr != KERN_SUCCESS) failed = 1;
done:
    if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
    if (write(release[1], "x", 1) != 1) failed = 1;
    close(report[0]); close(release[1]);
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) failed = 1;
    printf("%s\n", failed ? "FAIL" : "PASS: foreign child task port, read and write verified");
    return failed;
}
