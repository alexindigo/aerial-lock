#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <link.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <pthread.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Only explicitly preloaded into disposable VM test children. No product hook,
 * input trace, logging payload, or credential data passes through this fixture. */
static const char *mode;
static pthread_mutex_t stream_mutex = PTHREAD_MUTEX_INITIALIZER;
static FILE *streams[32];

static int guard_module(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size; (void)data;
    return info->dlpi_name && strstr(info->dlpi_name, "libAerialLockConnectionGuard.so") != NULL;
}

static void drain_trap(void) {
    /* The preload is inherited by every process the launch wrapper runs before
     * it execs the locker. Trap only the exit of the process that armed the
     * connection guard, never helper commands. */
    if (!dl_iterate_phdr(guard_module, NULL)) return;
    const char marker[] = "GUARD_DRAIN_TRAP_ENTERED\n";
    write(STDERR_FILENO, marker, sizeof(marker) - 1);
    for (;;) pause();
}

__attribute__((constructor)) static void configure(void) {
    /* Keep the native dependency in this child's global preload lookup group;
     * no consumer DSO or installed product is promoted/replaced. */
    if (mpv_client_api_version() < MPV_MAKE_VERSION(2, 0)) _exit(90);
    mode = getenv("AERIAL_TEST_FULL_CALLER_FAULT");
    if (mode && strcmp(mode, "guard-exit-trap") == 0 && atexit(drain_trap)) _exit(90);
}

static void *symbol(const char *name) {
    dlerror();
    void *address = dlsym(RTLD_NEXT, name);
    if (!address || dlerror()) _exit(90);
    return address;
}

static int enabled(const char *value) {
    return mode && strcmp(mode, value) == 0;
}

static int guard_caller(void *caller) {
    Dl_info info = {0};
    return dladdr(caller, &info) && info.dli_fname && strstr(info.dli_fname, "libAerialLockConnectionGuard.so");
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                   void *(*entry)(void *), void *argument) {
    if (enabled("guard-thread-start") && guard_caller(__builtin_return_address(0))) {
        const char marker[] = "GUARD_THREAD_START_REJECTED\n";
        write(STDERR_FILENO, marker, sizeof(marker) - 1);
        return EAGAIN;
    }
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = symbol("pthread_create");
    return real_create(thread, attributes, entry, argument);
}

int poll(struct pollfd *descriptors, nfds_t count, int timeout) {
    if (guard_caller(__builtin_return_address(0))) {
        if (enabled("guard-poll-failure")) {
            const char marker[] = "GUARD_POLL_FAILURE_INJECTED\n";
            write(STDERR_FILENO, marker, sizeof(marker) - 1);
            errno = EBADF;
            return -1;
        }
        if (enabled("guard-eintr")) {
            static unsigned interrupted = 0;
            if (interrupted++ < 5) {
                const char marker[] = "GUARD_POLL_INTERRUPTED\n";
                write(STDERR_FILENO, marker, sizeof(marker) - 1);
                errno = EINTR;
                return -1;
            }
        }
    }
    int (*real_poll)(struct pollfd *, nfds_t, int) = symbol("poll");
    return real_poll(descriptors, count, timeout);
}

void mpv_terminate_destroy(mpv_handle *handle) {
    if (enabled("guard-retirement")) {
        const char marker[] = "CONNECTION_LOSS_RETIREMENT_HELD\n";
        write(STDERR_FILENO, marker, sizeof(marker) - 1);
        for (;;) pause();
    }
    void (*real_destroy)(mpv_handle *) = symbol("mpv_terminate_destroy");
    real_destroy(handle);
}

mpv_handle *mpv_create(void) {
    if (enabled("core-create")) {
        const char marker[] = "FULL_CALLER_CORE_CREATE_FAULT\n";
        write(STDERR_FILENO, marker, sizeof(marker) - 1);
        return NULL;
    }
    mpv_handle *(*real_create)(void) = symbol("mpv_create");
    return real_create();
}

int mpv_render_context_create(mpv_render_context **context, mpv_handle *handle,
                              mpv_render_param *parameters) {
    if (enabled("render-create")) {
        const char marker[] = "FULL_CALLER_RENDER_CREATE_FAULT\n";
        write(STDERR_FILENO, marker, sizeof(marker) - 1);
        return MPV_ERROR_UNSUPPORTED;
    }
    int (*real_create)(mpv_render_context **, mpv_handle *, mpv_render_param *)
        = symbol("mpv_render_context_create");
    return real_create(context, handle, parameters);
}

static FILE *watch(FILE *stream, const char *path) {
    /* Accent frame grabs: <runtime>/aerial-lock/locker-<pid>/accent-*.jpg */
    const char *file = strrchr(path, '/');
    if (stream && enabled("screenshot-write") && file && strncmp(file, "/accent-", 8) == 0 &&
        strstr(path, "/aerial-lock/locker-")) {
        pthread_mutex_lock(&stream_mutex);
        for (size_t i = 0; i < 32; ++i) {
            if (!streams[i]) { streams[i] = stream; break; }
        }
        pthread_mutex_unlock(&stream_mutex);
    }
    return stream;
}

FILE *fopen(const char *path, const char *mode_) {
    FILE *(*real_open)(const char *, const char *) = symbol("fopen");
    return watch(real_open(path, mode_), path);
}

FILE *fopen64(const char *path, const char *mode_) {
    FILE *(*real_open)(const char *, const char *) = symbol("fopen64");
    return watch(real_open(path, mode_), path);
}

size_t fwrite(const void *data, size_t size, size_t count, FILE *stream) {
    size_t (*real_write)(const void *, size_t, size_t, FILE *) = symbol("fwrite");
    int watched = 0;
    pthread_mutex_lock(&stream_mutex);
    for (size_t i = 0; i < 32; ++i) {
        if (streams[i] == stream) { streams[i] = NULL; watched = 1; break; }
    }
    pthread_mutex_unlock(&stream_mutex);
    if (watched) {
        const char held[] = "FULL_CALLER_SCREENSHOT_WRITE_HELD\n";
        write(STDERR_FILENO, held, sizeof(held) - 1);
        struct timespec delay = {5, 0};
        while (nanosleep(&delay, &delay) < 0) {}
        const char released[] = "FULL_CALLER_SCREENSHOT_WRITE_RELEASED\n";
        write(STDERR_FILENO, released, sizeof(released) - 1);
    }
    return real_write(data, size, count, stream);
}

int fclose(FILE *stream) {
    int (*real_close)(FILE *) = symbol("fclose");
    pthread_mutex_lock(&stream_mutex);
    for (size_t i = 0; i < 32; ++i) if (streams[i] == stream) streams[i] = NULL;
    pthread_mutex_unlock(&stream_mutex);
    return real_close(stream);
}
