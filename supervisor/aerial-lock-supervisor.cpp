/*
 * aerial-lock-supervisor — owns the locker lifecycle and recovers it.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * respawns it up to three times on abnormal death, then takeover-releases
 * in-process. Never spawns the old bash/QML pair; never links Qt Quick or
 * QML (QtCore + QtDBus + wayland-client only).
 *
 * Lock state comes from the takeover probe: request a lock and read the
 * compositor's answer (refused ⟺ live holder, granted ⟺ nobody holds it).
 * That is the only signal sourced from the compositor itself, so it
 * survives the quirks that killed LockedHint (never set on niri) and the
 * locker's secure log (never fires on nested niri). A granted probe
 * releases immediately — used only at child-death decision points.
 */
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDir>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include <cstdio>
#include <cstring>
#include <string>

#include <wayland-client.h>

#include "takeover.h"

static const int RESPAWN_LIMIT = 3;
static const int RESPAWN_BACKOFF_MS = 1500;
static const char *SUPERVISOR_DBUS_NAME = "org.aeriallock.Supervisor";

/* ---- supervisor ---- */

class Supervisor : public QObject
{
    Q_OBJECT
public:
    Supervisor()
    {
        // Singleton: exactly one supervisor on duty, atomic by the bus.
        // Claimed before the lock-state probe.
        QDBusConnection bus = QDBusConnection::sessionBus();
        if (!bus.interface()->registerService(QString::fromLatin1(SUPERVISOR_DBUS_NAME))) {
            log("another supervisor is on duty — exiting");
            // std::exit, not QCoreApplication::exit: the event loop hasn't
            // started yet, so Qt's quit() would be a no-op here.
            std::exit(0);
        }

        m_lockerCommand = lockerCommandLine();
        m_attempt = 0;

        // Startup probe: if the session is already locked (a previous
        // supervisor died mid-episode), adopt it by respawning a locker;
        // otherwise start a fresh episode.
        Takeover::Outcome startup = Takeover::run(3000);
        if (startup == Takeover::Outcome::Refused) {
            log("startup probe: session locked (previous supervisor died "
                "mid-episode) — adopting");
            m_adopting = true;
        } else {
            log("startup probe: session unlocked — fresh episode");
        }
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

        // Ordering guard (load-bearing): compositor death is checked FIRST,
        // before any probe. When the compositor dies the locker dies too, and
        // the two signals can arrive in either order; without this guard a
        // dead-session "child exit" reads as "locker died → respawn" and the
        // supervisor spawns a locker into a dead session.
        if (!waylandAlive()) {
            log("compositor connection dead — session over, clearing state");
            QCoreApplication::exit(0);
            return;
        }

        // Probe the lock state: refused ⟺ a live client holds the lock,
        // granted ⟺ nobody holds it.
        Takeover::Outcome probe = Takeover::run(3000);
        bool locked = (probe == Takeover::Outcome::Refused);

        if (exitCode == 0 && !locked) {
            log("clean unlock — done");
            QCoreApplication::exit(0);
            return;
        }
        if (exitCode == 0 && locked) {
            log("child exited 0 but the lock is held by another client — "
                "not respawning (external takeover)");
            QCoreApplication::exit(0);
            return;
        }
        if (exitCode != 0 && !locked) {
            log("child crashed after unlock — not relocking");
            QCoreApplication::exit(0);
            return;
        }
        // exitCode != 0 && locked → locker died while holding the lock.
        log("locker died while holding the lock");

        // Escalation gate: a *respawned* instance that reached secure and
        // then died is suspicious (could be attacker-induced from the lock
        // UI) — never auto-unlock that. The probe at the moment of death is
        // the answer: still locked here means engaged-then-died.
        if (m_attempt > 1) {
            log("respawned instance was engaged when it died — staying locked, "
                "escalating to manual recovery only (see README)");
            QCoreApplication::exit(2);
            return;
        }

        if (m_attempt < RESPAWN_LIMIT) {
            log(QStringLiteral("respawning in %1 ms (attempt %2/%3)")
                    .arg(RESPAWN_BACKOFF_MS)
                    .arg(m_attempt + 1)
                    .arg(RESPAWN_LIMIT));
            QTimer::singleShot(RESPAWN_BACKOFF_MS, this, [this] {
                launch();
            });
        } else {
            log("respawn limit reached — in-process takeover");
            escalate();
        }
    }

    void escalate()
    {
        // In-process takeover (d26a), never exec'd.
        log(QStringLiteral("running in-process takeover…"));
        Takeover::Outcome outcome = Takeover::run(5000);

        // Hyprland legacy-config-manager builds have no
        // hl.clear_crashed_lockscreen(); the only client-side recovery there
        // is the allow_session_lock_restore flag, set just-in-time on refusal
        // then unset. Detect Hyprland by env; niri/sway take the lock
        // unconditionally.
        if (outcome == Takeover::Outcome::Refused && isHyprland()) {
            log(QStringLiteral("takeover refused on Hyprland — setting "
                               "misc:allow_session_lock_restore just-in-time, "
                               "retrying, then unsetting"));
            if (setHyprlandRestoreFlag(true)) {
                outcome = Takeover::run(5000);
                setHyprlandRestoreFlag(false);
            }
        }

        switch (outcome) {
        case Takeover::Outcome::Recovered:
            log(QStringLiteral("takeover recovered the session"));
            QCoreApplication::exit(0);
            return;
        case Takeover::Outcome::Refused:
            log(QStringLiteral("takeover refused — a live client holds the lock"));
            QCoreApplication::exit(3);
            return;
        case Takeover::Outcome::NoSocket:
            log(QStringLiteral("takeover: no Wayland socket"));
            QCoreApplication::exit(1);
            return;
        case Takeover::Outcome::Inconclusive:
            log(QStringLiteral("takeover inconclusive — staying locked, escalate "
                               "to manual recovery"));
            QCoreApplication::exit(2);
            return;
        }
    }

    // The compositor connection is the ordering guard's source of truth:
    // if the supervisor's own Wayland connection is gone, the compositor is
    // dead and the session is over.
    static bool waylandAlive()
    {
        // A cheap aliveness probe: try to open the display. A dead
        // compositor fails connect; a live one succeeds.
        const char *xdg = getenv("XDG_RUNTIME_DIR");
        if (!xdg || !*xdg) return false;
        const char *disp = getenv("WAYLAND_DISPLAY");
        if (!disp || !*disp) return false;
        // We deliberately reuse the takeover's socket discovery: connect and
        // immediately disconnect. Cheap, and correct on both compositors.
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
    bool m_adopting = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Supervisor supervisor;
    return app.exec();
}

#include "aerial-lock-supervisor.moc"
