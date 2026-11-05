// A private-bus login1/systemd peer. Never connects to the real system bus.
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusUnixFileDescriptor>
#include <QDBusVariant>
#include <QDBusVirtualObject>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSocketNotifier>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

using Display = std::tuple<QString, QDBusObjectPath>;
Q_DECLARE_METATYPE(Display)

static QElapsedTimer clockTime;
static void recordEvent(QJsonObject data)
{
    data["ms"] = double(clockTime.elapsed());
    const auto line = QJsonDocument(data).toJson(QJsonDocument::Compact) + '\n';
    fwrite(line.constData(), 1, size_t(line.size()), stdout);
    fflush(stdout);
}

class Peer : public QDBusVirtualObject {
public:
    Peer(QDBusConnection system, QDBusConnection session) : sys(system), bus(session) {}
    QString introspect(const QString &) const override { return {}; }
    bool handleMessage(const QDBusMessage &msg, const QDBusConnection &connection) override
    {
        const auto args = msg.arguments();
        const auto method = msg.member();
        if (method == "GetSession") {
            recordEvent({{"event", "session"}, {"id", args.value(0).toString()}});
            connection.send(msg.createReply({QVariant::fromValue(QDBusObjectPath(sessionPath))}));
        } else if (method == "Get" && args.value(1).toString() == "Display") {
            recordEvent({{"event", "display"}});
            connection.send(msg.createReply({QVariant::fromValue(QDBusVariant(
                QVariant::fromValue(Display{QStringLiteral("test-session"), QDBusObjectPath(sessionPath)})))}));
        } else if (method == "Get" && args.value(1).toString() == "InhibitDelayMaxUSec") {
            connection.send(msg.createReply({QVariant::fromValue(QDBusVariant(QVariant::fromValue(qulonglong(2000000))))}));
        } else if (method == "Get" && args.value(1).toString() == "PreparingForSleep") {
            recordEvent({{"event", "preparing"}, {"value", preparing}, {"fault", preparingFault}, {"systemOwner", sys.baseService()}});
            if (preparingFault == "error")
                connection.send(msg.createErrorReply("org.freedesktop.DBus.Error.Failed", "injected snapshot read failure"));
            else if (preparingFault == "non-bool")
                connection.send(msg.createReply({QVariant::fromValue(QDBusVariant(QStringLiteral("false")))}));
            else connection.send(msg.createReply({QVariant::fromValue(QDBusVariant(preparing))}));
        } else if (method == "Inhibit") {
            int fds[2];
            if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) < 0) return false;
            const int id = ++inhibitors;
            auto *watch = new QSocketNotifier(fds[0], QSocketNotifier::Read, this);
            QObject::connect(watch, &QSocketNotifier::activated, this, [watch, fd = fds[0], id] {
                char byte;
                if (read(fd, &byte, 1) == 0) {
                    watch->setEnabled(false);
                    close(fd);
                    watch->deleteLater();
                    recordEvent({{"event", "closed"}, {"id", id}});
                }
            });
            QJsonArray values;
            for (const auto &arg : args) values.append(arg.toString());
            recordEvent({{"event", "inhibit"}, {"id", id}, {"args", values}});
            connection.send(msg.createReply({QVariant::fromValue(QDBusUnixFileDescriptor(fds[1]))}));
            close(fds[1]);
        } else if (method == "StartTransientUnit") {
            QJsonObject properties;
            QList<QProcess *> pending;
            QProcessEnvironment environment = managerEnvironment;
            QStringList unsetEnvironment;
            QString unsetEnvironmentSignature;
            const auto entries = qvariant_cast<QDBusArgument>(args.value(2));
            entries.beginArray();
            while (!entries.atEnd()) {
                QString key;
                QDBusVariant value;
                entries.beginStructure(); entries >> key >> value; entries.endStructure();
                if (key == "ExecStart") {
                    const auto execs = qvariant_cast<QDBusArgument>(value.variant());
                    QJsonArray list;
                    execs.beginArray();
                    while (!execs.atEnd()) {
                        QString path;
                        QStringList argv;
                        bool ignore;
                        execs.beginStructure(); execs >> path >> argv >> ignore; execs.endStructure();
                        list.append(QJsonObject{{"path", path}, {"argv", QJsonArray::fromStringList(argv)}, {"ignore", ignore}});
                        auto *process = new QProcess(this);
                        process->setChildProcessModifier([] { setsid(); });
                        process->setProgram(path);
                        process->setArguments(argv.mid(1));
                        process->setStandardOutputFile(qEnvironmentVariable("IDLE_CASE") + "/unit-lock.log", QIODevice::Append);
                        process->setStandardErrorFile(qEnvironmentVariable("IDLE_CASE") + "/unit-lock.log", QIODevice::Append);
                        pending.append(process);
                    }
                    execs.endArray();
                    properties[key] = list;
                } else if (key == "Environment") {
                    const auto values = qdbus_cast<QStringList>(value.variant());
                    properties[key] = QJsonArray::fromStringList(values);
                    for (const auto &entry : values) {
                        const auto separator = entry.indexOf('=');
                        if (separator > 0) environment.insert(entry.left(separator), entry.mid(separator + 1));
                    }
                } else if (key == "UnsetEnvironment") {
                    unsetEnvironment = qdbus_cast<QStringList>(value.variant());
                    properties[key] = QJsonArray::fromStringList(unsetEnvironment);
                    unsetEnvironmentSignature = QString::fromLatin1(QDBusMetaType::typeToSignature(value.variant().metaType()));
                } else properties[key] = value.variant().toString();
            }
            entries.endArray();
            // Parse every property before starting: ExecStart may precede
            // Environment, and the caller's environment is not the manager's.
            // UnsetEnvironment is applied last, after manager/unit merging.
            for (const auto &key : unsetEnvironment) environment.remove(key);
            for (auto *process : pending) {
                process->setProcessEnvironment(environment);
                process->start();
                children.append(process);
            }
            recordEvent({{"event", "unit"}, {"signature", msg.signature()}, {"name", args.value(0).toString()},
                   {"mode", args.value(1).toString()}, {"properties", properties},
                   {"managerEnvironment", QJsonArray::fromStringList(managerEnvironment.toStringList())},
                   {"unsetEnvironmentSignature", unsetEnvironmentSignature},
                   {"auxSignature", qvariant_cast<QDBusArgument>(args.value(3)).currentSignature()}});
            connection.send(msg.createReply({QVariant::fromValue(QDBusObjectPath("/org/freedesktop/systemd1/job/1"))}));
        } else return false;
        return true;
    }
    void command(const QJsonObject &command)
    {
        const QString op = command.value("op").toString();
        if (op == "sleep") {
            preparing = command.value("value").toBool();
            auto signal = QDBusMessage::createSignal("/org/freedesktop/login1", "org.freedesktop.login1.Manager", "PrepareForSleep");
            signal << preparing; sys.send(signal);
        } else if (op == "preparing") {
            preparing = command.value("value").toBool(); // snapshot only, no signal
        } else if (op == "snapshot-fault") {
            preparingFault = command.value("mode").toString();
        } else if (op == "lock" || op == "unlock") {
            sys.send(QDBusMessage::createSignal(sessionPath, "org.freedesktop.login1.Session", op == "lock" ? "Lock" : "Unlock"));
        } else if (op == "drop") {
            sys.unregisterService("org.freedesktop.login1");
        } else if (op == "claim") {
            preparing = command.value("preparing").toBool(); // new instance's state
            sys = QDBusConnection::connectToBus(qEnvironmentVariable("DBUS_SYSTEM_BUS_ADDRESS"),
                                               QStringLiteral("fake-restart-%1").arg(++restarts));
            sys.registerVirtualObject("/org/freedesktop/login1", this, QDBusConnection::SubPath);
            sys.registerService("org.freedesktop.login1");
        } else if (op == "systemd") {
            managerEnvironment = QProcessEnvironment();
            const auto environment = command.value("environment").toObject();
            for (auto it = environment.begin(); it != environment.end(); ++it)
                managerEnvironment.insert(it.key(), it.value().toString());
            if (command.value("value").toBool()) bus.registerService("org.freedesktop.systemd1");
            else bus.unregisterService("org.freedesktop.systemd1");
        } else if (op == "quit") QCoreApplication::quit();
        recordEvent({{"event", "ack"}, {"op", op}, {"systemOwner", sys.baseService()}});
    }
    QDBusConnection sys, bus;
    QProcessEnvironment managerEnvironment;
    QString sessionPath = QStringLiteral("/org/freedesktop/login1/session/test");
    int inhibitors = 0;
    int restarts = 0;
    bool preparing = false;
    QString preparingFault;
    QList<QProcess *> children;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    clockTime.start();
    const auto sys = QDBusConnection::connectToBus(qEnvironmentVariable("DBUS_SYSTEM_BUS_ADDRESS"), "fake-system");
    const auto bus = QDBusConnection::sessionBus();
    if (!sys.isConnected() || !bus.isConnected()) return 1;
    qDBusRegisterMetaType<Display>();
    Peer peer(sys, bus);
    if (!peer.sys.registerVirtualObject("/org/freedesktop/login1", &peer, QDBusConnection::SubPath)
        || !peer.bus.registerVirtualObject("/org/freedesktop/systemd1", &peer, QDBusConnection::SubPath)
        || !peer.sys.registerService("org.freedesktop.login1")) return 1;
    fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
    QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
    QByteArray buffer;
    QObject::connect(&input, &QSocketNotifier::activated, &app, [&] {
        char bytes[4096];
        const auto count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count <= 0) { app.quit(); return; }
        buffer.append(bytes, count);
        while (buffer.contains('\n')) {
            const auto end = buffer.indexOf('\n');
            peer.command(QJsonDocument::fromJson(buffer.left(end)).object());
            buffer.remove(0, end + 1);
        }
    });
    recordEvent({{"event", "ready"}});
    return app.exec();
}
