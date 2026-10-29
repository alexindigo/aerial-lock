#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "virtual-pointer-client.h"

/* Test-only persistent native input device. No response/input payload is logged. */
static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct wl_output *target_output;
static const char *wanted_output;
struct output { struct wl_output *object; char name[128]; };
static struct output outputs[32];
static unsigned output_count;
static void geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                     int32_t sp, const char *make, const char *model, int32_t tr) {
    (void)data; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)make; (void)model; (void)tr;
}
static void mode(void *data, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    (void)data; (void)o; (void)f; (void)w; (void)h; (void)r;
}
static void done(void *data, struct wl_output *o) { (void)data; (void)o; }
static void scale(void *data, struct wl_output *o, int32_t s) { (void)data; (void)o; (void)s; }
static void name(void *data, struct wl_output *o, const char *value) {
    struct output *output = data;
    snprintf(output->name, sizeof(output->name), "%s", value);
    if (wanted_output && !strcmp(wanted_output, value)) target_output = o;
}
static void description(void *data, struct wl_output *o, const char *value) { (void)data; (void)o; (void)value; }
static const struct wl_output_listener output_listener = {geometry, mode, done, scale, name, description};
static void global(void *data, struct wl_registry *registry, uint32_t id,
                   const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_seat") && !seat)
        seat = wl_registry_bind(registry, id, &wl_seat_interface, version < 7 ? version : 7);
    else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
        manager = wl_registry_bind(registry, id, &zwlr_virtual_pointer_manager_v1_interface, version < 2 ? version : 2);
    else if (!strcmp(interface, "wl_output") && version >= 4 && output_count < 32) {
        struct output *output = &outputs[output_count++];
        output->object = wl_registry_bind(registry, id, &wl_output_interface, 4);
        wl_output_add_listener(output->object, &output_listener, output);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
    (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener listener = {global, removed};

int main(int argc, char **argv) {
    wanted_output = argc > 1 ? argv[1] : NULL;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) return 2;
    if (wl_display_roundtrip(display) < 0 || (wanted_output && !target_output)) return 2;
    struct zwlr_virtual_pointer_v1 *pointer = target_output
        ? zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(manager, seat, target_output)
        : zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    if (wl_display_roundtrip(display) < 0) return 2;
    zwlr_virtual_pointer_v1_motion(pointer, 1, wl_fixed_from_int(0), wl_fixed_from_int(0));
    if (target_output) zwlr_virtual_pointer_v1_motion_absolute(pointer, 1, 640, 400, 1280, 800);
    zwlr_virtual_pointer_v1_frame(pointer);
    if (wl_display_roundtrip(display) < 0) return 2;
    puts("VIRTUAL_POINTER_READY");
    fflush(stdout);
    char command[256];
    while (fgets(command, sizeof(command), stdin)) {
        if (!strncmp(command, "map ", 4)) {
            char *newline = strchr(command + 4, '\n');
            if (newline) *newline = 0;
            if (wl_display_roundtrip(display) < 0) return 2;
            if (wl_display_roundtrip(display) < 0) return 2;
            struct wl_output *output = NULL;
            for (unsigned i = 0; i < output_count; ++i) {
                if (!strcmp(outputs[i].name, command + 4)) output = outputs[i].object;
            }
            if (!output) return 2;
            zwlr_virtual_pointer_v1_destroy(pointer);
            pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(manager, seat, output);
            zwlr_virtual_pointer_v1_motion_absolute(pointer, 4, 640, 400, 1280, 800);
            zwlr_virtual_pointer_v1_frame(pointer);
            if (wl_display_roundtrip(display) < 0) return 2;
            puts("VIRTUAL_POINTER_MAPPED");
            fflush(stdout);
        } else if (!strncmp(command, "unmap", 5)) {
            zwlr_virtual_pointer_v1_destroy(pointer);
            pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
            zwlr_virtual_pointer_v1_motion(pointer, 4, wl_fixed_from_int(0), wl_fixed_from_int(0));
            zwlr_virtual_pointer_v1_frame(pointer);
            if (wl_display_roundtrip(display) < 0) return 2;
            puts("VIRTUAL_POINTER_UNMAPPED");
            fflush(stdout);
        } else if (!strncmp(command, "click", 5)) {
            zwlr_virtual_pointer_v1_button(pointer, 2, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(pointer);
            zwlr_virtual_pointer_v1_button(pointer, 3, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
            if (wl_display_roundtrip(display) < 0) return 2;
            puts("VIRTUAL_POINTER_CLICKED");
            fflush(stdout);
        }
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    zwlr_virtual_pointer_manager_v1_destroy(manager);
    for (unsigned i = 0; i < output_count; ++i) wl_output_release(outputs[i].object);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 0;
}
