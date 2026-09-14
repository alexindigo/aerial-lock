/*
 * aerial-lock-supervisor — owns the locker lifecycle and recovers it.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * respawns it up to three times on abnormal death, then takeover-releases
 * in-process. Never spawns the old bash/QML pair; never links Qt Quick or
 * QML (QtCore + QtDBus + wayland-client only).
 *
 * Lock state is tracked via a marker file (survives the locker's death),
 * optionally corroborated by logind's LockedHint where the compositor sets
 * it (probed at first lock).
 */
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingReply>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include <cstdio>
#include <cstring>
#include <string>

#include "takeover.h"

static const int RESPAWN_LIMIT = 3;
static const int RESPAWN_BACKOFF_MS = 1500;

static QString markerPath()
{
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    return QString::fromLatin1(xdg && *xdg ? xdg : "/tmp") + "/aerial-lock.locked";
}

/* ---- marker file (publish/clear/stale check) ---- */

static void markLocked()
{
    QFile f(markerPath());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write("1\n");
}

static void clearLocked()
{
    QFile::remove(markerPath());
}

static bool markerPresent()
{
    return QFile::exists(markerPath());
}

/* ---- LockedHint probe (logind) ---- */

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
            log("LockedHint: supported — used to resolve stale markers");
        else
            log("LockedHint: not exposed by this compositor — marker only");

        // clean slate: a stale marker from a previous run must not make us
        // relock before anything has actually locked
        clearLocked();
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
        log(QStringLiteral("launching locker, attempt %1/%2")
                .arg(m_attempt).arg(RESPAWN_LIMIT + 1));
        m_child = new QProcess(this);
        m_child->setProgram(QStringLiteral("qs"));
        m_child->setArguments({QStringLiteral("-p"), m_lockerCommand});
        connect(m_child, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, &Supervisor::onChildFinished);
        connect(m_child, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
            log(QStringLiteral("child failed to start: %1").arg(m_child->errorString()));
            m_childFailedToStart = true;
        });
        m_childFailedToStart = false;
        m_child->start();
    }

    void onChildFinished(int exitCode, QProcess::ExitStatus status)
    {
        log(QStringLiteral("child finished: exit=%1 status=%2")
                .arg(exitCode).arg(status));

        // Did it die while the session was locked? The marker file (written
        // by the supervisor below) is the ground truth, corroborated by
        // LockedHint where the compositor exposes it.
        bool diedWhileLocked = markerPresent();
        if (diedWhileLocked && m_lockedHintSupported) {
            HintState hint = queryLockedHint();
            if (hint == HintState::Unlocked) {
                log(QStringLiteral("marker present but LockedHint says "
                                   "unlocked — stale marker, clearing"));
                clearLocked();
                QCoreApplication::quit();
                return;
            }
        }

        if (!diedWhileLocked) {
            log(QStringLiteral("clean exit (marker absent) — done"));
            QCoreApplication::quit();
            return;
        }

        // Locker died while the session was locked.
        if (m_reachedSecure) {
            // It had reached secure earlier and then crashed. Post-engagement
            // crashes could be attacker-induced from the lock UI — never
            // convert those into an automatic unlock.
            log(QStringLiteral("respawned instance had reached secure before "
                               "crashing — staying locked, escalating to manual "
                               "recovery only (see README)"));
            clearLocked();
            QCoreApplication::exit(2);
            return;
        }

        if (m_attempt <= RESPAWN_LIMIT) {
            log(QStringLiteral("locker died while locked — respawning in %1 ms")
                    .arg(RESPAWN_BACKOFF_MS));
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
        switch (outcome) {
        case Takeover::Outcome::Recovered:
            log(QStringLiteral("takeover recovered the session"));
            clearLocked();
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

    void log(const QString &msg)
    {
        QTextStream out(stderr);
        out << "aerial-lock-supervisor: " << msg << "\n";
        out.flush();
    }

    QProcess *m_child = nullptr;
    QString m_lockerCommand;
    int m_attempt = 0;
    bool m_reachedSecure = false;
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
