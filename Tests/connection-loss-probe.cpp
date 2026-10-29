#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <QCoreApplication>
#include <QGuiApplication>
#include <QGenericPlugin>
#include <QPluginLoader>
#include <QtGui/qguiapplication_platform.h>
#include <QProcess>
#include <QProcessEnvironment>
#include <QDir>
#include <QFileInfo>
#include <QElapsedTimer>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <csignal>
#include <thread>
#include <memory>
#include <vector>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <wayland-client.h>

// A byte-preserving relay: receiving one byte per recvmsg keeps SCM_RIGHTS at
// its exact stream position instead of guessing which coalesced message owns it.
// No input/protocol bytes are logged. The parent closes only this child's peer.
struct Relay {
    int listener = -1;
    std::atomic<int> downstream{-1};
    std::atomic<int> upstream{-1};
    std::atomic<bool> closing{false};
    std::atomic<bool> failed{false};
    std::atomic<unsigned> accepted{0};
    QString path;
    QString target;
    std::thread worker;
    std::thread connection;
    std::vector<std::unique_ptr<Relay>> peers;

    static int connectTo(const QString &path) {
        const int descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (descriptor < 0) return -1;
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        const QByteArray encoded = QFileInfo(path).absoluteFilePath().toUtf8();
        if (encoded.size() >= static_cast<int>(sizeof(address.sun_path))) { close(descriptor); return -1; }
        std::memcpy(address.sun_path, encoded.constData(), static_cast<size_t>(encoded.size()) + 1);
        if (connect(descriptor, reinterpret_cast<sockaddr *>(&address), sizeof(address))) { close(descriptor); return -1; }
        return descriptor;
    }

    void pump(int source, int destination) {
        while (!closing.load()) {
            char byte;
            iovec data{&byte, 1};
            alignas(cmsghdr) std::array<char, CMSG_SPACE(256 * sizeof(int))> ancillary{};
            msghdr message{};
            message.msg_iov = &data;
            message.msg_iovlen = 1;
            message.msg_control = ancillary.data();
            message.msg_controllen = ancillary.size();
            const ssize_t received = recvmsg(source, &message, 0);
            if (received < 0 && errno == EINTR) continue;
            if (received <= 0) break;
            if (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) { failed.store(true); break; }
            ssize_t sent;
            do { sent = sendmsg(destination, &message, MSG_NOSIGNAL); } while (sent < 0 && errno == EINTR);
            // The receiver owns duplicates after sendmsg. Always close relay copies.
            for (cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
                if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS) {
                    const size_t count = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
                    const auto *descriptors = reinterpret_cast<const int *>(CMSG_DATA(header));
                    for (size_t i = 0; i < count; ++i) close(descriptors[i]);
                }
            }
            if (sent != 1) { if (!closing.load()) failed.store(true); break; }
        }
    }

    void startConnection(int client) {
        downstream.store(client);
        const int server = connectTo(target);
        upstream.store(server);
        if (server < 0) { failed.store(true); shutdown(client, SHUT_RDWR); return; }
        connection = std::thread([this, client, server]() {
            std::thread reverse([this, client, server]() { pump(server, client); });
            pump(client, server);
            closing.store(true);
            shutdown(server, SHUT_RDWR);
            shutdown(client, SHUT_RDWR);
            reverse.join();
        });
    }

    bool start() {
        listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (listener < 0) return false;
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        const QByteArray encoded = path.toUtf8();
        if (encoded.size() >= static_cast<int>(sizeof(address.sun_path))) return false;
        std::memcpy(address.sun_path, encoded.constData(), static_cast<size_t>(encoded.size()) + 1);
        if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(listener, 4)) return false;
        worker = std::thread([this]() {
            while (!closing.load()) {
                const int client = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
                if (client < 0 && errno == EINTR) continue;
                if (client < 0) { if (!closing.load()) failed.store(true); return; }
                accepted.fetch_add(1);
                if (downstream.load() < 0) {
                    // Qt's platform connection precedes generic-plugin arming
                    // and QML construction; this alone is the loss target.
                    startConnection(client);
                } else {
                    // libmpv opens another connection during bootstrap. Keep
                    // it independent of the actual guarded Qt loss target.
                    auto peer = std::make_unique<Relay>();
                    peer->target = target;
                    peer->startConnection(client);
                    peers.push_back(std::move(peer));
                }
            }
        });
        return true;
    }

    bool loseConnection() {
        const int client = downstream.load();
        if (client < 0) return false;
        closing.store(true);
        return shutdown(client, SHUT_RDWR) == 0;
    }

    ~Relay() {
        closing.store(true);
        if (listener >= 0) shutdown(listener, SHUT_RDWR);
        if (downstream.load() >= 0) shutdown(downstream.load(), SHUT_RDWR);
        if (upstream.load() >= 0) shutdown(upstream.load(), SHUT_RDWR);
        if (worker.joinable()) worker.join();
        if (connection.joinable()) connection.join();
        peers.clear();
        if (listener >= 0) close(listener);
        if (downstream.load() >= 0) close(downstream.load());
        if (upstream.load() >= 0) close(upstream.load());
        if (!path.isEmpty()) ::unlink(path.toUtf8().constData());
    }
};

// This is a terminal test failure, not a cleanup timeout. Keep the process and
// its peer alive until the child itself exits. Ordinary terminal/SSH-disconnect
// signals must not turn a failed observation into indirect locker termination.
static int holdBlocked(QProcess *child, qint64 pid, const QString &root,
                       const char *reason) {
    for (int signal : {SIGHUP, SIGINT, SIGTERM, SIGPIPE}) std::signal(signal, SIG_IGN);
    QSaveFile receipt(root + QStringLiteral("/run/blocked-qs-%1.json").arg(pid));
    if (receipt.open(QIODevice::WriteOnly)) {
        const QJsonObject record{{"status", "BLOCKED"}, {"locker_pid", pid},
            {"probe_pid", static_cast<qint64>(getpid())}, {"reason", reason}};
        receipt.write(QJsonDocument(record).toJson());
        if (!receipt.commit()) std::fprintf(stderr, "BLOCKED receipt write failed\n");
    } else std::fprintf(stderr, "BLOCKED receipt open failed\n");
    std::fprintf(stderr, "BLOCKED_QS_PID %lld PROBE_PID %ld; %s; retaining peer, no termination authorized\n",
                 static_cast<long long>(pid), static_cast<long>(getpid()), reason);
    std::fflush(stderr);
    while (child->state() != QProcess::NotRunning) {
        child->waitForFinished(250);
        // Drain without persisting any unexpected input-bearing output.
        child->readAll();
    }
    std::fprintf(stderr, "BLOCKED_CHILD_EXITED_NATURALLY %lld exit=%d; result remains BLOCKED\n",
                 static_cast<long long>(pid), child->exitCode());
    delete child;
    return 3;
}

// Non-locker safety regression: exchange data through the actual relay while
// the probe holds its BLOCKED branch. The peer chooses its own normal exit.
static int latchPeer(const QString &path) {
    const int fd = Relay::connectTo(path);
    if (fd < 0) return 1;
    std::puts("LATCH_PEER_READY");
    std::fflush(stdout);
    for (int i = 0; i < 20; ++i) {
        const char sent = 'x';
        char received = 0;
        if (send(fd, &sent, 1, MSG_NOSIGNAL) != 1 || recv(fd, &received, 1, 0) != 1 || received != sent) return 1;
        usleep(50000);
    }
    close(fd);
    return 0;
}

static int latchHarness(const QString &root) {
    const QString target = root + QStringLiteral("/run/latch-echo-%1.sock").arg(getpid());
    const int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    const QByteArray encoded = target.toUtf8();
    if (listener < 0 || encoded.size() >= static_cast<int>(sizeof(address.sun_path))) return 2;
    std::memcpy(address.sun_path, encoded.constData(), encoded.size() + 1);
    if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(listener, 1)) return 2;
    std::thread echo([listener]() {
        const int peer = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
        char byte;
        while (peer >= 0 && recv(peer, &byte, 1, 0) == 1) {
            if (send(peer, &byte, 1, MSG_NOSIGNAL) != 1) break;
        }
        if (peer >= 0) close(peer);
    });
    Relay relay;
    relay.path = root + QStringLiteral("/run/latch-relay-%1.sock").arg(getpid());
    relay.target = target;
    if (!relay.start()) {
        shutdown(listener, SHUT_RDWR);
        echo.join();
        close(listener);
        ::unlink(encoded.constData());
        return 2;
    }
    auto *peer = new QProcess;
    peer->setProcessChannelMode(QProcess::MergedChannels);
    peer->start(QCoreApplication::applicationFilePath(), {"--latch-peer", relay.path});
    if (!peer->waitForStarted(5000)) return 2;
    const qint64 pid = peer->processId();
    const int result = holdBlocked(peer, pid, root, "native echo-peer ownership regression");
    echo.join();
    close(listener);
    ::unlink(encoded.constData());
    return result;
}

static int sameSocketDescriptors(int original) {
    struct stat reference{};
    if (fstat(original, &reference)) return -1;
    int count = 0;
    for (int fd = 0; fd < 256; ++fd) {
        struct stat value{};
        if (!fstat(fd, &value) && value.st_dev == reference.st_dev && value.st_ino == reference.st_ino) ++count;
    }
    return count;
}

static int lifecycleChild(int argc, char **argv) {
    if (argc != 3) return 2;
    const QString root = QString::fromUtf8(argv[2]);
    qunsetenv("QT_QPA_GENERIC_PLUGINS");
    QGuiApplication application(argc, argv);
    auto *native = application.nativeInterface<QNativeInterface::QWaylandApplication>();
    if (!native || !native->display()) return 2;
    wl_display *display = native->display();
    const int original = wl_display_get_fd(display);
    const int before = sameSocketDescriptors(original);
    QPluginLoader loader(root + "/stage/usr/lib/aerial-lock/qt-plugins/generic/libAerialLockConnectionGuard.so");
    auto *factory = qobject_cast<QGenericPlugin *>(loader.instance());
    if (!factory || before < 1) return 2;
    qputenv("AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID", QByteArray::number(getpid()));
    QObject *facade = factory->create("AerialLockConnectionGuard", QString());
    if (!facade || qgetenv("AERIAL_LOCK_CONNECTION_GUARD_PID") != QByteArray::number(getpid())
        || sameSocketDescriptors(original) != before + 1) return 1;
    delete facade;
    loader.unload(); // native NODELETE pin retains monitor and atfork code
    if (sameSocketDescriptors(original) != before + 1) return 1;
    int reply[2];
    if (pipe2(reply, O_CLOEXEC)) return 2;
    const pid_t forked = fork();
    if (forked < 0) return 2;
    if (forked == 0) {
        close(reply[0]);
        const int count = sameSocketDescriptors(original);
        const bool valid = write(reply[1], &count, sizeof(count)) == sizeof(count) && count == before;
        ::_exit(valid ? 0 : 1); // no exec; original display fd must remain intact
    }
    close(reply[1]);
    int count = -1;
    const ssize_t received = read(reply[0], &count, sizeof(count));
    close(reply[0]);
    int status = 0;
    if (waitpid(forked, &status, 0) != forked || received != sizeof(count) || count != before
        || !WIFEXITED(status) || WEXITSTATUS(status) || sameSocketDescriptors(original) != before + 1) return 1;
    QProcess child;
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.insert("QT_QPA_PLATFORM", "offscreen");
    environment.insert("QT_PLUGIN_PATH", root + "/stage/usr/lib/aerial-lock/qt-plugins");
    environment.insert("QT_QPA_GENERIC_PLUGINS", "AerialLockConnectionGuard");
    child.setProcessEnvironment(environment);
    child.start(QCoreApplication::applicationFilePath(), {"--guard-unrelated-child"});
    if (!child.waitForFinished(5000) || child.exitStatus() != QProcess::NormalExit || child.exitCode()) return 1;
    // Hold a prepared reader, so Qt's event reader cannot consume the next
    // sync reply. This proves ordinary unread data exists on the actual fd.
    auto *queue = wl_display_create_queue(display);
    auto *callback = wl_display_sync(display);
    if (!queue || !callback) return 2;
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(callback), queue);
    if (wl_display_prepare_read_queue(display, queue)) return 2;
    if (wl_display_flush(display) < 0 && errno != EAGAIN) return 2;
    pollfd descriptor{original, POLLIN, 0};
    if (poll(&descriptor, 1, 1000) != 1 || !(descriptor.revents & POLLIN)) return 1;
    std::puts("GUARD_LIFECYCLE_FACADE_DELETED_FORK_CLEAN_CHILD_INERT_UNREAD_DATA");
    std::puts("CONNECTION_LOSS_READY");
    std::fflush(stdout);
    for (;;) pause(); // no dispatch/cancel/drain; independent monitor must exit
}

int main(int argc, char **argv) {
    if (argc > 1 && !std::strcmp(argv[1], "--guard-lifecycle-child")) return lifecycleChild(argc, argv);
    if (argc > 1 && !std::strcmp(argv[1], "--guard-unrelated-child")) {
        QGuiApplication application(argc, argv);
        return qgetenv("AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID") == QByteArray::number(getpid())
            || qgetenv("AERIAL_LOCK_CONNECTION_GUARD_PID") == QByteArray::number(getpid()) ? 1 : 0;
    }
    QCoreApplication application(argc, argv);
    const QStringList args = application.arguments();
    if (args.size() == 3 && args[1] == "--latch-peer") return latchPeer(args[2]);
    if (args.size() == 3 && args[1] == "--latch-harness") return latchHarness(args[2]);
    QString root;
    QString shell;
    QString vmRecord;
    QString sessionRecord;
    QString fault;
    QByteArray ready("CONNECTION_LOSS_READY");
    int intactMilliseconds = 0;
    bool nativeLifecycle = false;
    bool blocked = false;
    for (int i = 1; i < args.size(); ++i) {
        if (args[i] == "--root" && i + 1 < args.size()) root = args[++i];
        else if (args[i] == "--vm-record" && i + 1 < args.size()) vmRecord = args[++i];
        else if (args[i] == "--session-record" && i + 1 < args.size()) sessionRecord = args[++i];
        else if (args[i] == "--shell-dir" && i + 1 < args.size()) shell = args[++i];
        else if (args[i] == "--blocked-gui") blocked = true;
        else if (args[i] == "--fault" && i + 1 < args.size()) fault = args[++i];
        else if (args[i] == "--ready-marker" && i + 1 < args.size()) ready = args[++i].toUtf8();
        else if (args[i] == "--intact-ms" && i + 1 < args.size()) intactMilliseconds = args[++i].toInt();
        else if (args[i] == "--native-lifecycle") nativeLifecycle = true;
        else return 2;
    }
    if (root.isEmpty() || shell.isEmpty() || vmRecord.isEmpty() || sessionRecord.isEmpty()) return 2;
    QProcess ownership;
    ownership.start(QStringLiteral("python3"),
                    {root + "/src/aerial-lock/Tests/owned_instance.py", "--root", root,
                     "--vm-record", vmRecord, "--session-record", sessionRecord});
    if (!ownership.waitForFinished(15000) || ownership.exitStatus() != QProcess::NormalExit
        || ownership.exitCode() != 0
        || !ownership.readAllStandardOutput().contains("OWNED_VM_SESSION_VALIDATED")) {
        std::fprintf(stderr, "owned VM/session validation failed before relay/child launch\n");
        return 2;
    }
    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    const QString original = environment.value(QStringLiteral("WAYLAND_DISPLAY"));
    const QString runtime = environment.value(QStringLiteral("XDG_RUNTIME_DIR"));
    Relay relay;
    relay.path = root + QStringLiteral("/run/guard-relay-%1.sock").arg(getpid());
    relay.target = original.startsWith('/') ? original : runtime + '/' + original;
    if (!relay.start()) { std::fprintf(stderr, "relay startup NOT_EXERCISED\n"); return 2; }
    environment.insert(QStringLiteral("WAYLAND_DISPLAY"), relay.path);
    environment.insert(QStringLiteral("AERIAL_LOCK_TEST_BLOCK_GUI"), blocked ? "1" : "0");
    environment.remove(QStringLiteral("LD_PRELOAD"));
    environment.remove(QStringLiteral("WAYLAND_DEBUG"));
    environment.remove(QStringLiteral("AERIAL_TEST_FULL_CALLER_FAULT"));
    if (!fault.isEmpty()) {
        const QStringList supported{"guard-retirement", "guard-exit-trap", "guard-eintr",
                                    "guard-thread-start", "guard-poll-failure", "guard-logger"};
        if (!supported.contains(fault)) return 2;
        environment.insert(QStringLiteral("LD_PRELOAD"), root + "/build/debug/aerial-tests/"
                           + (fault == "guard-logger" ? "libguard-logger-trap.so" : "libfull-caller-faults.so"));
        environment.insert(QStringLiteral("AERIAL_TEST_FULL_CALLER_FAULT"), fault);
    }
    environment.remove(QStringLiteral("AERIAL_LOCK_CONNECTION_GUARD_PID"));
    environment.remove(QStringLiteral("AERIAL_LOCK_CONNECTION_GUARD_OWNER_PID"));
    // Deliberately heap-owned: never let QProcess destructor kill a surviving qs.
    auto *child = new QProcess;
    child->setProcessEnvironment(environment);
    child->setProcessChannelMode(QProcess::MergedChannels);
    if (nativeLifecycle)
        child->start(QCoreApplication::applicationFilePath(), {"--guard-lifecycle-child", root});
    else
        child->start(root + "/stage/usr/libexec/aerial-lock/aerial-lock-run",
                     {"--shell-dir", shell, "--plugin-root", root + "/stage/usr/lib/aerial-lock/qt-plugins"});
    if (!child->waitForStarted(5000)) {
        if (child->state() != QProcess::NotRunning)
            return holdBlocked(child, child->processId(), root, "start outcome unresolved");
        delete child;
        return 2;
    }
    const qint64 pid = child->processId();
    QByteArray output;
    QElapsedTimer startup;
    startup.start();
    while (!output.contains(ready) && startup.elapsed() < 10000) {
        child->waitForReadyRead(20);
        output += child->readAll();
        if (child->state() == QProcess::NotRunning) break;
    }
    if (fault == "guard-thread-start" || fault == "guard-poll-failure") {
        if (child->state() != QProcess::NotRunning && !child->waitForFinished(5000))
            return holdBlocked(child, pid, root, "guard arming/failure did not fail closed");
        const int expectedExit = fault == "guard-thread-start" ? 72 : 71;
        const bool pass = child->exitStatus() == QProcess::NormalExit && child->exitCode() == expectedExit
                          && output.contains(fault == "guard-thread-start" ? "GUARD_THREAD_START_REJECTED" : "GUARD_POLL_FAILURE_INJECTED")
                          && !output.contains("CONNECTION_LOSS_READY");
        std::printf("GUARD_FAILURE_OUTCOME locker=%lld exit=%d fault=%s\n",
                    static_cast<long long>(pid), child->exitCode(), fault.toUtf8().constData());
        delete child;
        return pass ? 0 : 1;
    }
    if (!output.contains(ready) || relay.failed.load()
        || (fault == "guard-retirement" && !output.contains("CONNECTION_LOSS_RETIREMENT_HELD"))) {
        std::fprintf(stderr, "RELAY_READINESS_FAILED connections=%u failed=%d\n", relay.accepted.load(), relay.failed.load());
        std::fwrite(output.constData(), 1, static_cast<size_t>(output.size()), stderr);
        if (child->state() != QProcess::NotRunning) {
            return holdBlocked(child, pid, root, "readiness/relay gate failed");
        }
        delete child;
        return 2;
    }
    QElapsedTimer intact;
    intact.start();
    while (intact.elapsed() < intactMilliseconds) {
        child->waitForReadyRead(20);
        output += child->readAll();
        if (child->state() == QProcess::NotRunning) { delete child; return 1; }
    }
    QElapsedTimer loss;
    loss.start();
    if (!relay.loseConnection()) {
        if (child->state() != QProcess::NotRunning)
            return holdBlocked(child, pid, root, "connection-loss trigger failed");
        delete child;
        return 2;
    }
    if (!child->waitForFinished(5000)) {
        return holdBlocked(child, pid, root, "guard did not exit");
    }
    const qint64 elapsed = loss.nsecsElapsed();
    output += child->readAll();
    // Qt can win the ordinary dispatch race and call _exit(-1) itself. Only
    // blocked-dispatch cases prove the independent guard and must exit70.
    const bool requireGuard = blocked || nativeLifecycle || fault == "guard-retirement" || fault == "guard-logger";
    const bool expectedExit = child->exitCode() == 70 || (!requireGuard && child->exitCode() == 255);
    const bool pass = child->exitStatus() == QProcess::NormalExit && expectedExit && elapsed <= 250000000
                      && !output.contains("GUARD_DRAIN_TRAP_ENTERED")
                      && (fault != "guard-eintr" || output.count("GUARD_POLL_INTERRUPTED") == 5)
                      && (!nativeLifecycle || output.contains("GUARD_LIFECYCLE_FACADE_DELETED_FORK_CLEAN_CHILD_INERT_UNREAD_DATA"));
    std::printf("CONNECTION_LOSS_OUTCOME locker=%lld exit=%d ns=%lld blocked_gui=%d intact_ms=%d fault=%s\n",
                static_cast<long long>(pid), child->exitCode(), static_cast<long long>(elapsed), blocked,
                intactMilliseconds, fault.toUtf8().constData());
    delete child;
    return pass ? 0 : 1;
}
