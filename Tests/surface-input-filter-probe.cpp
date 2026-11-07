#include "../native/surface-input.h"
#include <QInputMethodEvent>
#include <QQuickItem>
#include <QTest>
#include <cstdio>
#include <functional>
#include <vector>

struct Received {
    QEvent::Type type;
    int key;
    Qt::KeyboardModifiers modifiers;
    QString text;
    bool repeat;
};
class Window : public QQuickWindow {
public:
    std::vector<Received> keys;
    int inputMethods = 0;
    bool event(QEvent *event) override {
        if (event->type() == QEvent::InputMethod) { ++inputMethods; return true; }
        return QQuickWindow::event(event);
    }
protected:
    void keyPressEvent(QKeyEvent *event) override { record(event); }
    void keyReleaseEvent(QKeyEvent *event) override { record(event); }
private:
    void record(QKeyEvent *event) {
        keys.push_back({event->type(), event->key(), event->modifiers(), event->text(), event->isAutoRepeat()});
    }
};
static QStringList drops;
static QtMessageHandler previous;
static void messages(QtMsgType type, const QMessageLogContext &context, const QString &message) {
    if (message.startsWith("AerialLockSurfaceInput: dropped ")) drops.append(message);
    else if (previous) previous(type, context, message);
}
static int failed = 0;
static void expect(bool ok, const char *label) {
    std::printf("%s: %s\n", ok ? "ok" : "FAIL", label);
    if (!ok) ++failed;
}
static void key(Window &window, QEvent::Type type = QEvent::KeyPress, int value = Qt::Key_A,
                QString text = QStringLiteral("synthetic-not-for-logging")) {
    QKeyEvent event(type, value, Qt::ShiftModifier, text, true, 1);
    QCoreApplication::sendEvent(&window, &event);
}
static void activate(QQuickWindow &window) {
    window.resize(100, 100);
    window.show();
    window.requestActivate();
    expect(QTest::qWaitForWindowActive(&window, 1000), "native window focus-in exercised");
    QCoreApplication::processEvents();
}
// Opaque fixture ordinals survive cloning; all keys have identical, empty data.
class SequenceEvent final : public QKeyEvent {
public:
    explicit SequenceEvent(int sequence) : QKeyEvent(QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier), sequence(sequence) {}
    SequenceEvent *clone() const override { return new SequenceEvent(sequence); }
    const int sequence;
};
class SequenceWindow final : public QQuickWindow {
public:
    std::vector<int> received;
    std::function<void()> reenter;
    bool event(QEvent *event) override {
        if (auto *sequence = dynamic_cast<SequenceEvent *>(event)) {
            received.push_back(sequence->sequence);
            if (reenter) { auto callback = std::move(reenter); callback(); }
            return true;
        }
        return QQuickWindow::event(event);
    }
};
static void send(SequenceWindow &window, int sequence) {
    SequenceEvent event(sequence);
    QCoreApplication::sendEvent(&window, &event);
}
static void focusIn(SequenceWindow &window) {
    window.contentItem()->forceActiveFocus();
    QFocusEvent event(QEvent::FocusIn);
    QCoreApplication::sendEvent(&window, &event);
    QCoreApplication::processEvents();
}
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    SurfaceInputFilter filter;
    previous = qInstallMessageHandler(messages);
    {
        SequenceWindow window;
        window.setObjectName(SurfaceInputFilter::windowName());
        send(window, 1);
        send(window, 2);
        window.reenter = [&] {
            window.contentItem()->setFocus(false);
            window.contentItem()->forceActiveFocus();
            send(window, 3);
        };
        activate(window);
        expect(window.received == std::vector<int>({1, 2, 3}), "scheduled drain keeps FIFO under ready-key reentry");
    }
    {
        SequenceWindow window;
        window.setObjectName(SurfaceInputFilter::windowName());
        send(window, 1);
        window.reenter = [&] {
            send(window, 2);
            expect(window.received == std::vector<int>({1}), "last-key reentry is queued rather than recursively delivered");
        };
        activate(window);
        expect(window.received == std::vector<int>({1, 2}), "drain owns reentrant delivery even after popping its last key");
    }
    {
        SequenceWindow window;
        window.setObjectName(SurfaceInputFilter::windowName());
        send(window, 1);
        send(window, 2);
        window.reenter = [&] {
            window.contentItem()->setFocus(false);
            send(window, 3);
        };
        activate(window);
        expect(!window.activeFocusItem(), "reentrant focus loss leaves no active focus item");
        expect(window.received == std::vector<int>({1}), "focus loss pauses the drain without passing newer keys");
        focusIn(window);
        expect(window.received == std::vector<int>({1, 2, 3}), "focus-in resumes the same FIFO after mid-drain focus loss");
    }
    {
        SequenceWindow window;
        window.setObjectName(SurfaceInputFilter::windowName());
        activate(window);
        window.contentItem()->setFocus(false);
        send(window, 1);
        send(window, 2);
        window.contentItem()->forceActiveFocus();
        window.reenter = [&] {
            window.contentItem()->setFocus(false);
            send(window, 4);
        };
        send(window, 3);
        expect(window.received == std::vector<int>({1}), "ready-key drain cannot pass its triggering key after focus loss");
        focusIn(window);
        expect(window.received == std::vector<int>({1, 2, 3, 4}), "ready-key drain retains triggering and reentrant keys in FIFO order");
    }
    {
        Window window;
        key(window);
        expect(window.keys.size() == 1, "unmarked windows are never intercepted");
    }
    {
        Window window;
        window.setObjectName(SurfaceInputFilter::windowName());
        QInputMethodEvent input;
        input.setCommitString("synthetic");
        QCoreApplication::sendEvent(&window, &input);
        expect(window.inputMethods == 1, "input-method events are not intercepted");
        key(window);
        key(window, QEvent::KeyRelease);
        expect(window.keys.empty(), "pre-focus key pair retained");
        activate(window);
        key(window, QEvent::KeyPress, Qt::Key_B, "later");
        expect(window.keys.size() == 3, "pair replayed once before later key");
        if (window.keys.size() == 3) {
            expect(window.keys[0].type == QEvent::KeyPress && window.keys[1].type == QEvent::KeyRelease
                   && window.keys[2].key == Qt::Key_B, "native event order preserved");
            expect(window.keys[0].modifiers == Qt::ShiftModifier && window.keys[0].repeat
                   && window.keys[0].text == "synthetic-not-for-logging", "native key metadata preserved");
        }
        QCoreApplication::processEvents();
        expect(window.keys.size() == 3, "deferred drain cannot replay twice");
    }
    drops.clear();
    {
        Window window;
        window.setObjectName(SurfaceInputFilter::windowName());
        for (int i = 0; i <= SurfaceInputFilter::maximumEvents; ++i) key(window);
        expect(window.keys.empty(), "capacity test remains pre-focus");
        expect(drops == QStringList{"AerialLockSurfaceInput: dropped 1 key events"}, "capacity drop logs count only");
        activate(window);
        expect(window.keys.size() == SurfaceInputFilter::maximumEvents, "capacity never exceeds bound");
    }
    drops.clear();
    {
        Window window;
        window.setObjectName(SurfaceInputFilter::windowName());
        key(window);
        QTest::qWait(SurfaceInputFilter::maximumAgeMs + 30);
        expect(drops == QStringList{"AerialLockSurfaceInput: dropped 1 key events"}, "aged event expires with count-only log");
        activate(window);
        expect(window.keys.empty(), "expired event cannot resurrect after focus-in");
    }
    drops.clear();
    {
        Window window;
        window.setObjectName(SurfaceInputFilter::windowName());
        key(window);
        window.setObjectName("not-a-lock-surface");
        expect(drops == QStringList{"AerialLockSurfaceInput: dropped 1 key events"}, "scope removal clears retained keys");
        activate(window);
        expect(window.keys.empty(), "unmarked replacement role receives no stale keys");
    }
    drops.clear();
    {
        auto *window = new Window;
        window->setObjectName(SurfaceInputFilter::windowName());
        key(*window);
        delete window;
        expect(drops == QStringList{"AerialLockSurfaceInput: dropped 1 key events"}, "window destruction clears retained keys");
        Window replacement;
        replacement.setObjectName(SurfaceInputFilter::windowName());
        activate(replacement);
        expect(replacement.keys.empty(), "replacement window has no stale events");
    }
    for (const auto &message : drops) expect(!message.contains("synthetic"), "drop logs contain no payload");
    qInstallMessageHandler(previous);
    std::printf("SURFACE_INPUT_FILTER failures=%d\n", failed);
    return failed ? 1 : 0;
}
