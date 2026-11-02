#pragma once

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QString>

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
