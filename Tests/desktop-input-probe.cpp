#include <QGuiApplication>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QTimer>
#include <cstdio>

class DesktopProbe final : public QQuickWindow {
protected:
    void keyPressEvent(QKeyEvent *event) override {
        if (event->key() == Qt::Key_F12) {
            std::puts("DESKTOP_INPUT_RECEIVED");
            std::fflush(stdout);
            QCoreApplication::exit(0);
        }
    }
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    DesktopProbe window;
    window.setTitle("aerial remediation desktop input probe");
    window.setColor(Qt::darkGreen);
    window.resize(320, 240);
    window.show();
    QTimer readiness;
    QObject::connect(&readiness, &QTimer::timeout, [&window, &readiness] {
        if (!window.isActive() || !window.isExposed()) return;
        readiness.stop();
        std::puts("DESKTOP_INPUT_READY");
        std::fflush(stdout);
    });
    readiness.start(10);
    QTimer::singleShot(5000, [] { QCoreApplication::exit(1); });
    return app.exec();
}
