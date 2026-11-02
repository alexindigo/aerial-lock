// Exercise terminal D-Bus replies on the real Supervisor without adding a
// product lifetime/test switch. Normal builds use main's app.exec()/exit.
#define main supervisorMain
#include "../supervisor/aerial-lock-supervisor.cpp"
#undef main

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Supervisor supervisor(sessionSocketPath());
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerObject(QString::fromLatin1(SUPERVISOR_OBJECT_PATH), &supervisor,
                            QDBusConnection::ExportScriptableSlots)
        || !bus.registerService(supervisorServiceName(sessionSocketPath())))
        return 1;
    supervisor.start();
    QDeadlineTimer deadline(10000);
    while (supervisor.State() != QStringLiteral("ended") && supervisor.State() != QStringLiteral("failed")) {
        if (deadline.hasExpired()) return 1;
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(1);
    }
    QDeadlineTimer terminal(1000);
    while (!terminal.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        QThread::msleep(1);
    }
    return 0;
}
