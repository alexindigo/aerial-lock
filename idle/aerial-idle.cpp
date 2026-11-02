// Idle and logind policy lives here; lock ownership stays in the supervisor.
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusUnixFileDescriptor>
#include <QDBusVariant>
#include <QDebug>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSocketNotifier>
#include <QTimer>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <functional>
#include <limits>
#include <signal.h>
#include <sys/signalfd.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <wayland-client.h>
#include "ext-idle-notify-v1-client.h"
#include "../native/session-identity.h"

#ifndef AERIAL_IDLE_DATADIR
#define AERIAL_IDLE_DATADIR "/usr/share/aerial-lock"
#endif
#ifndef AERIAL_IDLE_LOCK_COMMAND
#define AERIAL_IDLE_LOCK_COMMAND "/usr/bin/aerial-lock"
#endif

static constexpr int BusTimeoutMs = 1000;
static constexpr int StateTimeoutMs = 300;
static constexpr int PollMs = 100;
static constexpr int StartGraceMs = 10000;
static constexpr qulonglong DefaultDelayUSec = 5000000;
static constexpr qulonglong SleepMarginUSec = 500000;
static const QString Login = QStringLiteral("org.freedesktop.login1");
static const QString ManagerPath = QStringLiteral("/org/freedesktop/login1");
static const QString Manager = QStringLiteral("org.freedesktop.login1.Manager");

// systemd's a(sv), a(sasb), a(sa(sv)) signatures, not variant maps.
using UnitProperty = std::tuple<QString, QDBusVariant>;
using UnitProperties = QList<UnitProperty>;
using UnitExec = std::tuple<QString, QStringList, bool>;
using UnitExecs = QList<UnitExec>;
using AuxiliaryUnit = std::tuple<QString, UnitProperties>;
using AuxiliaryUnits = QList<AuxiliaryUnit>;
Q_DECLARE_METATYPE(UnitProperty)
Q_DECLARE_METATYPE(UnitProperties)
Q_DECLARE_METATYPE(UnitExec)
Q_DECLARE_METATYPE(UnitExecs)
Q_DECLARE_METATYPE(AuxiliaryUnit)
Q_DECLARE_METATYPE(AuxiliaryUnits)

static QJsonObject deepMerge(QJsonObject base, const QJsonObject &overrides)
{
    for (auto it = overrides.begin(); it != overrides.end(); ++it) {
        base[it.key()] = base[it.key()].isObject() && it.value().isObject()
            ? QJsonValue(deepMerge(base[it.key()].toObject(), it.value().toObject())) : it.value();
    }
    return base;
}

static bool readObject(const QString &path, QJsonObject &object, bool required)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (required || file.exists()) qWarning().noquote() << "aerial-idle: cannot read" << path;
        return !required && !file.exists();
    }
    QJsonParseError error;
    auto doc = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning().noquote() << "aerial-idle: invalid config object at" << path;
        return false;
    }
    object = doc.object();
    return true;
}

static bool validTimeout(const QJsonValue &value)
{
    return value.isDouble() && value.toDouble() >= 0
        && std::isfinite(value.toDouble())
        && std::floor(value.toDouble()) == value.toDouble();
}

static bool loadConfig(QJsonObject &idle)
{
    QJsonObject defaults;
    if (!readObject(QStringLiteral(AERIAL_IDLE_DATADIR "/Config/defaults.json"), defaults, true))
        return false;
    const auto baseline = defaults.value("idle").toObject();
    if (!validTimeout(baseline.value("timeoutSeconds"))
        || !baseline.value("respectInhibitors").isBool()
        || !baseline.value("lockOnSuspend").isBool()
        || !baseline.value("logindLockUnlock").isBool()) {
        qWarning("aerial-idle: invalid bundled idle defaults");
        return false;
    }
    QString configHome = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (configHome.isEmpty()) configHome = QDir::homePath() + QStringLiteral("/.config");
    QJsonObject user;
    readObject(configHome + QStringLiteral("/aerial-lock/config.json"), user, false);
    idle = deepMerge(defaults, user).value("idle").toObject();
    for (auto it = baseline.begin(); it != baseline.end(); ++it) {
        const bool valid = it.key() == "timeoutSeconds" ? validTimeout(idle.value(it.key()))
                                                        : idle.value(it.key()).isBool();
        if (!valid) {
            qWarning().noquote() << "aerial-idle: idle." + it.key() << "invalid; using default";
            idle[it.key()] = it.value();
        }
    }
    return true;
}

class Idle : public QObject {
    Q_OBJECT
public:
    explicit Idle(QJsonObject config) : m_config(std::move(config)),
        m_bus(QDBusConnection::sessionBus()), m_system(QDBusConnection::systemBus())
    {
        m_poll.setInterval(PollMs);
        connect(&m_poll, &QTimer::timeout, this, [this] { checkSleep(); });
        m_guard.setSingleShot(true);
        m_guard.setTimerType(Qt::PreciseTimer);
        connect(&m_guard, &QTimer::timeout, this, [this] { releaseSleep("guard deadline"); });
        m_startGrace.setSingleShot(true);
        m_startGrace.setInterval(StartGraceMs);
    }

    ~Idle() override
    {
        if (m_notification) ext_idle_notification_v1_destroy(m_notification);
        if (m_notifier) ext_idle_notifier_v1_destroy(m_notifier);
        if (m_seat) wl_seat_destroy(m_seat);
        if (m_registry) wl_registry_destroy(m_registry);
        if (m_display) wl_display_disconnect(m_display);
    }

    bool start()
    {
        const auto socket = sessionSocketPath();
        if (socket.isEmpty() || !m_bus.isConnected()) {
            qWarning("aerial-idle: Wayland session identity and session bus are required");
            return false;
        }
        m_supervisor = supervisorServiceName(socket);
        QString ownName = m_supervisor;
        ownName.replace(QStringLiteral("org.aeriallock.Supervisor"), QStringLiteral("org.aeriallock.Idle"));
        if (!m_bus.registerService(ownName)) {
            qWarning("aerial-idle: another instance owns this Wayland session (or bus name claim failed)");
            return false;
        }
        auto *supervisorWatch = new QDBusServiceWatcher(m_supervisor, m_bus,
            QDBusServiceWatcher::WatchForOwnerChange, this);
        connect(supervisorWatch, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &owner) {
                if (!owner.isEmpty()) m_startGrace.stop();
                if (m_sleeping) checkSleep();
            });
        if (!connectWayland()) return false;
        if (m_config.value("lockOnSuspend").toBool() || m_config.value("logindLockUnlock").toBool()) {
            auto *watch = new QDBusServiceWatcher(Login, m_system,
                QDBusServiceWatcher::WatchForOwnerChange, this);
            connect(watch, &QDBusServiceWatcher::serviceOwnerChanged, this,
                [this](const QString &, const QString &, const QString &) { setupLogind(); });
            setupLogind();
        }
        qInfo("aerial-idle: ready");
        return true;
    }

private:
    // All remote methods are asynchronous: an unresponsive service must never
    // block the sleep deadline, Wayland dispatch or termination.
    void call(const QDBusConnection &bus, const QString &service, const QString &path,
              const QString &interface, const QString &method, const QVariantList &args,
              std::function<void(const QDBusMessage &)> done, int timeout = BusTimeoutMs)
    {
        auto message = QDBusMessage::createMethodCall(service, path, interface, method);
        message.setArguments(args);
        auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(message, timeout), this);
        connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [watcher, done = std::move(done)] { done(watcher->reply()); watcher->deleteLater(); });
    }

    void state(std::function<void(QString)> done)
    {
        call(m_bus, m_supervisor, QStringLiteral("/org/aeriallock/Supervisor"),
             QStringLiteral("org.aeriallock.Supervisor"), QStringLiteral("State"), {},
             [done = std::move(done)](const QDBusMessage &reply) {
                 done(reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 1
                     ? reply.arguments().first().toString() : QString());
             }, StateTimeoutMs);
    }

    void lock()
    {
        if (m_lockQuery || m_startGrace.isActive()) return;
        m_lockQuery = true;
        state([this](const QString &value) {
            m_lockQuery = false;
            if (value == "locked" || value == "engaging") return;
            m_startGrace.start();
            // NameHasOwner avoids activating systemd on a systemd-less bus.
            call(m_bus, QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"),
                QStringLiteral("org.freedesktop.DBus"), QStringLiteral("NameHasOwner"),
                {QStringLiteral("org.freedesktop.systemd1")}, [this](const QDBusMessage &reply) {
                    if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().value(0).toBool())
                        startUnit();
                    else startDetached();
                });
        });
    }

    QByteArray command() const
    {
        auto path = qgetenv("AERIAL_IDLE_LOCK_COMMAND"); // test-only; never parsed as a command line
        return path.isEmpty() ? QByteArray(AERIAL_IDLE_LOCK_COMMAND) : path;
    }

    void startUnit()
    {
        qDBusRegisterMetaType<UnitProperty>();
        qDBusRegisterMetaType<UnitProperties>();
        qDBusRegisterMetaType<UnitExec>();
        qDBusRegisterMetaType<UnitExecs>();
        qDBusRegisterMetaType<AuxiliaryUnit>();
        qDBusRegisterMetaType<AuxiliaryUnits>();
        const QString path = QString::fromLocal8Bit(command());
        QStringList environment;
        for (const auto *key : {"WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_ID",
                               "HYPRLAND_INSTANCE_SIGNATURE", "NIRI_SOCKET", "DBUS_SESSION_BUS_ADDRESS"}) {
            if (qEnvironmentVariableIsSet(key))
                environment << QString::fromLatin1(key) + '=' + qEnvironmentVariable(key);
        }
        UnitProperties properties {
            {QStringLiteral("ExecStart"), QDBusVariant(QVariant::fromValue(UnitExecs{{path, {path}, false}}))},
            {QStringLiteral("Environment"), QDBusVariant(environment)},
            {QStringLiteral("CollectMode"), QDBusVariant(QStringLiteral("inactive-or-failed"))},
            {QStringLiteral("Description"), QDBusVariant(QStringLiteral("aerial-lock session lock"))}
        };
        const QString unit = QStringLiteral("aerial-lock-%1-%2.service").arg(getpid()).arg(++m_episode);
        call(m_bus, QStringLiteral("org.freedesktop.systemd1"), QStringLiteral("/org/freedesktop/systemd1"),
            QStringLiteral("org.freedesktop.systemd1.Manager"), QStringLiteral("StartTransientUnit"),
            {unit, QStringLiteral("fail"), QVariant::fromValue(properties), QVariant::fromValue(AuxiliaryUnits{})},
            [this, unit](const QDBusMessage &reply) {
                if (reply.type() == QDBusMessage::ErrorMessage) {
                    qWarning().noquote() << "aerial-idle: cannot start" << unit << reply.errorMessage();
                    m_startGrace.stop();
                } else qInfo().noquote() << "aerial-idle: started" << unit;
            });
    }

    void startDetached()
    {
        const QByteArray path = command();
        int channel[2];
        if (pipe2(channel, O_CLOEXEC) != 0) { qWarning("aerial-idle: launch pipe failed"); return; }
        const pid_t first = fork();
        if (first == 0) {
            close(channel[0]);
            if (setsid() < 0) _exit(1);
            const pid_t second = fork();
            if (second < 0) _exit(1);
            if (second > 0) {
                const auto ignored = write(channel[1], &second, sizeof(second));
                (void)ignored;
                _exit(0);
            }
            // No Qt or allocation after fork. Lock and daemon never share a
            // process group/session or a parent-child lifetime relationship.
            sigset_t empty;
            sigemptyset(&empty);
            sigprocmask(SIG_SETMASK, &empty, nullptr);
            const int input = open("/dev/null", O_RDONLY);
            if (input < 0 || dup2(input, STDIN_FILENO) < 0) _exit(1);
            close_range(3, ~0U, 0);
            char *const argv[] = {const_cast<char *>(path.constData()), nullptr};
            execv(argv[0], argv);
            _exit(127);
        }
        close(channel[1]);
        if (first < 0) { close(channel[0]); qWarning("aerial-idle: fork failed"); return; }
        // Only the intermediate fork is our child; it does no external work.
        int status;
        while (waitpid(first, &status, 0) < 0 && errno == EINTR) {}
        pid_t detached = -1;
        const auto count = read(channel[0], &detached, sizeof(detached));
        close(channel[0]);
        if (count == sizeof(detached)) qInfo() << "aerial-idle: started detached PID" << detached;
        else { qWarning("aerial-idle: detached launch failed"); m_startGrace.stop(); }
    }

    void setupLogind()
    {
        const int generation = ++m_logindGeneration;
        // A sleep cycle belongs to one login1 instance. Its replacement need
        // not emit the old instance's resume, so invalidate the entire cycle.
        m_poll.stop();
        m_guard.stop();
        ++m_sleepCycle;
        m_sleeping = false;
        m_delayUSec = DefaultDelayUSec;
        m_inhibitor = {};
        m_inhibitPending = false;
        if (!m_loginOwner.isEmpty()) {
            m_system.disconnect(m_loginOwner, ManagerPath, Manager, "PrepareForSleep", this, SLOT(sleep(bool)));
            if (!m_sessionPath.isEmpty()) {
                m_system.disconnect(m_loginOwner, m_sessionPath, "org.freedesktop.login1.Session", "Lock", this, SLOT(logindLock()));
                m_system.disconnect(m_loginOwner, m_sessionPath, "org.freedesktop.login1.Session", "Unlock", this, SLOT(logindUnlock()));
            }
        }
        m_sessionPath.clear();
        m_loginOwner.clear();
        call(m_system, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
            {Login}, [this, generation](const QDBusMessage &reply) {
                if (generation != m_logindGeneration) return;
                if (reply.type() == QDBusMessage::ErrorMessage) {
                    qWarning("aerial-idle: logind unavailable; idle timeout only");
                    return;
                }
                m_loginOwner = reply.arguments().value(0).toString();
                if (m_config.value("lockOnSuspend").toBool()) {
                    call(m_system, m_loginOwner, ManagerPath, "org.freedesktop.DBus.Properties", "Get",
                         {Manager, QStringLiteral("InhibitDelayMaxUSec")},
                         [this, generation](const QDBusMessage &result) {
                             if (generation != m_logindGeneration) return;
                             m_delayUSec = result.type() == QDBusMessage::ReplyMessage
                                 ? qdbus_cast<QDBusVariant>(result.arguments().value(0)).variant().toULongLong()
                                 : DefaultDelayUSec;
                             // Establish the delay limit before handling sleep.
                             // Subscribe before reading the snapshot so no later
                             // transition is lost; a signal supersedes the read.
                             m_system.connect(m_loginOwner, ManagerPath, Manager, "PrepareForSleep", this, SLOT(sleep(bool)));
                             const int cycle = m_sleepCycle;
                             call(m_system, m_loginOwner, ManagerPath, "org.freedesktop.DBus.Properties", "Get",
                                  {Manager, QStringLiteral("PreparingForSleep")},
                                  [this, generation, cycle](const QDBusMessage &snapshot) {
                                      if (generation != m_logindGeneration || cycle != m_sleepCycle) return;
                                      const QVariant preparing = qdbus_cast<QDBusVariant>(snapshot.arguments().value(0)).variant();
                                      const bool valid = snapshot.type() == QDBusMessage::ReplyMessage
                                          && preparing.metaType() == QMetaType::fromType<bool>();
                                      if (!valid)
                                          qWarning("aerial-idle: logind sleep state unavailable; assuming awake and taking sleep inhibitor");
                                      // Unknown state must preserve protection for
                                      // the next sleep, just like an awake snapshot.
                                      sleep(valid && preparing.toBool());
                                  });
                         });
                }
                if (m_config.value("logindLockUnlock").toBool()) resolveSession(generation);
            });
    }

    void resolveSession(int generation)
    {
        const QString id = qEnvironmentVariable("XDG_SESSION_ID");
        if (!id.isEmpty()) {
            call(m_system, m_loginOwner, ManagerPath, Manager, "GetSession", {id},
                [this, generation](const QDBusMessage &reply) {
                    if (generation != m_logindGeneration) return;
                    subscribeSession(qdbus_cast<QDBusObjectPath>(reply.arguments().value(0)).path());
                });
        } else {
            call(m_system, m_loginOwner, "/org/freedesktop/login1/user/self", "org.freedesktop.DBus.Properties", "Get",
                 {QStringLiteral("org.freedesktop.login1.User"), QStringLiteral("Display")},
                 [this, generation](const QDBusMessage &reply) {
                     if (generation != m_logindGeneration) return;
                     const QVariant value = qdbus_cast<QDBusVariant>(reply.arguments().value(0)).variant();
                     const auto display = qdbus_cast<std::tuple<QString, QDBusObjectPath>>(value);
                     subscribeSession(std::get<1>(display).path());
                 });
        }
    }

    void subscribeSession(const QString &path)
    {
        if (path.isEmpty() || path == "/") { qWarning("aerial-idle: graphical logind session unavailable"); return; }
        m_sessionPath = path;
        m_system.connect(m_loginOwner, path, "org.freedesktop.login1.Session", "Lock", this, SLOT(logindLock()));
        m_system.connect(m_loginOwner, path, "org.freedesktop.login1.Session", "Unlock", this, SLOT(logindUnlock()));
        qInfo().noquote() << "aerial-idle: logind session" << path;
    }

    void takeInhibitor()
    {
        if (m_sleeping || m_inhibitor.isValid() || m_inhibitPending || m_loginOwner.isEmpty()) return;
        m_inhibitPending = true;
        const int generation = m_logindGeneration;
        call(m_system, m_loginOwner, ManagerPath, Manager, "Inhibit",
            {QStringLiteral("sleep"), QStringLiteral("aerial-idle"),
             QStringLiteral("Lock the screen before sleep"), QStringLiteral("delay")},
            [this, generation](const QDBusMessage &reply) {
                if (generation != m_logindGeneration) return;
                m_inhibitPending = false;
                if (reply.type() == QDBusMessage::ErrorMessage) {
                    qWarning().noquote() << "aerial-idle: sleep inhibitor unavailable:" << reply.errorMessage();
                    return;
                }
                if (!m_sleeping) {
                    m_inhibitor = qdbus_cast<QDBusUnixFileDescriptor>(reply.arguments().value(0));
                    qInfo("aerial-idle: sleep inhibitor held");
                }
            });
    }

    void releaseSleep(const char *reason)
    {
        m_poll.stop();
        m_guard.stop();
        m_inhibitor = {};
        qInfo() << "aerial-idle: sleep inhibitor released:" << reason;
    }

    void checkSleep()
    {
        if (!m_sleeping || !m_guard.isActive() || m_stateQuery) return;
        m_stateQuery = true;
        const int cycle = m_sleepCycle;
        state([this, cycle](const QString &value) {
            m_stateQuery = false;
            if (!m_sleeping || cycle != m_sleepCycle || !m_guard.isActive()) return;
            if (value == "locked") releaseSleep("supervisor locked");
            else if (value != "engaging") lock();
        });
    }

    bool connectWayland()
    {
        m_display = wl_display_connect(nullptr);
        if (!m_display) { qWarning("aerial-idle: cannot connect to compositor"); return false; }
        if (m_config.value("timeoutSeconds").toDouble() > 0) {
            m_registry = wl_display_get_registry(m_display);
            static const wl_registry_listener listener = {global, removed};
            wl_registry_add_listener(m_registry, &listener, this);
            if (wl_display_roundtrip(m_display) < 0) return false;
            if (m_notifier && m_seat) {
                const uint32_t timeout = uint32_t(std::min(m_config.value("timeoutSeconds").toDouble() * 1000,
                                                         double(std::numeric_limits<uint32_t>::max())));
                const bool inputOnly = !m_config.value("respectInhibitors").toBool();
                if (inputOnly && wl_proxy_get_version(reinterpret_cast<wl_proxy *>(m_notifier)) < 2)
                    qWarning("aerial-idle: idle notifier v1; falling back to inhibitor-aware timeout");
                m_notification = inputOnly && wl_proxy_get_version(reinterpret_cast<wl_proxy *>(m_notifier)) >= 2
                    ? ext_idle_notifier_v1_get_input_idle_notification(m_notifier, timeout, m_seat)
                    : ext_idle_notifier_v1_get_idle_notification(m_notifier, timeout, m_seat);
                static const ext_idle_notification_v1_listener idleListener = {idled, resumed};
                ext_idle_notification_v1_add_listener(m_notification, &idleListener, this);
                wl_display_flush(m_display);
            } else qWarning("aerial-idle: idle notifier/seat unavailable; idle timeout disabled");
        }
        auto *read = new QSocketNotifier(wl_display_get_fd(m_display), QSocketNotifier::Read, this);
        auto *write = new QSocketNotifier(wl_display_get_fd(m_display), QSocketNotifier::Write, this);
        write->setEnabled(false);
        auto flush = [this, write] {
            if (wl_display_flush(m_display) < 0) {
                if (errno == EAGAIN) write->setEnabled(true);
                else QCoreApplication::quit();
            } else write->setEnabled(false);
        };
        connect(read, &QSocketNotifier::activated, this, [this, flush] {
            if (wl_display_dispatch(m_display) < 0) QCoreApplication::quit();
            else flush();
        });
        connect(write, &QSocketNotifier::activated, this, flush);
        flush();
        return true;
    }

    static void global(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
    {
        auto *self = static_cast<Idle *>(data);
        if (strcmp(interface, "ext_idle_notifier_v1") == 0)
            self->m_notifier = static_cast<ext_idle_notifier_v1 *>(wl_registry_bind(registry, name, &ext_idle_notifier_v1_interface, std::min(version, 2U)));
        else if (strcmp(interface, "wl_seat") == 0 && !self->m_seat)
            self->m_seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
    }
    static void removed(void *, wl_registry *, uint32_t) {}
    static void idled(void *data, ext_idle_notification_v1 *) { static_cast<Idle *>(data)->lock(); }
    static void resumed(void *, ext_idle_notification_v1 *) {}

private slots:
    void logindLock() { lock(); }
    void logindUnlock()
    {
        call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
             {m_supervisor}, [this](const QDBusMessage &reply) {
                 if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().value(0).toBool())
                     call(m_bus, m_supervisor, "/org/aeriallock/Supervisor", "org.aeriallock.Supervisor", "Release", {},
                          [](const QDBusMessage &) {});
             });
    }
    void sleep(bool preparing)
    {
        m_sleeping = preparing;
        ++m_sleepCycle;
        if (!preparing) { m_poll.stop(); m_guard.stop(); takeInhibitor(); return; }
        const auto guardMs = m_delayUSec > SleepMarginUSec ? (m_delayUSec - SleepMarginUSec) / 1000 : 0;
        m_guard.start(int(std::min(guardMs, qulonglong(std::numeric_limits<int>::max()))));
        m_poll.start();
        checkSleep();
    }

private:
    QJsonObject m_config;
    QDBusConnection m_bus, m_system;
    QString m_supervisor, m_loginOwner, m_sessionPath;
    QDBusUnixFileDescriptor m_inhibitor;
    QTimer m_poll, m_guard, m_startGrace;
    bool m_sleeping = false, m_lockQuery = false, m_stateQuery = false, m_inhibitPending = false;
    int m_logindGeneration = 0, m_sleepCycle = 0;
    unsigned m_episode = 0;
    qulonglong m_delayUSec = DefaultDelayUSec;
    wl_display *m_display = nullptr;
    wl_registry *m_registry = nullptr;
    wl_seat *m_seat = nullptr;
    ext_idle_notifier_v1 *m_notifier = nullptr;
    ext_idle_notification_v1 *m_notification = nullptr;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QJsonObject config;
    if (!loadConfig(config)) return 1;
    if (app.arguments() == QStringList{app.arguments().first(), QStringLiteral("--print-config")}) {
        const QByteArray json = QJsonDocument(config).toJson(QJsonDocument::Compact) + '\n';
        return write(STDOUT_FILENO, json.constData(), json.size()) == json.size() ? 0 : 1;
    }
    if (argc != 1) { qWarning("usage: aerial-idle [--print-config]"); return 1; }
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    if (sigprocmask(SIG_BLOCK, &mask, nullptr) < 0) return 1;
    const int signalFd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signalFd < 0) return 1;
    QSocketNotifier termination(signalFd, QSocketNotifier::Read);
    QObject::connect(&termination, &QSocketNotifier::activated, &app, &QCoreApplication::quit);
    int result;
    { Idle idle(config); result = idle.start() ? app.exec() : 1; }
    close(signalFd);
    return result;
}

#include "aerial-idle.moc"
