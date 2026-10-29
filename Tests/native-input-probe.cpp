// d43 native-input probe (test-only). Drives Tests/auth-input-fixture.qml
// with real key events (QTest), clipboard content, autorepeat key events
// and public QInputMethodEvent injection, asserting BOTH the authoritative
// model (context.auth.input) and the native editor agree at every step.
// Synthetic text only. No private Qt APIs; no platform-IM bridge claims.
#include <QGuiApplication>
#include <QFont>
#include <QQuickView>
#include <QQuickItem>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QPointer>
#include <QClipboard>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QTest>
#include <cstdio>
#include <memory>

static QObject *rootObj = nullptr;
static QQuickWindow *viewPtr = nullptr;
static int failures = 0;

static void settle() {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    QTest::qWait(1);
    QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
}

static void expect(bool cond, const char *label) {
    printf("%s: %s\n", cond ? "ok  " : "FAIL", label);
    if (!cond)
        failures++;
}

static void expectStr(const QString &actual, const QString &want, const char *label) {
    bool ok = actual == want;
    printf("%s: %s (actual %s)\n", ok ? "ok  " : "FAIL", label,
           ok ? "" : qPrintable(QStringLiteral("\"%1\" want \"%2\"").arg(actual, want)));
    if (!ok)
        failures++;
}

static void call(const char *fn, QVariant a = QVariant(), QVariant b = QVariant()) {
    bool ok;
    if (a.isValid() && b.isValid())
        ok = QMetaObject::invokeMethod(rootObj, fn, Q_ARG(QVariant, a), Q_ARG(QVariant, b));
    else if (a.isValid())
        ok = QMetaObject::invokeMethod(rootObj, fn, Q_ARG(QVariant, a));
    else
        ok = QMetaObject::invokeMethod(rootObj, fn);
    if (!ok)
        printf("FAIL: invoke %s failed\n", fn), failures++;
    settle();
}

static QJsonObject state() {
    QMetaObject::invokeMethod(rootObj, "snap");
    return QJsonDocument::fromJson(rootObj->property("outState").toString().toUtf8()).object();
}

static QObject *focusInput() { return viewPtr->focusObject(); }

static QString fText() {
    QObject *o = focusInput();
    return o ? o->property("text").toString() : QStringLiteral("<no focus object>");
}
static bool fComposing() {
    QObject *o = focusInput();
    return o && o->property("inputMethodComposing").toBool();
}
static QString fPreedit() {
    QObject *o = focusInput();
    return o ? o->property("preeditText").toString() : QStringLiteral("<no focus object>");
}

// QTest::keyClicks has no QWindow* overload — click char by char; Qt letter
// keys are uppercase, map ASCII lowercase.
static void clicks(const char *keys) {
    for (const char *p = keys; *p; ++p) {
        int k = static_cast<unsigned char>(*p);
        if (k >= 'a' && k <= 'z')
            k = Qt::Key_A + (k - 'a');
        QTest::keyClick(viewPtr, Qt::Key(k));
        settle();
    }
}

// Public-API IME injection: direct object delivery (the route Qt's own
// QQuickTextInput tests use). Does NOT prove the platform IM bridge.
static void ime(const QString &preedit, const QString &commit,
                int replaceFrom = 0, int replaceLen = 0) {
    QObject *focus = focusInput();
    if (!focus) {
        printf("FAIL: no focus object for IME event\n");
        failures++;
        return;
    }
    QList<QInputMethodEvent::Attribute> attrs;
    if (!preedit.isEmpty())
        attrs << QInputMethodEvent::Attribute(QInputMethodEvent::Cursor,
                                              preedit.size(), 1, QVariant());
    QInputMethodEvent ev(preedit, attrs);
    ev.setCommitString(commit, replaceFrom, replaceLen);
    QCoreApplication::sendEvent(focus, &ev);
    settle();
}

// Direct key event with explicit autorepeat flag (QTest cannot express it).
static void keyDirect(QEvent::Type type, int key, const QString &text, bool autorep) {
    QObject *focus = focusInput();
    if (!focus) {
        printf("FAIL: no focus object for key event\n");
        failures++;
        return;
    }
    QKeyEvent ev(type, key, Qt::NoModifier, text, autorep, 1);
    QCoreApplication::sendEvent(focus, &ev);
    settle();
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    const bool migration = argc > 1 && QString::fromUtf8(argv[1]) == QStringLiteral("--migration");
    QQmlEngine engine;
    QObject scopeOwner;
    std::unique_ptr<QQmlComponent> persistentComponent;
    auto view = std::make_unique<QQuickView>(&engine, nullptr);
    viewPtr = view.get();
    const int pathIndex = migration ? 2 : 1;
    const QUrl source = QUrl::fromLocalFile(
        argc > pathIndex ? QString::fromUtf8(argv[pathIndex]) : QStringLiteral("auth-input-fixture.qml"));
    if (migration) {
        // Match the production Scope's engine/creation-context ownership:
        // deleting a surface must not destroy the persistent editor's context.
        persistentComponent = std::make_unique<QQmlComponent>(&engine, source);
        rootObj = persistentComponent->create();
        auto *item = qobject_cast<QQuickItem *>(rootObj);
        if (!item) return 2;
        item->setParent(&scopeOwner);
        item->setParentItem(view->contentItem());
        view->resize(640, 480);
    } else {
        view->setSource(source);
        rootObj = view->rootObject();
    }
    if (!rootObj) {
        printf("FATAL: fixture failed to load\n");
        for (const auto &e : view->errors())
            printf("  %s\n", e.toString().toUtf8().constData());
        return 2;
    }
    view->show();
    (void)QTest::qWaitForWindowExposed(view.get());
    view->requestActivate();
    (void)QTest::qWaitForWindowActive(view.get(), 2000);

    if (migration) {
        call("newRig", 1, 0);
        clicks("prefix");
        QObject *const editor = focusInput();
        auto *rig = qobject_cast<QQuickItem *>(rootObj->property("rig").value<QObject *>());
        QObject *context = rig ? rig->property("context").value<QObject *>() : nullptr;
        QObject *auth = context ? context->property("auth").value<QObject *>() : nullptr;
        QObject *model = auth ? auth->property("input").value<QObject *>() : nullptr;
        expect(editor && rig && model, "migration: production editor/model located");
        if (!editor || !rig || !model) return 1;
        QMetaObject::invokeMethod(editor, "select", Q_ARG(int, 5), Q_ARG(int, 2));
        settle();
        const int revision = model->property("revision").toInt();
        const int writer = model->property("activeWriter").toInt();
        const bool latched = model->property("tuningLatched").toBool();
        rig->setParent(&scopeOwner); // independent controller ownership, as Lock Scope provides
        QQuickWindow survivor;
        survivor.resize(640, 480);
        survivor.show();
        (void)QTest::qWaitForWindowExposed(&survivor);
        rig->setParentItem(survivor.contentItem());
        viewPtr = &survivor;
        survivor.requestActivate();
        (void)QTest::qWaitForWindowActive(&survivor, 2000);
        QMetaObject::invokeMethod(rig->property("fieldA").value<QObject *>(), "focusField");
        settle();
        view.reset(); // old window/subtree is gone; the original editor must survive
        settle();
        expect(focusInput() == editor, "migration: identical native editor focused on survivor");
        expectStr(model->property("text").toString(), "prefix", "migration: committed draft survives old-window destruction");
        expect(model->property("revision").toInt() == revision, "migration: moving does not hydrate/reset the draft");
        expect(model->property("activeWriter").toInt() == writer, "migration: writer token retained");
        expect(model->property("tuningLatched").toBool() == latched, "migration: tuning progress retained");
        expect(editor->property("cursorPosition").toInt() == 2
               && editor->property("selectionStart").toInt() == 2
               && editor->property("selectionEnd").toInt() == 5, "migration: reverse selection retained");
        ime(QStringLiteral("ni"), QString());
        expect(fComposing() && fPreedit() == "ni", "migration: native preedit started");
        // Native IME initiation replaces the selected committed range. Keep
        // that ordinary edit, then prove migration adds no reset/serialization.
        const QString committedDuringPreedit = model->property("text").toString();
        const int composingRevision = model->property("revision").toInt();
        QQuickWindow next;
        next.resize(640, 480);
        next.show();
        (void)QTest::qWaitForWindowExposed(&next);
        rig->setParentItem(next.contentItem());
        viewPtr = &next;
        next.requestActivate();
        (void)QTest::qWaitForWindowActive(&next, 2000);
        QMetaObject::invokeMethod(rig->property("fieldA").value<QObject *>(), "focusField");
        settle();
        expect(focusInput() == editor, "migration: composing editor identity retained");
        expect(fComposing() && fPreedit() == "ni", "migration: native preedit survives cross-window attachment");
        expectStr(model->property("text").toString(), committedDuringPreedit,
                  "migration: committed draft unchanged across composing move");
        expect(model->property("revision").toInt() == composingRevision,
               "migration: composition move does not rehydrate/reset");
        expect(!model->property("text").toString().contains("ni"),
               "migration: preedit not serialized into committed draft");
        ime(QString(), QString::fromUtf8("\xE3\x81\xAB"));
        expect(model->property("text").toString().contains(QString::fromUtf8("\xE3\x81\xAB")),
               "migration: naturally delivered commit reaches authoritative model");
        rig->setParentItem(nullptr);
        printf("%s: %d failure(s)\n", failures == 0 ? "ALL OK" : "FAILURES", failures);
        return failures == 0 ? 0 : 1;
    }

    // ---------------- Phase 1: IME lifecycle ----------------
    call("newRig", 0, 0); // preserve / lock
    expect(focusInput() != nullptr, "p1: field focused");
    clicks("abc");
    expectStr(state()["text"].toString(), "abc", "p1: typed text reaches model");
    ime(QStringLiteral("n"), QString());
    expectStr(state()["text"].toString(), "abc", "p1: preedit does not touch model text");
    expect(fComposing() && fPreedit() == "n", "p1: native preedit visible, composing");
    ime(QStringLiteral("ni"), QString());
    expect(fComposing() && fPreedit() == "ni", "p1: preedit update");
    expectStr(state()["text"].toString(), "abc", "p1: model still untouched mid-composition");
    ime(QString(), QString::fromUtf8("\xE3\x81\xAB")); // commit に
    expectStr(state()["text"].toString(), QString::fromUtf8("abc\xE3\x81\xAB"), "p1: commit publishes to model");
    expect(!fComposing(), "p1: composition ended after commit");
    expect(state()["cursor"].toInt() == 4, "p1: caret after commit");
    // Commit + new preedit in ONE event.
    ime(QStringLiteral("k"), QString::fromUtf8("\xE3\x81\x8B")); // commit か, preedit k
    expectStr(state()["text"].toString(), QString::fromUtf8("abc\xE3\x81\xAB\xE3\x81\x8B"),
              "p1: one-event commit applied");
    expect(fComposing() && fPreedit() == "k", "p1: new composition continues in same event");
    // Cancel: empty commit + empty preedit preserves text.
    ime(QString(), QString());
    expect(!fComposing(), "p1: cancel ends composition");
    expectStr(state()["text"].toString(), QString::fromUtf8("abc\xE3\x81\xAB\xE3\x81\x8B"),
              "p1: cancel preserves committed text");

    // Unicode exactness: A, U+1F600 (surrogate pair), e, U+0301 combining
    // acute, U+4E2D — six UTF-16 code units, preserved exactly.
    QString uni = QString::fromUtf16(u"A\U0001F600e\u0301\u4E2D");
    call("newRig", 0, 0);
    ime(QString(), uni);
    expectStr(state()["text"].toString(), uni, "p1: unicode commit preserved exactly");
    expect(state()["text"].toString().size() == 6, "p1: UTF-16 code-unit count");
    expect(state()["cursor"].toInt() == 6, "p1: caret counts UTF-16 units");

    // Surrounding-text replacement: "abcXdef", caret 4, commit Z replacing
    // the two code units before the caret ("cX") -> "abZdef".
    call("newRig", 0, 0);
    clicks("abcxdef");
    settle();
    if (QObject *o = focusInput())
        o->setProperty("cursorPosition", 4);
    settle();
    ime(QString(), QStringLiteral("Z"), -2, 2);
    expectStr(state()["text"].toString(), "abZdef", "p1: surrounding-text replacement");
    expect(state()["cursor"].toInt() == 3, "p1: caret after surrounding replace");

    // ---------------- Phase 2: composition Return routing ----------------
    call("newRig", 0, 0);
    clicks("abc");
    ime(QStringLiteral("n"), QString());
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    expect(state()["submits"].toInt() == 0, "p2: Return while composing must not submit");
    expect(fComposing(), "p2: composition survives the Return");
    expectStr(state()["text"].toString(), "abc", "p2: Return while composing inserts nothing");
    ime(QString(), QString()); // cancel
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    expect(state()["submits"].toInt() == 1, "p2: Return submits once composition ended");
    expect(state()["accepted"].toArray().first().toString() == "abc", "p2: submitted draft is the model's");
    // Native undo cannot resurrect the consumed draft.
    clicks("zz");
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    QTest::keyClick(viewPtr, Qt::Key_Z, Qt::ControlModifier);
    settle();
    expectStr(state()["text"].toString(), "", "p2: native undo cannot resurrect submitted text");
    expect(state()["submits"].toInt() == 2, "p2: no extra submission from undo");

    // ---------------- Phase 3: initial-space tunings ----------------
    call("newRig", 1, 0); // ignoreFirst / lock
    keyDirect(QEvent::KeyPress, Qt::Key_Space, QStringLiteral(" "), false);
    expectStr(state()["text"].toString(), "", "p3: ignoreFirst consumes the initial press");
    keyDirect(QEvent::KeyPress, Qt::Key_Space, QStringLiteral(" "), true);
    keyDirect(QEvent::KeyPress, Qt::Key_Space, QStringLiteral(" "), true);
    expectStr(state()["text"].toString(), "", "p3: repeats of the ignored press are consumed");
    keyDirect(QEvent::KeyRelease, Qt::Key_Space, QString(), false);
    QTest::keyClick(viewPtr, Qt::Key_Space);
    settle();
    expectStr(state()["text"].toString(), " ", "p3: a later intentional Space is inserted");

    call("newRig", 2, 0); // ignoreLeading / lock
    QTest::keyClick(viewPtr, Qt::Key_Space);
    settle();
    keyDirect(QEvent::KeyPress, Qt::Key_Space, QStringLiteral(" "), true);
    QTest::keyClick(viewPtr, Qt::Key_Space);
    settle();
    expectStr(state()["text"].toString(), "", "p3: ignoreLeading consumes presses and repeats");
    clicks("a");
    QTest::keyClick(viewPtr, Qt::Key_Space);
    settle();
    expectStr(state()["text"].toString(), "a ", "p3: accepted insertion closes the window");

    // Paste beginning with spaces is NOT rewritten.
    call("newRig", 2, 0);
    QGuiApplication::clipboard()->setText(QStringLiteral("  ab"));
    QTest::keyClick(viewPtr, Qt::Key_V, Qt::ControlModifier);
    settle();
    expectStr(state()["text"].toString(), "  ab", "p3: paste payload kept verbatim");
    expect(state()["windowOpen"].toBool() == false, "p3: accepted paste closes the window");

    // IME commit containing spaces is NOT rewritten either.
    call("newRig", 2, 0);
    ime(QString(), QStringLiteral(" x"));
    expectStr(state()["text"].toString(), " x", "p3: IME commit payload kept verbatim");
    expect(state()["windowOpen"].toBool() == false, "p3: IME commit closes the window");

    // Modified Space is left to native handling (no insertion, window open).
    call("newRig", 2, 0);
    QTest::keyClick(viewPtr, Qt::Key_Space, Qt::ControlModifier);
    settle();
    QTest::keyClick(viewPtr, Qt::Key_Space);
    settle();
    expectStr(state()["text"].toString(), "", "p3: unmodified Space still initial after Ctrl+Space");
    clicks("a");
    expectStr(state()["text"].toString(), "a", "p3: first real character lands");

    // ---------------- Phase 4: handoff during composition ----------------
    call("newRig", 0, 0);
    clicks("pre");
    ime(QStringLiteral("n"), QString()); // start composing on A
    call("requestHandoff");
    {
        auto st = state();
        expect(st["state"].toString() == "releasing", "p4: handoff deferred while composing");
        expect(st["active"].toInt() == st["aToken"].toInt(), "p4: outgoing editor keeps authority");
        expect(fComposing(), "p4: native composition undisturbed (no forced commit/reset)");
    }
    ime(QString(), QString::fromUtf8("\xE3\x81\xAB")); // natural completion
    settle();
    {
        auto st = state();
        expect(st["state"].toString() == "", "p4: handoff completed after natural composition end");
        expect(st["active"].toInt() == st["bToken"].toInt(), "p4: incoming editor claimed");
        expectStr(st["text"].toString(), QString::fromUtf8("pre\xE3\x81\xAB"),
                  "p4: prefix preserved including the committed text");
    }
    call("promoteB");
    expect(state()["bFocus"].toBool(), "p4: promoted editor focused");
    clicks("fix");
    expectStr(state()["text"].toString(), QString::fromUtf8("pre\xE3\x81\xAB" "fix"),
              "p4: suffix continues the preserved draft");
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    expect(state()["accepted"].toArray().first().toString()
               == QString::fromUtf8("pre\xE3\x81\xAB" "fix"),
           "p4: submitted response combines pre/post-handoff text");

    // ---------------- Phase 5: busy gating and response limits ----------------
    call("newRig", 0, 0);
    clicks("ab");
    call("setBusy", true);
    clicks("c");
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    expectStr(state()["text"].toString(), "ab", "p5: disabled editor rejects keys while busy");
    expect(state()["submits"].toInt() == 0, "p5: busy submission rejected, draft preserved");
    call("setBusy", false);
    QTest::keyClick(viewPtr, Qt::Key_Return);
    settle();
    expect(state()["submits"].toInt() == 1, "p5: submission recovers after busy clears");

    // Known limit: cap is maxResponseSize - 1 at BOTH ends.
    call("setMaxResp", 5);
    QGuiApplication::clipboard()->setText(QStringLiteral("abcdefgh"));
    QTest::keyClick(viewPtr, Qt::Key_V, Qt::ControlModifier);
    settle();
    expectStr(state()["text"].toString(), "abcd", "p5: over-limit paste capped in model");
    expectStr(fText(), "abcd", "p5: over-limit paste capped in native editor");

    // Unknown limit (0): the widget ceiling applies, no PAM guessing.
    call("newRig", 0, 0);
    call("setMaxResp", 0);
    QGuiApplication::clipboard()->setText(QStringLiteral("abcdefgh"));
    QTest::keyClick(viewPtr, Qt::Key_V, Qt::ControlModifier);
    settle();
    expectStr(state()["text"].toString(), "abcdefgh", "p5: unknown limit keeps full paste");
    expectStr(fText(), "abcdefgh", "p5: native editor agrees");

    // ---------------- Phase 6: d44 presentation seams ----------------
    call("newRig", 0, 0);
    call("styleFieldA");
    settle();
    {
        QObject *focus = focusInput();
        expect(focus != nullptr, "p6: styled field focused");
        if (focus) {
            QFont f = focus->property("font").value<QFont>();
            expect(f.family() == "DejaVu Sans" || f.families().contains(QStringLiteral("DejaVu Sans")),
                   "p6: fontFamily seam applied to the native editor");
            expect(f.weight() == QFont::Bold, "p6: fontWeight seam applied");
            expect(qAbs(f.letterSpacing() - 2.0) < 0.01, "p6: fontLetterSpacing seam applied");
            expect(focus->property("horizontalAlignment").toInt() == 4 /*Qt::AlignHCenter*/,
                   "p6: horizontalAlignment seam applied");
            expect(!focus->property("cursorDelegate").isNull(), "p6: cursorDelegate seam applied");
        }
        // Styling must not mutate draft/selection/writer/tuning progress.
        auto before = state();
        clicks("ab");
        QTest::keyClick(viewPtr, Qt::Key_Return);
        settle();
        auto st = state();
        expect(st["submits"].toInt() == 1, "p6: styled field submits once");
        expect(st["accepted"].toArray().first().toString() == "ab",
               "p6: submitted draft unchanged by styling");
        expect(st["active"].toInt() == before["active"].toInt(),
               "p6: writer authority unchanged by styling");
        expect(st["windowOpen"].toBool() == false, "p6: tuning progress advanced normally");
    }

    printf("%s: %d failure(s)\n", failures == 0 ? "ALL OK" : "FAILURES", failures);
    return failures == 0 ? 0 : 1;
}
