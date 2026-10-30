/*
 * aerial-lock-supervisor — owns the locker lifecycle; respawn-only recovery.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * retries within three total attempts on abnormal death, and — when attempts run
 * out — reports failure without claiming an unavailable guard locked the
 * session. There is NO automatic unlock
 * anywhere: no path from "at the lock screen" to "inside the session" that
 * does not go through PAM. The shelved auto-release work (Takeover::run as a
 * supervisor call path, the escalation gate, probe-based state detection)
 * lives on the `shelved/auto-release` branch; the manual `aerial-unlock`
 * binary is unchanged as the ops/TTY tool.
 *
 * Decision matrix is exit-code only:
 *   compositor dead  → session over, clean exit (checked FIRST)
 *   exit 0           → clean unlock / PAM refusal / external invalidation → done
 *   exit 72          → this attempt never engaged (runner/guard unavailable;
 *                      a shell's 126/127 from the runner counts the same)
 *   exit 71          → guard monitor failed; engagement is unknown
 *   exit != 0        → respawn under limit; at limit, guard failures exit 3,
 *                      other failures exit 2. No automatic unlock.
 */
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTextStream>
#include <QTimer>

#include <cstdio>
#include <cstring>
#include <string>

#include <wayland-client.h>

#ifndef AERIAL_LOCK_DEFAULT_SHELL
#define AERIAL_LOCK_DEFAULT_SHELL "/usr/share/aerial-lock"
#endif
#ifndef AERIAL_LOCK_DEFAULT_RUNNER
#define AERIAL_LOCK_DEFAULT_RUNNER "/usr/libexec/aerial-lock/aerial-lock-run"
#endif
#ifndef AERIAL_LOCK_DEFAULT_PLUGIN_ROOT
#define AERIAL_LOCK_DEFAULT_PLUGIN_ROOT "/usr/lib/aerial-lock/qt-plugins"
#endif

static const int RESPAWN_LIMIT = 3;
static const int RESPAWN_BACKOFF_MS = 1500;
static const char *SUPERVISOR_DBUS_NAME = "org.aeriallock.Supervisor";

// The protected resource is one compositor session, identified by the
// Wayland socket a client started from this environment connects to
// (libwayland's resolution: WAYLAND_DISPLAY, default "wayland-0", relative
// to XDG_RUNTIME_DIR unless absolute). Several sessions can share one user
// bus (nested or parallel compositors), so the single-instance name is
// derived from that socket rather than being bus-wide.
static QString sessionSocketPath()
{
    QByteArray display = qgetenv("WAYLAND_DISPLAY");
    if (display.isEmpty())
        display = "wayland-0";
    QString path = QString::fromLocal8Bit(display);
    if (!path.startsWith(QLatin1Char('/'))) {
        const QByteArray runtime = qgetenv("XDG_RUNTIME_DIR");
        if (runtime.isEmpty())
            return QString();
        path = QString::fromLocal8Bit(runtime) + QLatin1Char('/') + path;
    }
    const QString canonical = QFileInfo(path).canonicalFilePath();
    return canonical.isEmpty() ? QDir::cleanPath(path) : canonical;
}

static QString supervisorServiceName(const QString &socket)
{
    // Bus name elements allow [A-Za-z0-9_-] and must not start with a digit.
    const QByteArray digest = QCryptographicHash::hash(socket.toUtf8(),
                                                      QCryptographicHash::Sha256).toHex().left(32);
    return QStringLiteral("%1.s%2").arg(QString::fromLatin1(SUPERVISOR_DBUS_NAME),
                                       QString::fromLatin1(digest));
}

class Supervisor : public QObject
{
    Q_OBJECT
public:
    Supervisor()
    {
        m_sessionSocket = sessionSocketPath();
        if (m_sessionSocket.isEmpty()) {
            log("cannot identify the Wayland session to protect "
                "(WAYLAND_DISPLAY is relative and XDG_RUNTIME_DIR is unset) — exiting");
            std::exit(1);
        }
        QDBusConnection bus = QDBusConnection::sessionBus();
        if (!bus.interface()->registerService(supervisorServiceName(m_sessionSocket))) {
            log(QStringLiteral("another supervisor is on duty for %1 — exiting").arg(m_sessionSocket));
            // std::exit, not QCoreApplication::exit: the event loop hasn't
            // started yet, so Qt's quit() would be a no-op here.
            std::exit(0);
        }

        m_lockerCommand = lockerCommandLine();
        m_attempt = 0;
        launch();
    }

private:
    QString lockerCommandLine()
    {
        // the supervisor IS the aerial-lock launcher: it runs the locker
        // payload directly, so a bare `aerial-lock` invocation works both
        // before and after `make install`.
        const char *shell = getenv("AERIAL_LOCK_SHELL");
        return QString::fromLatin1(shell && *shell ? shell
                                                   : AERIAL_LOCK_DEFAULT_SHELL);
    }

    void launch()
    {
        m_attempt++;
        m_attemptSettled = false;
        m_video = nextVideo();

        // On Hyprland a respawned locker is refused without the
        // session-lock-restore flag, so set it just-in-time before every
        // launch there (first or respawn); unset when the episode ends.
        if (isHyprland() && !m_hyprFlagSet) {
            if (setHyprlandRestoreFlag(true)) {
                m_hyprFlagSet = true;
                log("Hyprland: misc:allow_session_lock_restore set just-in-time");
            }
        }

        log(QStringLiteral("launching locker, attempt %1/%2%3")
                .arg(m_attempt).arg(RESPAWN_LIMIT)
                .arg(m_video.isEmpty() ? QString()
                                       : QStringLiteral(" (video: %1)").arg(m_video)));
        m_child = new QProcess(this);
        const QByteArray runner = qgetenv("AERIAL_LOCK_RUNNER");
        const QByteArray pluginRoot = qgetenv("AERIAL_LOCK_PLUGIN_ROOT");
        m_child->setProgram(runner.isEmpty() ? QStringLiteral(AERIAL_LOCK_DEFAULT_RUNNER)
                                           : QString::fromLocal8Bit(runner));
        QStringList args{QStringLiteral("--shell-dir"), m_lockerCommand,
                        QStringLiteral("--plugin-root"), pluginRoot.isEmpty()
                            ? QStringLiteral(AERIAL_LOCK_DEFAULT_PLUGIN_ROOT) : QString::fromLocal8Bit(pluginRoot)};
        m_child->setArguments(args);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (!m_video.isEmpty())
            env.insert(QStringLiteral("AERIAL_LOCK_VIDEO"), m_video);
        m_child->setProcessEnvironment(env);
        QProcess *const child = m_child;
        connect(m_child, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this, child](int code, QProcess::ExitStatus status) {
            if (child == m_child) onChildFinished(code, status);
        });
        connect(m_child, &QProcess::errorOccurred, this, [this, child](QProcess::ProcessError error) {
            if (child != m_child || m_attemptSettled) return;
            log(QStringLiteral("child process error: %1").arg(child->errorString()));
            if (error == QProcess::FailedToStart)
                onChildFinished(72, QProcess::CrashExit);
        });
        m_child->start();
    }

    // A respawn picks a different video than the one playing at crash time —
    // content-specific crashes are a real class, and a fresh file makes a
    // repeat less likely. Empty if no video pool is configured (the locker
    // renders its solid background, which is the current behaviour).
    QString nextVideo()
    {
        const char *pool = getenv("AERIAL_LOCK_VIDEO_POOL");
        if (!pool || !*pool) return QString();
        QDir dir(QString::fromLatin1(pool));
        if (!dir.exists()) return QString();
        QStringList files = dir.entryList(QDir::Files, QDir::Name);
        if (files.isEmpty()) return QString();
        QString pick = files.first();
        if (!m_lastVideo.isEmpty()) {
            int idx = files.indexOf(m_lastVideo);
            if (idx >= 0 && files.size() > 1)
                pick = files.at((idx + 1) % files.size());
        }
        m_lastVideo = pick;
        return dir.absoluteFilePath(pick);
    }

    void onChildFinished(int exitCode, QProcess::ExitStatus status)
    {
        if (m_attemptSettled) return;
        m_attemptSettled = true;
        QProcess *const completed = m_child;
        m_child = nullptr;
        if (completed) completed->deleteLater();
        log(QStringLiteral("child finished: exit=%1 status=%2")
                .arg(exitCode).arg(status));

        // Ordering guard (load-bearing): compositor death is checked FIRST.
        // When the compositor dies the locker dies too, and the two signals
        // can arrive in either order; without this guard a dead-session
        // "child exit" reads as "locker died → respawn" and the supervisor
        // spawns a locker into a dead session.
        if (!waylandAlive(m_sessionSocket)) {
            log("compositor connection dead — session over, clearing state");
            finishEpisode(0);
            return;
        }

        if (exitCode == 0) {
            // clean unlock / PAM probe refusal (never locked) / external
            // invalidation (another client owns it) — all mean "do not
            // respawn".
            log("clean exit — done");
            finishEpisode(0);
            return;
        }

        // Abnormal death. The correct response to an abnormal death while
        // locked is a respawn.
        // 72 is the runner's and guard's "never engaged". A shell's 126/127
        // (command not executable / not found) means the locker process
        // itself never ran, so it cannot have engaged either; qs and the
        // guard never exit with those codes.
        const bool notEngaged = exitCode == 72 || exitCode == 126 || exitCode == 127;
        m_onlyPreEngagementFailures = m_onlyPreEngagementFailures && notEngaged;
        m_guardFailed = m_guardFailed || exitCode == 71 || notEngaged;
        if (exitCode == 72)
            log("guard unavailable — this attempt did not engage the lock");
        else if (notEngaged)
            log("locker could not be started — this attempt did not engage the lock");
        else if (exitCode == 71)
            log("guard monitor failed — this attempt's engagement is unknown");
        if (m_attempt < RESPAWN_LIMIT) {
            log(QStringLiteral("locker died abnormally — respawning in %1 ms "
                               "(attempt %2/%3)")
                    .arg(RESPAWN_BACKOFF_MS)
                    .arg(m_attempt + 1)
                    .arg(RESPAWN_LIMIT));
            QTimer::singleShot(RESPAWN_BACKOFF_MS, this, [this] {
                launch();
            });
        } else {
            if (m_guardFailed) {
                if (m_onlyPreEngagementFailures)
                    // Only this episode is known: a lock left by an earlier
                    // episode (e.g. a clientless one) may still be held.
                    log("respawn limit reached: guard unavailable — these attempts did not engage a lock; "
                        "the current screen state is unknown. Check the screen and recover from a TTY "
                        "if needed (see README)");
                else
                    log("respawn limit reached: guard failed — lock engagement not confirmed; "
                        "the screen may be unlocked. Recover manually from a TTY (see README)");
                finishEpisode(3);
                return;
            }
            // Respawns ran out. There is NO automatic unlock — stay locked
            // and escalate loudly. Manual recovery is aerial-unlock from a
            // TTY/ops (see README).
            log("respawn limit reached — staying locked. NO automatic unlock. "
                "Recover manually: aerial-unlock from a TTY (see README)");
            finishEpisode(2);
        }
    }

    void finishEpisode(int code)
    {
        if (m_hyprFlagSet) {
            setHyprlandRestoreFlag(false);
            m_hyprFlagSet = false;
        }
        QCoreApplication::exit(code);
    }

    // The compositor connection is the ordering guard's source of truth:
    // if the protected session's socket no longer accepts a connection, the
    // compositor is dead and the session is over.
    static bool waylandAlive(const QString &socket)
    {
        const QByteArray path = QFile::encodeName(socket);
        struct wl_display *d = wl_display_connect(path.constData());
        if (!d) return false;
        wl_display_disconnect(d);
        return true;
    }

    static bool isHyprland()
    {
        const char *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
        return sig && *sig;
    }

    // hyprctl keyword misc:allow_session_lock_restore <0|1>
    static bool setHyprlandRestoreFlag(bool on)
    {
        QProcess p;
        p.start(QStringLiteral("hyprctl"),
                {QStringLiteral("keyword"),
                 QStringLiteral("misc:allow_session_lock_restore"),
                 on ? QStringLiteral("1") : QStringLiteral("0")});
        if (!p.waitForFinished(3000)) {
            return false;
        }
        return p.exitCode() == 0;
    }

    void log(const QString &msg)
    {
        QTextStream out(stderr);
        out << "aerial-lock-supervisor: " << msg << "\n";
        out.flush();
    }

    QProcess *m_child = nullptr;
    QString m_sessionSocket;
    QString m_lockerCommand;
    QString m_video;
    QString m_lastVideo;
    int m_attempt = 0;
    bool m_hyprFlagSet = false;
    bool m_attemptSettled = false;
    bool m_onlyPreEngagementFailures = true;
    bool m_guardFailed = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Supervisor supervisor;
    return app.exec();
}

#include "aerial-lock-supervisor.moc"
