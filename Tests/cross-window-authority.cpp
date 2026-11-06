// Public Qt IME-event surrogate of the stock Mozc type/Escape reduction.
// This checks native editor -> shared draft, not the platform IME bridge.
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <cstdio>
#include <memory>

static int failures = 0;
static void expect(bool condition, const char *label) {
    std::printf("%s: %s\n", condition ? "ok  " : "FAIL", label);
    if (!condition) ++failures;
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (argc != 3) return 2;
    const QString mode = QString::fromLocal8Bit(argv[1]);
    const bool sameWindow = mode == QStringLiteral("same-window");
    const bool emptyState = mode == QStringLiteral("empty-state");
    const bool focusOut = mode == QStringLiteral("focus-out");
    QQmlEngine engine;
    QQmlComponent component(&engine, QUrl::fromLocalFile(QString::fromLocal8Bit(argv[2])));
    std::unique_ptr<QObject> root(component.create());
    if (!root) return 3;
    QQuickWindow first, second;
    first.resize(640, 480);
    second.resize(640, 480);
    auto create = [&](const char *method, QQuickWindow &window) {
        expect(QMetaObject::invokeMethod(root.get(), method,
               Q_ARG(QVariant, QVariant::fromValue(window.contentItem()))), "fixture editor created");
    };
    create(sameWindow ? "newSink" : "newPanel", first);
    auto *model = root->property("draft").value<QObject *>();
    first.show();
    if (!QTest::qWaitForWindowExposed(&first)) return 4;
    first.requestActivate();
    if (!QTest::qWaitForWindowActive(&first)) return 5;
    QObject *outgoing = app.focusObject();
    if (!outgoing || !outgoing->property("preeditText").isValid()) return 6;
    QTest::keyClick(&first, Qt::Key_X);
    expect(model->property("text").toString() == QStringLiteral("x"), "prefix reaches shared draft");
    const int writer = model->property("activeWriter").toInt();
    const int generation = model->property("generation").toInt();
    const int revision = model->property("revision").toInt();
    const bool residual = emptyState || focusOut;
    QInputMethodEvent preedit(residual ? QString() : QStringLiteral("n"),
        {QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, residual ? 0 : 1, 1, QVariant())});
    QCoreApplication::sendEvent(outgoing, &preedit);
    expect(outgoing->property("inputMethodComposing").toBool()
           && model->property("compositionActive").toBool(), "native composition reported");
    expect(outgoing->property("preeditText").toString() == (residual ? QString() : QStringLiteral("n")),
           "native preedit matches surrogate state");
    if (sameWindow) {
        create("attachPanel", first);
        QTest::qWait(1);
        expect(app.focusObject() == outgoing, "same-window replacement retains native focus");
        expect(model->property("activeWriter").toInt() == writer
               && model->property("generation").toInt() == generation,
               "same-window replacement retains authority and generation");
        expect(model->property("revision").toInt() == revision, "panel arrival commits nothing");
    }
    if (!residual) {
        // Normal focus-out commits before new-window activation. In the
        // same-window case this is the user's natural composition completion.
        QInputMethodEvent commit;
        commit.setCommitString(QStringLiteral("z"));
        QCoreApplication::sendEvent(outgoing, &commit);
        expect(model->property("text").toString() == QStringLiteral("xz")
               && model->property("revision").toInt() == revision + 1,
               "natural commit publishes exactly once");
    }
    QQuickWindow &incoming = sameWindow ? first : second;
    if (sameWindow) {
        QTest::qWait(1); // pending same-window replacement follows textEdited
    } else {
        if (!focusOut) create("newSink", second);
        second.show();
        if (!QTest::qWaitForWindowExposed(&second)) return 7;
        second.requestActivate();
        if (!QTest::qWaitForWindowActive(&second)) return 8;
        if (focusOut) {
            expect(outgoing->property("inputMethodComposing").toBool(), "native residual flag remains untouched");
            expect(model->property("activeWriter").toInt() == writer,
                   "focus-out alone does not replace the writer");
            expect(!model->property("compositionActive").toBool(),
                   "focus-out publishes current activity before another editor exists");
            create("newSink", second);
        }
    }
    expect(app.focusWindow() == &incoming && app.focusObject() && app.focusObject() != outgoing,
           "incoming native editor has focus");
    expect(model->property("activeWriter") == model->property("focusedWriter")
           && model->property("activeWriter").toInt() != writer,
           "incoming editor owns authority without composition wait");
    expect(!model->property("compositionActive").toBool(), "activity describes current native focus");
    QTest::keyClick(&incoming, Qt::Key_B);
    const QString expected = residual ? QStringLiteral("xb") : QStringLiteral("xzb");
    expect(app.focusObject()->property("text").toString() == expected, "incoming native key delivered");
    expect(model->property("text").toString() == expected
           && model->property("revision").toInt() == revision + (residual ? 1 : 2),
           "first incoming key publishes to shared draft exactly once");
    // A late notification from the old editor cannot poison the new owner.
    QInputMethodEvent ended;
    QCoreApplication::sendEvent(outgoing, &ended);
    expect(!model->property("compositionActive").toBool(), "outgoing activity cannot overwrite new owner");
    std::printf("%s: %d failure(s)\n", failures == 0 ? "ALL OK" : "FAILURES", failures);
    return failures == 0 ? 0 : 1;
}
