#include "takeover.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "ext-session-lock-v1-client.h"

static struct ext_session_lock_manager_v1 *g_lock_manager = nullptr;
static struct ext_session_lock_v1 *g_lock = nullptr;
static int g_locked = 0;
static int g_finished = 0;

static void lock_locked(void *, struct ext_session_lock_v1 *) { g_locked = 1; }
static void lock_finished(void *, struct ext_session_lock_v1 *) { g_finished = 1; }

static const struct ext_session_lock_v1_listener lock_listener = {
    .locked = lock_locked,
    .finished = lock_finished,
};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version)
{
    (void)data; (void)version;
    if (strcmp(interface, "ext_session_lock_manager_v1") == 0) {
        g_lock_manager = static_cast<struct ext_session_lock_manager_v1 *>(
            wl_registry_bind(registry, name,
                             &ext_session_lock_manager_v1_interface, 1));
    }
}

static void registry_global_remove(void *, struct wl_registry *, uint32_t) {}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static std::string find_socket()
{
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (!xdg || !*xdg) return "";
    std::vector<std::string> sockets;
    DIR *dir = opendir(xdg);
    if (!dir) return "";
    struct dirent *ent;
    while ((ent = readdir(dir)) != nullptr) {
        const char *n = ent->d_name;
        if (strncmp(n, "wayland-", 8) != 0) continue;
        const char *suffix = n + 8;
        if (!*suffix || *suffix < '0' || *suffix > '9') continue;
        std::string path = std::string(xdg) + "/" + n;
        struct stat st;
        if (stat(path.c_str(), &st) == 0 && S_ISSOCK(st.st_mode))
            sockets.push_back(path);
    }
    closedir(dir);
    if (sockets.empty()) return "";
    const char *disp = getenv("WAYLAND_DISPLAY");
    if (disp && *disp) {
        std::string path = std::string(xdg) + "/" + disp;
        struct stat st;
        if (stat(path.c_str(), &st) == 0) return path;
    }
    return sockets.front();
}

Takeover::Outcome Takeover::run(int timeoutMs)
{
    std::string socket = find_socket();
    if (socket.empty()) return Outcome::NoSocket;

    setenv("WAYLAND_DISPLAY", socket.c_str(), 1);
    struct wl_display *display = wl_display_connect(nullptr);
    if (!display) return Outcome::NoSocket;

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, nullptr);
    wl_display_roundtrip(display);

    if (!g_lock_manager) {
        wl_registry_destroy(registry);
        wl_display_disconnect(display);
        return Outcome::NoSocket;
    }

    g_lock = ext_session_lock_manager_v1_lock(g_lock_manager);
    ext_session_lock_v1_add_listener(g_lock, &lock_listener, nullptr);

    struct timeval start, now;
    gettimeofday(&start, nullptr);
    while (!g_locked && !g_finished) {
        if (wl_display_dispatch(display) < 0) break;
        gettimeofday(&now, nullptr);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                       (now.tv_usec - start.tv_usec) / 1000;
        if (elapsed > timeoutMs) break;
    }

    Outcome outcome;
    if (g_locked) {
        ext_session_lock_v1_unlock_and_destroy(g_lock);
        wl_display_roundtrip(display);
        outcome = Outcome::Recovered;
    } else if (g_finished) {
        outcome = Outcome::Refused;
    } else {
        outcome = Outcome::Inconclusive;
    }

    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return outcome;
}
