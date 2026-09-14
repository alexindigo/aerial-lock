/*
 * aerial-unlock - native takeover-release for a stuck session lock
 *
 * One binary, two roles: manual recovery from a TTY, and the supervisor's
 * L2 escalation (d26b execs it after failed respawns). Native
 * C++/wayland-client only — zero shared runtime with aerial-lock, so a
 * Quickshell-side crash cannot take it down too.
 *
 * Exit codes:
 *   0  recovered (took over the lock and released it)
 *   1  no Wayland socket / environment (fatal, with guidance)
 *   2  inconclusive (neither locked nor finished within the timeout)
 *   3  refused (a LIVE client holds the lock; reports the PID + --purge hint)
 *
 * --purge first kills stale aerial-lock processes by explicit PID (/proc
 * discovery, never pattern matching), then proceeds identically.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <csignal>
#include <string>
#include <vector>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <wayland-client.h>
#include "ext-session-lock-v1-client.h"

static struct ext_session_lock_manager_v1 *lock_manager = nullptr;
static struct ext_session_lock_v1 *lock_obj = nullptr;
static int got_locked = 0;
static int got_finished = 0;

static const int TIMEOUT_MS = 5000;

/* ---- listeners ---- */

static void lock_locked(void *, struct ext_session_lock_v1 *)
{
    got_locked = 1;
}

static void lock_finished(void *, struct ext_session_lock_v1 *)
{
    got_finished = 1;
}

static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked,
    .finished = lock_finished,
};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version)
{
    (void)data; (void)version;
    if (strcmp(interface, "ext_session_lock_manager_v1") == 0) {
        lock_manager = static_cast<struct ext_session_lock_manager_v1 *>(
            wl_registry_bind(registry, name,
                             &ext_session_lock_manager_v1_interface, 1));
    }
}

static void registry_global_remove(void *, struct wl_registry *, uint32_t) {}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

/* ---- socket discovery ---- */

static std::string find_socket()
{
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (!xdg || !*xdg) {
        fprintf(stderr,
                "aerial-unlock: XDG_RUNTIME_DIR is not set.\n"
                "  From a TTY: export XDG_RUNTIME_DIR=/run/user/$(id -u)\n");
        return "";
    }

    std::vector<std::string> sockets;
    DIR *dir = opendir(xdg);
    if (!dir) {
        fprintf(stderr, "aerial-unlock: cannot open %s: %s\n", xdg, strerror(errno));
        return "";
    }
    struct dirent *ent;
    while ((ent = readdir(dir)) != nullptr) {
        const char *n = ent->d_name;
        if (strncmp(n, "wayland-", 8) != 0) continue;
        const char *suffix = n + 8;
        if (!*suffix || *suffix < '0' || *suffix > '9') continue;   // skip .lock
        std::string path = std::string(xdg) + "/" + n;
        struct stat st;
        if (stat(path.c_str(), &st) == 0 && S_ISSOCK(st.st_mode))
            sockets.push_back(path);
    }
    closedir(dir);

    if (sockets.empty()) {
        fprintf(stderr,
                "aerial-unlock: no Wayland socket found under %s\n"
                "  Expected wayland-N entries; check ls -la %s/wayland-*\n",
                xdg, xdg);
        return "";
    }

    const char *explicit_display = getenv("WAYLAND_DISPLAY");
    if (explicit_display && *explicit_display) {
        std::string path = std::string(xdg) + "/" + explicit_display;
        struct stat st;
        if (stat(path.c_str(), &st) == 0)
            return path;
    }
    return sockets.front();
}

/* ---- /proc discovery ---- */

static std::vector<int> find_aerial_lockers()
{
    std::vector<int> pids;
    const int self = getpid();
    DIR *proc = opendir("/proc");
    if (!proc) return pids;
    struct dirent *ent;
    while ((ent = readdir(proc)) != nullptr) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') continue;
        int pid = atoi(ent->d_name);
        if (pid <= 0 || pid == self) continue;
        char path[256];
        snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        char buf[4096];
        ssize_t n = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (n <= 0) continue;
        buf[n] = '\0';
        // NUL-separated args -> spaces for a single readable string
        for (ssize_t i = 0; i < n - 1; ++i)
            if (buf[i] == '\0') buf[i] = ' ';
        // skip if this is the tool itself (its own name in cmdline)
        if (strstr(buf, "aerial-unlock") != nullptr) continue;
        if (strstr(buf, "aerial-lock") != nullptr)
            pids.push_back(pid);
    }
    closedir(proc);
    return pids;
}

static bool purge_aerial_lockers()
{
    std::vector<int> pids = find_aerial_lockers();
    if (pids.empty()) return false;
    fprintf(stderr, "aerial-unlock: --purge found %d stale aerial-lock process(es):\n",
            static_cast<int>(pids.size()));
    for (int pid : pids) {
        fprintf(stderr, "  pid %d: SIGTERM\n", pid);
        kill(pid, SIGTERM);
    }
    usleep(500000);
    for (int pid : pids) {
        if (kill(pid, 0) == 0) {
            fprintf(stderr, "  pid %d: SIGKILL\n", pid);
            kill(pid, SIGKILL);
        }
    }
    usleep(300000);
    return true;
}

/* ---- main ---- */

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--purge]\n"
            "  Take over a stuck session lock and release it.\n"
            "  --purge   kill stale aerial-lock processes first (explicit PIDs)\n",
            argv0);
}

int main(int argc, char **argv)
{
    bool purge = false;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--purge") == 0) purge = true;
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]); return 0;
        } else {
            usage(argv[0]); return 2;
        }
    }

    if (purge) purge_aerial_lockers();

    std::string socket = find_socket();
    if (socket.empty()) return 1;

    // connect to the chosen socket explicitly (wl_display_connect honours
    // WAYLAND_DISPLAY for the name; set it to the absolute path)
    setenv("WAYLAND_DISPLAY", socket.c_str(), 1);
    struct wl_display *display = wl_display_connect(nullptr);
    if (!display) {
        fprintf(stderr, "aerial-unlock: failed to connect to %s\n", socket.c_str());
        return 1;
    }
    fprintf(stderr, "aerial-unlock: connected to %s\n", socket.c_str());

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, nullptr);
    wl_display_roundtrip(display);

    if (!lock_manager) {
        fprintf(stderr,
                "aerial-unlock: ext_session_lock_manager_v1 not available on this "
                "compositor\n  (cannot take over a lock that isn't exposed)\n");
        wl_registry_destroy(registry);
        wl_display_disconnect(display);
        return 1;
    }

    lock_obj = ext_session_lock_manager_v1_lock(lock_manager);
    ext_session_lock_v1_add_listener(lock_obj, &lock_listener, nullptr);

    // event loop with a hard timeout — roundtrip is fast; if nothing
    // arrives, the answer is inconclusive, not "hang forever"
    struct timeval start, now;
    gettimeofday(&start, nullptr);
    while (!got_locked && !got_finished) {
        if (wl_display_dispatch(display) < 0) break;
        gettimeofday(&now, nullptr);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                       (now.tv_usec - start.tv_usec) / 1000;
        if (elapsed > TIMEOUT_MS) break;
    }

    int rc;
    if (got_locked) {
        ext_session_lock_v1_unlock_and_destroy(lock_obj);
        wl_display_roundtrip(display);
        fprintf(stderr, "aerial-unlock: recovered — took over the lock and released it\n");
        rc = 0;
    } else if (got_finished) {
        // refusal: a live client already holds the lock
        fprintf(stderr,
                "aerial-unlock: refused — a live client already holds the lock.\n");
        std::vector<int> pids = find_aerial_lockers();
        if (!pids.empty()) {
            fprintf(stderr, "  likely holder(s):");
            for (int pid : pids) fprintf(stderr, " pid %d", pid);
            fprintf(stderr, "\n  retry with: aerial-unlock --purge\n");
        } else {
            fprintf(stderr,
                    "  no aerial-lock process found; the holder is another client.\n"
                    "  kill that client, then retry.\n");
        }
        rc = 3;
    } else {
        fprintf(stderr,
                "aerial-unlock: inconclusive — no locked/finished within %d ms.\n"
                "  compositor did not answer; retry or check it directly.\n",
                TIMEOUT_MS);
        rc = 2;
    }

    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return rc;
}
