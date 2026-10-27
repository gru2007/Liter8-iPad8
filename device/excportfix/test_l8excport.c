/*
 * Host test for l8excport.dylib, run by `./build.sh test`.
 *
 * Run once without arguments (control) and once with the path to a host build of the
 * shim. The shim is loaded with dlopen(), the way ElleKit's TweakLoader loads tweaks,
 * so a pass also proves that rebinding reaches an image that was bound before the shim
 * arrived. The control run shows the kernel here accepts the legacy behaviors, so a
 * handler that is missing in the shim run was dropped by the shim and not by the kernel.
 */

#include <dlfcn.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdio.h>

#if defined(__arm64__)
#define NATIVE_FLAVOR ARM_THREAD_STATE64
#else
#define NATIVE_FLAVOR x86_THREAD_STATE64
#endif

#define MASK EXC_MASK_BAD_ACCESS
#define LEGACY (EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES)
#define LEGACY_STATE (EXCEPTION_STATE_IDENTITY | MACH_EXCEPTION_CODES)
#define HARDENED (EXCEPTION_STATE_IDENTITY_PROTECTED | MACH_EXCEPTION_CODES)

static int failures;

#define CHECK(condition, ...)                                              \
    do {                                                                   \
        if (!(condition)) {                                                \
            fprintf(stderr, "FAIL line %d: ", __LINE__);                   \
            fprintf(stderr, __VA_ARGS__);                                  \
            fputc('\n', stderr);                                           \
            failures++;                                                    \
        }                                                                  \
    } while (0)

static mach_port_t new_handler_port(void)
{
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS ||
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) !=
            KERN_SUCCESS) {
        fprintf(stderr, "could not allocate a handler port\n");
        return MACH_PORT_NULL;
    }
    return port;
}

static mach_port_t task_handler(exception_behavior_t *behavior)
{
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    if (task_get_exception_ports(mach_task_self(), MASK, masks, &count, handlers, behaviors,
                                 flavors) != KERN_SUCCESS ||
        count == 0) {
        return MACH_PORT_NULL;
    }
    if (behavior) {
        *behavior = behaviors[0];
    }
    return handlers[0];
}

static mach_port_t thread_handler(thread_t thread)
{
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    if (thread_get_exception_ports(thread, MASK, masks, &count, handlers, behaviors,
                                   flavors) != KERN_SUCCESS ||
        count == 0) {
        return MACH_PORT_NULL;
    }
    return handlers[0];
}

static void clear_task(void)
{
    kern_return_t kr = task_set_exception_ports(mach_task_self(), MASK, MACH_PORT_NULL,
                                                LEGACY, THREAD_STATE_NONE);
    CHECK(kr == KERN_SUCCESS && task_handler(NULL) == MACH_PORT_NULL,
          "clearing the task handler failed: %d", kr);
}

static void clear_thread(thread_t thread)
{
    kern_return_t kr = thread_set_exception_ports(thread, MASK, MACH_PORT_NULL, LEGACY,
                                                  THREAD_STATE_NONE);
    CHECK(kr == KERN_SUCCESS && thread_handler(thread) == MACH_PORT_NULL,
          "clearing the thread handler failed: %d", kr);
}

int main(int argc, char **argv)
{
    bool shimmed = argc > 1;
    if (shimmed && !dlopen(argv[1], RTLD_NOW)) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    const char *run = shimmed ? "shim" : "control";

    mach_port_t first = new_handler_port();
    mach_port_t second = new_handler_port();
    if (!first || !second) {
        return 2;
    }

    /* task_set_exception_ports with a behavior the hardened policy refuses. */
    clear_task();
    kern_return_t kr = task_set_exception_ports(mach_task_self(), MASK, first, LEGACY,
                                                THREAD_STATE_NONE);
    CHECK(kr == KERN_SUCCESS, "%s: legacy task set returned %d", run, kr);
    CHECK((task_handler(NULL) == first) == !shimmed, "%s: legacy task handler %s", run,
          shimmed ? "was installed" : "is missing");

    /* A hardened behavior always reaches the kernel. */
    clear_task();
    kr = task_set_exception_ports(mach_task_self(), MASK, first, HARDENED, NATIVE_FLAVOR);
    exception_behavior_t behavior = 0;
    CHECK(kr == KERN_SUCCESS, "%s: hardened task set returned %d", run, kr);
    CHECK(task_handler(&behavior) == first && behavior == (exception_behavior_t)HARDENED,
          "%s: hardened task handler missing (behavior 0x%x)", run, (unsigned)behavior);

    /* task_swap_exception_ports with a refused behavior reports the current handler and,
     * under the shim, leaves it installed. */
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    kr = task_swap_exception_ports(mach_task_self(), MASK, second, LEGACY_STATE, NATIVE_FLAVOR,
                                   masks, &count, handlers, behaviors, flavors);
    CHECK(kr == KERN_SUCCESS, "%s: legacy task swap returned %d", run, kr);
    CHECK(count == 1 && handlers[0] == first &&
              behaviors[0] == (exception_behavior_t)HARDENED,
          "%s: legacy task swap reported the wrong previous handler", run);
    CHECK(task_handler(NULL) == (shimmed ? first : second),
          "%s: legacy task swap left the wrong handler installed", run);

    /* The thread variants. */
    thread_t thread = mach_thread_self();
    clear_thread(thread);
    kr = thread_set_exception_ports(thread, MASK, first, LEGACY, THREAD_STATE_NONE);
    CHECK(kr == KERN_SUCCESS, "%s: legacy thread set returned %d", run, kr);
    CHECK((thread_handler(thread) == first) == !shimmed, "%s: legacy thread handler %s", run,
          shimmed ? "was installed" : "is missing");

    clear_thread(thread);
    kr = thread_set_exception_ports(thread, MASK, first, HARDENED, NATIVE_FLAVOR);
    CHECK(kr == KERN_SUCCESS && thread_handler(thread) == first,
          "%s: hardened thread handler missing (%d)", run, kr);

    count = EXC_TYPES_COUNT;
    kr = thread_swap_exception_ports(thread, MASK, second, LEGACY, THREAD_STATE_NONE, masks,
                                     &count, handlers, behaviors, flavors);
    CHECK(kr == KERN_SUCCESS && count == 1 && handlers[0] == first,
          "%s: legacy thread swap returned %d with the wrong previous handler", run, kr);
    CHECK(thread_handler(thread) == (shimmed ? first : second),
          "%s: legacy thread swap left the wrong handler installed", run);

    clear_task();
    clear_thread(thread);
    printf("%s: %s\n", run, failures ? "FAILED" : "ok");
    return failures ? 1 : 0;
}
