#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <QGenericPlugin>
#include <QGuiApplication>
#include <QtGui/qguiapplication_platform.h>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <new>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#if !QT_CONFIG(wayland)
#error AerialLockConnectionGuard requires the Qt public Wayland application interface
#endif

namespace {
constexpr int lostExit = 70;
constexpr int failedExit = 71;
constexpr int notEngagedExit = 72;
char moduleAnchor;
// Published before PAM can fork, and never changed in the parent after arming.
int inheritedDescriptor = -1;

struct Monitor {
    int descriptor = -1;
    pthread_t thread{};
    std::atomic<bool> started{false};
    void *modulePin = nullptr;
};

[[noreturn]] void fail() noexcept { ::_exit(failedExit); }
// Only arming runs here, at plugin load before QML can create a lock.
[[noreturn]] void failArming() noexcept { ::_exit(notEngagedExit); }

void childCleanup() noexcept {
    const int descriptor = inheritedDescriptor;
    inheritedDescriptor = -1;
    if (descriptor >= 0) ::close(descriptor); // never shutdown the parent's shared socket
}

void *pinLoadedModule() {
    Dl_info identity{};
    if (!dladdr(&moduleAnchor, &identity) || !identity.dli_fname || !identity.dli_fbase) failArming();
    char *path = realpath(identity.dli_fname, nullptr);
    if (!path) failArming();
    void *pin = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE);
    std::free(path);
    if (!pin) failArming();
    link_map *map = nullptr;
    if (dlinfo(pin, RTLD_DI_LINKMAP, &map) || !map
        || reinterpret_cast<void *>(map->l_addr) != identity.dli_fbase) failArming();
    return pin; // process lifetime, independent of QObject/factory teardown
}

bool terminalSocketError(int error) noexcept {
    return error == EPIPE || error == ECONNRESET || error == ECONNABORTED
        || error == ENOTCONN || error == ESHUTDOWN;
}

void backoff() noexcept {
    timespec delay{0, 10000000};
    while (nanosleep(&delay, &delay) && errno == EINTR) {}
}

void *watch(void *argument) noexcept {
    auto *monitor = static_cast<Monitor *>(argument);
    monitor->started.store(true, std::memory_order_release);
    unsigned uncertain = 0;
    for (;;) {
        // POLLIN is intentionally absent. Never consume, peek, dispatch or flush
        // protocol data, and never spin on ordinary unread Wayland messages.
        pollfd descriptor{monitor->descriptor, POLLRDHUP, 0};
        const int result = poll(&descriptor, 1, -1);
        if (result < 0) {
            if (errno == EINTR) continue;
            fail();
        }
        if (!result) continue;
        if (descriptor.revents & (POLLHUP | POLLRDHUP)) ::_exit(lostExit);
        if (descriptor.revents & POLLNVAL) fail();
        if (descriptor.revents & POLLERR) {
            int error = 0;
            socklen_t size = sizeof(error);
            if (getsockopt(monitor->descriptor, SOL_SOCKET, SO_ERROR, &error, &size)) {
                if (errno == EINTR) continue;
                fail();
            }
            // SO_ERROR is get-and-clear: inspect it only after an error poll.
            if (terminalSocketError(error)) ::_exit(lostExit);
        }
        // A persistent unconfirmed/descriptor failure is guard failure, never
        // fictitious transport loss or silently abandoned monitoring.
        if (++uncertain >= 100) fail();
        backoff();
    }
}

bool authorized() {
    const QByteArray owner = qgetenv("AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID");
    if (owner.isEmpty()) return false;
    bool valid = false;
    const qlonglong pid = owner.toLongLong(&valid);
    return valid && pid == static_cast<qlonglong>(getpid());
}

void arm() {
    if (!qGuiApp) failArming();
    auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    if (!native || !native->display()) failArming();
    const int original = wl_display_get_fd(native->display());
    if (original < 0) failArming();
    auto *monitor = new (std::nothrow) Monitor;
    if (!monitor || inheritedDescriptor >= 0) failArming();
    monitor->modulePin = pinLoadedModule();
    monitor->descriptor = fcntl(original, F_DUPFD_CLOEXEC, 3);
    if (monitor->descriptor < 0) failArming();
    inheritedDescriptor = monitor->descriptor;
    if (pthread_atfork(nullptr, nullptr, childCleanup)) failArming();
    if (pthread_create(&monitor->thread, nullptr, watch, monitor)) failArming();
    while (!monitor->started.load(std::memory_order_acquire)) sched_yield();
    if (!qputenv("AERIAL_LOCK_CONNECTION_GUARD_PID", QByteArray::number(getpid()))) failArming();
}
} // namespace

class AerialLockConnectionGuard final : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "connection-guard.json")
public:
    QObject *create(const QString &name, const QString &specification) override {
        Q_UNUSED(specification)
        if (name.compare(QStringLiteral("AerialLockConnectionGuard"), Qt::CaseInsensitive) != 0)
            return nullptr;
        if (authorized()) arm();
        // The inert facade may be deleted by Qt. It owns no monitor state and
        // never joins the native thread or closes the guard's duplicate.
        return new QObject;
    }
};

#include "connection-guard.moc"
