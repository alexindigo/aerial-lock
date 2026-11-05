/*
 * aerial-lock-supervisor — owns the locker lifecycle; respawn-only recovery.
 *
 * Long-lived child process (the aerial-lock launcher): spawns the locker,
 * retries within three total attempts on abnormal death, and — when attempts run
 * out — reports failure without claiming an unavailable guard locked the
 * session. Recovery never unlocks automatically. An explicit Release() call
 * on the user's session bus or SIGUSR1 requests a graceful locker release,
 * bypassing PAM and disabling further respawns. The shelved auto-release work (Takeover::run as a
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
 *
 * Engagement state is never inferred from a running process or a held bus
 * name. Each locker attempt reports the compositor's lock confirmation over a
 * supervisor-owned channel that only that attempt's process is accepted on;
 * the supervisor publishes the result as State() on its session-scoped name.
 * A duplicate invocation for the same session exits 0 only after that State()
 * says "locked"; anything else it reports as not confirmed (exit 4).
 */
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusContext>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSocketNotifier>
#include <QTextStream>
#include <QThread>
#include <QTimer>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <wayland-client.h>

#include "../native/session-identity.h"
#include "../native/shell-dir.h"

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
static const char *SUPERVISOR_OBJECT_PATH = "/org/aeriallock/Supervisor";
static const char *SUPERVISOR_INTERFACE = "org.aeriallock.Supervisor";
// A duplicate invocation waits at most this long for the supervisor on duty to
// move from "engaging" to "locked" (a slow locker start or a pending respawn).
static const int ENGAGEMENT_CONFIRM_WAIT_MS = 10000;
static const int ENGAGEMENT_POLL_MS = 200;
// Duplicate invocation whose session lock could not be confirmed.
static const int DUPLICATE_UNCONFIRMED_EXIT = 4;
// Passed to each locker attempt: where to report its lock confirmation.
static const char *ENGAGEMENT_SOCKET_ENV = "AERIAL_LOCK_ENGAGEMENT_SOCKET";
static const QByteArray ENGAGEMENT_LOCKED_REPORT = QByteArrayLiteral("locked\n");
static const QByteArray RELEASE_REQUEST = QByteArrayLiteral("release\n");

// The signal handler only writes to a nonblocking pipe. Qt and the release
// state machine run on the event-loop thread, never in signal context.
static volatile sig_atomic_t releaseSignalFd = -1;
static void releaseSignalHandler(int)
{
    const int saved = errno;
    const char byte = 1;
    ssize_t result;
    do { result = ::write(int(releaseSignalFd), &byte, 1); } while (result < 0 && errno == EINTR);
    // EAGAIN means the pipe already contains a release request.
    errno = saved;
}

static void logLine(const QString &msg)
{
    QTextStream out(stderr);
    out << "aerial-lock-supervisor: " << msg << "\n";
    out.flush();
}

class Supervisor : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.aeriallock.Supervisor")
public:
    // engaging: a locker attempt is starting, respawning or running without
    //           (or no longer with) a confirmed lock.
    // locked:   the current attempt's locker reported ext-session-lock's
    //           `locked` event and is still alive and connected.
    // failed:   respawns ran out (exit 2/3); no lock is maintained by us.
    // ended:    the episode finished (unlock, refusal, compositor gone).
    enum class LockState { Engaging, Locked, Failed, Ended };

    explicit Supervisor(const QString &sessionSocket)
        : m_sessionSocket(sessionSocket)
    {
    }

    ~Supervisor() override
    {
        if (m_signalPipe[0] >= 0) {
            sigset_t mask;
            sigemptyset(&mask);
            sigaddset(&mask, SIGUSR1);
            ::sigprocmask(SIG_BLOCK, &mask, nullptr);
            releaseSignalFd = -1;
            delete m_signalNotifier;
            ::close(m_signalPipe[0]);
            ::close(m_signalPipe[1]);
        }
        closeReport();
        closeChannel();
    }

    // Runs only after this process owns the session's bus name.
    void start()
    {
        QString why;
        if (!openChannel(&why))
            log(QStringLiteral("engagement channel unavailable (%1) — locking anyway, but a duplicate "
                               "invocation cannot confirm this lock").arg(why));
        m_lockerCommand = lockerCommandLine();
        m_attempt = 0;
        launch();
    }

    // Only the atomic name-claim winner installs a handler. SIGUSR1 was
    // blocked before Qt created any threads; duplicates keep it blocked.
    bool installReleaseSignal()
    {
        if (::pipe2(m_signalPipe, O_CLOEXEC | O_NONBLOCK) != 0) return false;
        m_signalNotifier = new QSocketNotifier(m_signalPipe[0], QSocketNotifier::Read, this);
        connect(m_signalNotifier, &QSocketNotifier::activated, this, [this] {
            char bytes[128];
            ssize_t count;
            do { count = ::read(m_signalPipe[0], bytes, sizeof(bytes)); }
            while (count > 0 || (count < 0 && errno == EINTR));
            requestRelease(QStringLiteral("SIGUSR1"));
        });
        releaseSignalFd = m_signalPipe[1];
        struct sigaction action {};
        action.sa_handler = releaseSignalHandler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_RESTART;
        if (::sigaction(SIGUSR1, &action, nullptr) != 0) return false;
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGUSR1);
        return ::sigprocmask(SIG_UNBLOCK, &mask, nullptr) == 0;
    }

    static QString stateName(LockState state)
    {
        switch (state) {
        case LockState::Engaging: return QStringLiteral("engaging");
        case LockState::Locked: return QStringLiteral("locked");
        case LockState::Failed: return QStringLiteral("failed");
        case LockState::Ended: return QStringLiteral("ended");
        }
        return QStringLiteral("failed");
    }

public slots:
    // org.aeriallock.Supervisor.State — this episode's actual lock state.
    Q_SCRIPTABLE QString State() const { return stateName(m_state); }

    Q_SCRIPTABLE void Release()
    {
        if (!requestRelease(QStringLiteral("D-Bus")) && calledFromDBus())
            sendErrorReply(QStringLiteral("org.aeriallock.Supervisor.Error.NotLocked"),
                           QStringLiteral("This episode is not locked"));
    }

private:
    bool requestRelease(const QString &via)
    {
        if (m_state == LockState::Ended || m_state == LockState::Failed) return false;
        m_releaseRequested = true;
        log(QStringLiteral("release requested via %1 — %2")
                .arg(via, m_state == LockState::Locked ? QStringLiteral("delivering")
                                                       : QStringLiteral("pending lock confirmation")));
        deliverRelease();
        // A release during respawn backoff has no current locker to release.
        // End with unknown screen state rather than starting another attempt.
        if (!m_child) {
            log("release requested during respawn backoff — screen state unknown; no respawn");
            finishEpisode(2);
        }
        return true;
    }

    void deliverRelease()
    {
        if (!m_releaseRequested || m_releaseDelivered || m_state != LockState::Locked || m_reportFd < 0) return;
        while (m_releaseOffset < RELEASE_REQUEST.size()) {
            const ssize_t sent = ::send(m_reportFd, RELEASE_REQUEST.constData() + m_releaseOffset,
                                        size_t(RELEASE_REQUEST.size() - m_releaseOffset), MSG_NOSIGNAL);
            if (sent < 0 && errno == EINTR) continue;
            if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!m_releaseNotifier) {
                    m_releaseNotifier = new QSocketNotifier(m_reportFd, QSocketNotifier::Write, this);
                    connect(m_releaseNotifier, &QSocketNotifier::activated, this, [this] { deliverRelease(); });
                }
                return;
            }
            if (sent <= 0) {
                withdrawReport(QStringLiteral("release delivery failed — screen state unknown"));
                return;
            }
            m_releaseOffset += sent;
        }
        if (m_releaseNotifier) m_releaseNotifier->setEnabled(false);
        m_releaseDelivered = true;
        log("release delivered to the locker");
    }

    QString lockerCommandLine()
    {
        // the supervisor IS the aerial-lock launcher: it runs the locker
        // payload directly, so a bare `aerial-lock` invocation works both
        // before and after `make install`.
        return shellDir(QStringLiteral(AERIAL_LOCK_DEFAULT_SHELL));
    }

    void launch()
    {
        if (m_releaseRequested) return; // a pending backoff never revives a released episode
        m_attempt++;
        m_attemptSettled = false;
        // A new attempt has confirmed nothing yet, whatever an earlier one did.
        closeReport();
        m_reportAccepted = false;
        setState(LockState::Engaging);
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
        // Never let an inherited value point this attempt at another channel.
        env.remove(QString::fromLatin1(ENGAGEMENT_SOCKET_ENV));
        if (m_listenFd >= 0)
            env.insert(QString::fromLatin1(ENGAGEMENT_SOCKET_ENV), m_channelPath);
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
        // A locker that is gone confirms nothing; the next attempt must report anew.
        closeReport();
        if (m_state == LockState::Locked)
            setState(LockState::Engaging);

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

        if (m_releaseRequested) {
            if (exitCode == 0 && status == QProcess::NormalExit) {
                log("released locker exited cleanly — done");
                finishEpisode(0);
            } else {
                log("released, but the locker exited abnormally — screen state unknown; no respawn");
                finishEpisode(2);
            }
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
            // Respawns ran out. There is NO automatic unlock. Only an attempt
            // that confirmed the lock lets us say the session stays locked
            // (ext-session-lock keeps a confirmed lock after its client dies).
            // Manual recovery is aerial-unlock from a TTY/ops (see README).
            if (m_episodeEngaged)
                log("respawn limit reached — staying locked. NO automatic unlock. "
                    "Recover manually: aerial-unlock from a TTY (see README)");
            else
                log("respawn limit reached — no attempt confirmed the lock; the current screen state is "
                    "unknown. NO automatic unlock. Check the screen and recover manually from a TTY "
                    "if needed (see README)");
            finishEpisode(2);
        }
    }

    void finishEpisode(int code)
    {
        closeReport();
        setState(code == 0 ? LockState::Ended : LockState::Failed);
        if (m_hyprFlagSet) {
            setHyprlandRestoreFlag(false);
            m_hyprFlagSet = false;
        }
        QCoreApplication::exit(code);
    }

    void setState(LockState state)
    {
        if (m_state == state) return;
        m_state = state;
        log(QStringLiteral("state: %1").arg(stateName(state)));
    }

    // ---- engagement channel -------------------------------------------------
    // A private Unix socket under $XDG_RUNTIME_DIR/aerial-lock (the runner's
    // 0700 per-user directory). Only a connection whose SO_PEERCRED process is
    // the current attempt's child is accepted, once per attempt; it confirms
    // the lock by sending exactly "locked\n" and withdraws it by closing.

    static QByteArray channelBase()
    {
        const QByteArray runtime = qgetenv("XDG_RUNTIME_DIR");
        if (!runtime.startsWith('/')) return QByteArray();
        return runtime + "/aerial-lock";
    }

    static bool ownedEntry(const QByteArray &path, mode_t type)
    {
        struct stat info {};
        return lstat(path.constData(), &info) == 0 && (info.st_mode & S_IFMT) == type
            && info.st_uid == getuid();
    }

    // Sockets of supervisors that are no longer running are stale.
    static void removeStaleChannels(const QByteArray &base)
    {
        static const QRegularExpression name(QStringLiteral("^supervisor-([0-9]+)\\.sock$"));
        DIR *directory = ::opendir(base.constData());
        if (!directory) return;
        QList<QByteArray> stale;
        while (const dirent *entry = ::readdir(directory)) {
            const QRegularExpressionMatch match = name.match(QString::fromLatin1(entry->d_name));
            if (!match.hasMatch()) continue;
            if (QFileInfo::exists(QStringLiteral("/proc/") + match.captured(1))) continue;
            stale.append(base + '/' + QByteArray(entry->d_name));
        }
        ::closedir(directory);
        for (const QByteArray &path : std::as_const(stale))
            if (ownedEntry(path, S_IFSOCK)) ::unlink(path.constData());
    }

    bool openChannel(QString *why)
    {
        const QByteArray base = channelBase();
        if (base.isEmpty()) { *why = QStringLiteral("XDG_RUNTIME_DIR is not an absolute path"); return false; }
        if (::mkdir(base.constData(), 0700) != 0 && errno != EEXIST) {
            *why = QStringLiteral("cannot create %1: %2").arg(QFile::decodeName(base), QString::fromLocal8Bit(strerror(errno)));
            return false;
        }
        if (!ownedEntry(base, S_IFDIR) || ::chmod(base.constData(), 0700) != 0) {
            *why = QStringLiteral("%1 is not a private directory of this user").arg(QFile::decodeName(base));
            return false;
        }
        removeStaleChannels(base);
        const QByteArray path = base + "/supervisor-" + QByteArray::number(qint64(getpid())) + ".sock";
        sockaddr_un address {};
        address.sun_family = AF_UNIX;
        if (size_t(path.size()) >= sizeof(address.sun_path)) {
            *why = QStringLiteral("socket path is too long: %1").arg(QFile::decodeName(path));
            return false;
        }
        std::memcpy(address.sun_path, path.constData(), size_t(path.size()));
        // A socket left by an earlier holder of this PID is stale by definition.
        if (ownedEntry(path, S_IFSOCK)) ::unlink(path.constData());
        const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0 || ::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0
            || ::listen(fd, 4) != 0) {
            *why = QStringLiteral("cannot listen on %1: %2").arg(QFile::decodeName(path), QString::fromLocal8Bit(strerror(errno)));
            if (fd >= 0) ::close(fd);
            return false;
        }
        m_listenFd = fd;
        m_channelPath = QFile::decodeName(path);
        m_listenNotifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
        connect(m_listenNotifier, &QSocketNotifier::activated, this, [this] { acceptReports(); });
        return true;
    }

    void closeChannel()
    {
        if (m_listenFd < 0) return;
        delete m_listenNotifier;
        m_listenNotifier = nullptr;
        ::close(m_listenFd);
        m_listenFd = -1;
        ::unlink(QFile::encodeName(m_channelPath).constData());
    }

    void acceptReports()
    {
        for (;;) {
            const int fd = ::accept4(m_listenFd, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
            if (fd < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    // A persistent failure (e.g. no descriptors) would spin the
                    // event loop; stop listening — nothing can confirm a lock now.
                    log(QStringLiteral("engagement channel failed: %1 — a duplicate invocation cannot "
                                       "confirm this lock").arg(QString::fromLocal8Bit(strerror(errno))));
                    m_listenNotifier->setEnabled(false);
                }
                return;
            }
            ucred peer {};
            socklen_t size = sizeof(peer);
            const bool known = ::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) == 0
                && size == sizeof(peer);
            const qint64 child = m_child && !m_attemptSettled ? m_child->processId() : 0;
            if (!known || peer.uid != getuid() || child <= 0 || qint64(peer.pid) != child) {
                log(QStringLiteral("ignored an engagement report from pid %1: not the current locker")
                        .arg(known ? qint64(peer.pid) : -1));
                ::close(fd);
                continue;
            }
            if (m_reportAccepted) {
                log(QStringLiteral("ignored a second engagement connection from attempt %1").arg(m_attempt));
                ::close(fd);
                continue;
            }
            m_reportAccepted = true;
            m_reportFd = fd;
            m_reportBuffer.clear();
            m_reportNotifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
            connect(m_reportNotifier, &QSocketNotifier::activated, this, [this] { readReport(); });
        }
    }

    void readReport()
    {
        char chunk[64];
        for (;;) {
            const ssize_t count = ::recv(m_reportFd, chunk, sizeof(chunk), 0);
            if (count < 0) {
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) return;
                withdrawReport(QStringLiteral("report connection failed"));
                return;
            }
            if (count == 0) {
                withdrawReport(QStringLiteral("the locker withdrew its lock confirmation"));
                return;
            }
            m_reportBuffer.append(chunk, count);
            // Exactly one "locked\n" per attempt; anything else is a protocol
            // violation and never counts as engagement.
            if (m_state == LockState::Locked || !ENGAGEMENT_LOCKED_REPORT.startsWith(m_reportBuffer)) {
                withdrawReport(QStringLiteral("malformed engagement report"));
                return;
            }
            if (m_reportBuffer == ENGAGEMENT_LOCKED_REPORT) {
                m_episodeEngaged = true;
                log(QStringLiteral("attempt %1: the locker confirmed the session lock").arg(m_attempt));
                setState(LockState::Locked);
                deliverRelease();
                if (m_reportFd < 0) return;
            }
        }
    }

    void withdrawReport(const QString &reason)
    {
        log(QStringLiteral("attempt %1: %2").arg(m_attempt).arg(reason));
        closeReport();
        if (m_state == LockState::Locked)
            setState(LockState::Engaging);
    }

    void closeReport()
    {
        if (m_releaseNotifier) {
            m_releaseNotifier->setEnabled(false);
            m_releaseNotifier->deleteLater();
            m_releaseNotifier = nullptr;
        }
        if (m_reportFd < 0) return;
        // Never delete a notifier from inside its own activation.
        m_reportNotifier->setEnabled(false);
        m_reportNotifier->deleteLater();
        m_reportNotifier = nullptr;
        ::close(m_reportFd);
        m_reportFd = -1;
        m_reportBuffer.clear();
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

    static void log(const QString &msg) { logLine(msg); }

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
    LockState m_state = LockState::Engaging;
    bool m_episodeEngaged = false;
    int m_listenFd = -1;
    QString m_channelPath;
    QSocketNotifier *m_listenNotifier = nullptr;
    bool m_reportAccepted = false;
    int m_reportFd = -1;
    QSocketNotifier *m_reportNotifier = nullptr;
    QByteArray m_reportBuffer;
    bool m_releaseRequested = false;
    bool m_releaseDelivered = false;
    qsizetype m_releaseOffset = 0;
    QSocketNotifier *m_releaseNotifier = nullptr;
    int m_signalPipe[2] = {-1, -1};
    QSocketNotifier *m_signalNotifier = nullptr;
};

// Only printable state names are echoed; anything else is reported as malformed.
static QString printableState(const QString &state)
{
    static const QRegularExpression word(QStringLiteral("^[a-z]{1,32}$"));
    return word.match(state).hasMatch() ? QStringLiteral("\"%1\"").arg(state)
                                        : QStringLiteral("a malformed state");
}

// A duplicate invocation: another process owns this session's supervisor
// name. Owning the name proves nothing about the screen, so ask the owner for
// its actual engagement state. Exit 0 only on "locked"; wait (bounded) while
// it is "engaging"; every other outcome — an error or no reply, a malformed
// reply, an unknown or terminal state, the deadline — is "not confirmed".
static int confirmSupervisorOnDuty(const QDBusConnection &bus, const QString &service,
                                   const QString &session)
{
    logLine(QStringLiteral("another supervisor is on duty for %1 — confirming its lock engagement")
                .arg(session));
    const QString unconfirmed = QStringLiteral(
        " — lock engagement not confirmed; the screen may be unlocked. Exiting %1")
            .arg(DUPLICATE_UNCONFIRMED_EXIT);
    const QDeadlineTimer deadline(ENGAGEMENT_CONFIRM_WAIT_MS);
    bool waiting = false;
    for (;;) {
        if (waiting && deadline.hasExpired()) {
            logLine(QStringLiteral("the supervisor on duty did not confirm the lock within %1 ms")
                        .arg(ENGAGEMENT_CONFIRM_WAIT_MS) + unconfirmed);
            return DUPLICATE_UNCONFIRMED_EXIT;
        }
        QDBusMessage call = QDBusMessage::createMethodCall(
            service, QString::fromLatin1(SUPERVISOR_OBJECT_PATH),
            QString::fromLatin1(SUPERVISOR_INTERFACE), QStringLiteral("State"));
        call.setAutoStartService(false); // ask the owner; never activate one
        const int timeout = int(qBound(qint64(1), deadline.remainingTime(), qint64(ENGAGEMENT_CONFIRM_WAIT_MS)));
        const QDBusMessage reply = bus.call(call, QDBus::Block, timeout);
        if (reply.type() != QDBusMessage::ReplyMessage) {
            logLine(QStringLiteral("the supervisor on duty gave no valid state (%1)")
                        .arg(reply.errorName().isEmpty() ? QStringLiteral("no reply") : reply.errorName())
                    + unconfirmed);
            return DUPLICATE_UNCONFIRMED_EXIT;
        }
        const QList<QVariant> arguments = reply.arguments();
        if (reply.signature() != QLatin1String("s") || arguments.size() != 1
            || arguments.first().metaType().id() != QMetaType::QString) {
            logLine(QStringLiteral("the supervisor on duty sent a malformed state reply") + unconfirmed);
            return DUPLICATE_UNCONFIRMED_EXIT;
        }
        const QString state = arguments.first().toString();
        if (state == Supervisor::stateName(Supervisor::LockState::Locked)) {
            logLine(QStringLiteral("the supervisor on duty confirms its locker holds the session lock — exiting"));
            return 0;
        }
        if (state != Supervisor::stateName(Supervisor::LockState::Engaging)) {
            logLine(QStringLiteral("the supervisor on duty reports %1").arg(printableState(state)) + unconfirmed);
            return DUPLICATE_UNCONFIRMED_EXIT;
        }
        if (!waiting) {
            logLine(QStringLiteral("waiting for the supervisor on duty to confirm the lock (state: engaging)"));
            waiting = true;
        }
        QThread::msleep(ulong(qBound(qint64(1), deadline.remainingTime(), qint64(ENGAGEMENT_POLL_MS))));
    }
}

int main(int argc, char **argv)
{
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    if (::sigprocmask(SIG_BLOCK, &mask, nullptr) != 0) {
        std::perror("aerial-lock-supervisor: cannot block SIGUSR1");
        return 1;
    }
    QCoreApplication app(argc, argv);
    const QString session = sessionSocketPath();
    if (session.isEmpty()) {
        logLine("cannot identify the Wayland session to protect "
                "(WAYLAND_DISPLAY is relative and XDG_RUNTIME_DIR is unset) — exiting");
        return 1;
    }
    QDBusConnection bus = QDBusConnection::sessionBus();
    QDBusConnectionInterface *const busService = bus.isConnected() ? bus.interface() : nullptr;
    if (!busService) {
        logLine(QStringLiteral("no session bus (%1) — cannot keep one supervisor per session; exiting")
                    .arg(bus.lastError().message()));
        return 1;
    }
    Supervisor supervisor(session);
    // Export State() before claiming the name, so the name never exists
    // without the method that reports what it protects.
    if (!bus.registerObject(QString::fromLatin1(SUPERVISOR_OBJECT_PATH), &supervisor,
                            QDBusConnection::ExportScriptableSlots)) {
        logLine(QStringLiteral("cannot export the supervisor state (%1) — exiting").arg(bus.lastError().message()));
        return 1;
    }
    const QString service = supervisorServiceName(session);
    const QDBusReply<QDBusConnectionInterface::RegisterServiceReply> claim = busService->registerService(service);
    if (!claim.isValid()) {
        logLine(QStringLiteral("cannot claim the supervisor name for %1 (%2) — exiting")
                    .arg(session, claim.error().message()));
        return 1;
    }
    if (claim.value() != QDBusConnectionInterface::ServiceRegistered) {
        bus.unregisterObject(QString::fromLatin1(SUPERVISOR_OBJECT_PATH));
        return confirmSupervisorOnDuty(bus, service, session);
    }
    if (!supervisor.installReleaseSignal()) {
        logLine("cannot install the release signal handler — exiting without launching a locker");
        return 1;
    }
    supervisor.start();
    return app.exec();
}

#include "aerial-lock-supervisor.moc"
