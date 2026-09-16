/*
 * aerial-lock-supervisor — owns the locker lifecycle; respawn-only recovery.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * respawns it up to three times on abnormal death, and — when respawns run
 * out — stays locked and escalates loudly. There is NO automatic unlock
 * anywhere: no path from "at the lock screen" to "inside the session" that
 * does not go through PAM. The shelved auto-release work (Takeover::run as a
 * supervisor call path, the escalation gate, probe-based state detection)
 * lives on the `shelved/auto-release` branch; the manual `aerial-unlock`
 * binary is unchanged as the ops/TTY tool.
 *
 * Decision matrix is exit-code only (see plan d29):
 *   compositor dead  → session over, clean exit (checked FIRST)
 *   exit 0           → clean unlock / PAM refusal / external invalidation → done
 *   exit != 0        → respawn under limit; at limit, stay locked + escalate
 */
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDir>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include <cstdio>
#include <cstring>
#include <string>

#include <wayland-client.h>

static const int RESPAWN_LIMIT = 3;
static const int RESPAWN_BACKOFF_MS = 1500;
static const char *SUPERVISOR_DBUS_NAME = "org.aeriallock.Supervisor";

class Supervisor : public QObject
{
    Q_OBJECT
public:
    Supervisor()
    {
        QDBusConnection bus = QDBusConnection::sessionBus();
        if (!bus.interface()->registerService(QString::fromLatin1(SUPERVISOR_DBUS_NAME))) {
            log("another supervisor is on duty — exiting");
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
                                                  : "/usr/share/aerial-lock");
    }

    void launch()
    {
        m_attempt++;
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
                .arg(m_attempt).arg(RESPAWN_LIMIT + 1)
                .arg(m_video.isEmpty() ? QString()
                                       : QStringLiteral(" (video: %1)").arg(m_video)));
        m_child = new QProcess(this);
        m_child->setProgram(QStringLiteral("qs"));
        QStringList args{QStringLiteral("-p"), m_lockerCommand};
        m_child->setArguments(args);
        if (!m_video.isEmpty()) {
            QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
            env.insert(QStringLiteral("AERIAL_LOCK_VIDEO"), m_video);
            m_child->setProcessEnvironment(env);
        }
        connect(m_child, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, &Supervisor::onChildFinished);
        connect(m_child, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
            log(QStringLiteral("child failed to start: %1").arg(m_child->errorString()));
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
        log(QStringLiteral("child finished: exit=%1 status=%2")
                .arg(exitCode).arg(status));

        // Ordering guard (load-bearing): compositor death is checked FIRST.
        // When the compositor dies the locker dies too, and the two signals
        // can arrive in either order; without this guard a dead-session
        // "child exit" reads as "locker died → respawn" and the supervisor
        // spawns a locker into a dead session.
        if (!waylandAlive()) {
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
    // if the supervisor's own Wayland connection is gone, the compositor is
    // dead and the session is over.
    static bool waylandAlive()
    {
        const char *disp = getenv("WAYLAND_DISPLAY");
        if (!disp || !*disp) return false;
        struct wl_display *d = wl_display_connect(disp);
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
    QString m_lockerCommand;
    QString m_video;
    QString m_lastVideo;
    int m_attempt = 0;
    bool m_hyprFlagSet = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Supervisor supervisor;
    return app.exec();
}

#include "aerial-lock-supervisor.moc"
