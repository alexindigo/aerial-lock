#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "idle-inhibit-client.h"
#include "idle-xdg-shell-client.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *shell;
static struct zwp_idle_inhibit_manager_v1 *manager;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static volatile sig_atomic_t running = 1;

static void stop(int sig) { (void)sig; running = 0; }
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial)
{ (void)data; xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener shell_listener = {ping};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        shell = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(shell, &shell_listener, NULL);
    } else if (!strcmp(interface, "zwp_idle_inhibit_manager_v1"))
        manager = wl_registry_bind(registry, name, &zwp_idle_inhibit_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name)
{ (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = {global, removed};

static void frame(void *data, struct wl_callback *callback, uint32_t time)
{
    (void)data; (void)time;
    wl_callback_destroy(callback);
    puts("INHIBITOR_VISIBLE frame-presented");
    fflush(stdout);
}
static const struct wl_callback_listener frame_listener = {frame};
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial)
{
    (void)data;
    xdg_surface_ack_configure(xdg, serial);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, 320, 200);
    wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
    wl_surface_commit(surface);
}
static const struct xdg_surface_listener surface_listener = {configure};
static void size(void *data, struct xdg_toplevel *top, int32_t w, int32_t h, struct wl_array *states)
{ (void)data; (void)top; (void)w; (void)h; (void)states; }
static void close_surface(void *data, struct xdg_toplevel *top)
{ (void)data; (void)top; running = 0; }
static const struct xdg_toplevel_listener top_listener = {.configure = size, .close = close_surface};

int main(void)
{
    struct sigaction action = {.sa_handler = stop};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !shell || !manager) return 1;
    const size_t bytes = 320 * 200 * 4;
    int fd = memfd_create("aerial-idle-inhibit-probe", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)bytes) < 0) return 1;
    uint32_t *pixels = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) return 1;
    for (size_t i = 0; i < bytes / 4; ++i) pixels[i] = 0xff247ba0;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)bytes);
    buffer = wl_shm_pool_create_buffer(pool, 0, 320, 200, 320 * 4, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(shell, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_app_id(top, "aerial-idle-inhibit-probe");
    xdg_toplevel_set_title(top, "aerial-idle inhibitor probe");
    struct zwp_idle_inhibitor_v1 *inhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(manager, surface);
    wl_surface_commit(surface);
    while (running) {
        if (wl_display_dispatch_pending(display) < 0) break;
        wl_display_flush(display);
        struct pollfd input = {.fd = wl_display_get_fd(display), .events = POLLIN};
        int result = poll(&input, 1, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (input.revents & (POLLERR | POLLHUP | POLLNVAL))) break;
        if (input.revents & POLLIN && wl_display_dispatch(display) < 0) break;
    }
    zwp_idle_inhibitor_v1_destroy(inhibitor);
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(xdg);
    wl_surface_destroy(surface);
    wl_buffer_destroy(buffer);
    zwp_idle_inhibit_manager_v1_destroy(manager);
    xdg_wm_base_destroy(shell);
    wl_shm_destroy(shm);
    wl_compositor_destroy(compositor);
    wl_registry_destroy(registry);
    wl_display_flush(display);
    wl_display_disconnect(display);
    munmap(pixels, bytes);
    puts("INHIBITOR_RELEASED");
    return 0;
}
