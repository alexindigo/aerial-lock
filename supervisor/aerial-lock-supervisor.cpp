/*
 * aerial-lock-supervisor — owns the locker lifecycle and recovers it.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * respawns it up to three times on abnormal death, then takeover-releases
 * in-process. Never spawns the old bash/QML pair; never links Qt Quick or
 * QML (QtCore + QtDBus + wayland-client only).
 *
 * Lock state comes from the compositor: logind LockedHint where the
 * compositor sets it (survives the locker's death by definition), or the
 * locker's own compositor-confirmed secure log as the fallback. No marker
 * file.
 */
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingReply>
#include <QDir>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include <cstdio>
#include <cstring>
#include <string>

#include "takeover.h"

static const int RESPAWN_LIMIT = 3;
static const int RESPAWN_BACKOFF_MS = 1500;

/* ---- lock state: ask the compositor directly, never a marker file ---- */

enum class HintState { Unknown, Locked, Unlocked, Unsupported };

static HintState queryLockedHint()
{
    // Try the session object path first (standard logind API).
    QDBusInterface logind(
        QStringLiteral("org.freedesktop.login1"),
        QStringLiteral("/org/freedesktop/login1/session/self"),
        QStringLiteral("org.freedesktop.login1.Session"),
        QDBusConnection::systemBus());
    if (!logind.isValid())
        return HintState::Unsupported;

    QDBusPendingReply<QVariant> reply =
        logind.asyncCall(QStringLiteral("Get"),
                         QStringLiteral("org.freedesktop.login1.Session"),
                         QStringLiteral("LockedHint"));
    reply.waitForFinished();
    if (!reply.isValid())
        return HintState::Unsupported;
    bool locked = reply.value().toBool();
    return locked ? HintState::Locked : HintState::Unlocked;
}

/* ---- supervisor ---- */

class Supervisor : public QObject
{
    Q_OBJECT
public:
    Supervisor()
    {
        m_lockerCommand = lockerCommandLine();
        m_lockedHintSupported = (queryLockedHint() != HintState::Unsupported);
        if (m_lockedHintSupported)
            log("LockedHint: supported — used to resolve lock state");
        else
            log("LockedHint: not exposed by this compositor — falling back to "
                "the locker's stdout (sessionLock.secure)");

        m_attempt = 0;
        m_reachedSecure = false;
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
            m_childFailedToStart = true;
        });
        m_childFailedToStart = false;
        m_child->start();

        // Watch the locker's stdout for the compositor-confirmed secure
        // transition; this is the lock-state signal when the compositor
        // exposes no LockedHint (niri), and the source for the escalation
        // gate (a respawn that reached secure and then crashed is never
        // auto-unlocked).
        connect(m_child, &QProcess::readyReadStandardOutput, this, [this] {
            const QByteArray out = m_child->readAllStandardOutput();
            if (out.contains("secure=true")) {
                m_lastSecure = true;
                if (m_attempt > 1)
                    m_reachedSecure = true;
            } else if (out.contains("secure=false")) {
                m_lastSecure = false;
            }
        });
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
        // rotate: pick the next file after the last one used, wrapping
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

        // Was the session locked when the child died? Ask the compositor:
        // LockedHint where the compositor sets it, the locker's own secure
        // log otherwise. (niri does not set LockedHint, so on niri this is
        // the locker's compositor-confirmed secure value.)
        bool diedWhileLocked;
        if (m_lockedHintSupported) {
            HintState hint = queryLockedHint();
            diedWhileLocked = (hint == HintState::Locked);
        } else {
            diedWhileLocked = m_lastSecure;
        }

        if (!diedWhileLocked) {
            log(QStringLiteral("clean exit (session not locked) — done"));
            QCoreApplication::quit();
            return;
        }

        // Respawn cap for a *locked* session only. The first locker is
        // attempt 1; respawns 2..N up to RESPAWN_LIMIT. After that, in-process
        // takeover (a crashed locker can never reach secure again, so the
        // respawn loop is bounded).
        if (m_attempt < RESPAWN_LIMIT) {
            log(QStringLiteral("locker died while locked — respawning in %1 ms "
                               "(attempt %2/%3)")
                    .arg(RESPAWN_BACKOFF_MS)
                    .arg(m_attempt + 1)
                    .arg(RESPAWN_LIMIT));
            QTimer::singleShot(RESPAWN_BACKOFF_MS, this, [this] {
                launch();
            });
        } else {
            log(QStringLiteral("respawn limit reached — in-process takeover"));
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
            log(QStringLiteral("takeover inconclusive"));
            QCoreApplication::exit(2);
            return;
        }
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
    bool m_reachedSecure = false;
    bool m_lastSecure = false;
    bool m_lockedHintSupported = false;
    bool m_childFailedToStart = false;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Supervisor supervisor;
    return app.exec();
}

#include "aerial-lock-supervisor.moc"
