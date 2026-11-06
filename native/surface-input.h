#pragma once

#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QPointer>
#include <QQuickWindow>
#include <QSet>
#include <QTimer>
#include <chrono>
#include <deque>
#include <map>
#include <memory>

// Transport only: Qt can deliver a newly mapped lock window's key before its
// focus-in. QQuickDeliveryAgent drops that key before QML sees it. Retain only
// this gap, then use the ordinary window delivery path after focus-in.
class SurfaceInputFilter final : public QObject {
public:
    static constexpr int maximumEvents = 64;
    static constexpr int maximumAgeMs = 250;
    static QString windowName() { return QStringLiteral("aerial-lock-surface"); }

    explicit SurfaceInputFilter(QObject *parent = nullptr) : QObject(parent) {
        qGuiApp->installEventFilter(this);
    }

protected:
    bool eventFilter(QObject *receiver, QEvent *event) override {
        auto *window = qobject_cast<QQuickWindow *>(receiver);
        if (!window || window->objectName() != windowName() || replaying.contains(event))
            return false;
        if (event->type() == QEvent::FocusIn) {
            // The event filter runs before QQuickWindow::focusInEvent. Its
            // normal handler must resolve the root/field and QML authority first.
            QPointer<QQuickWindow> target(window);
            QTimer::singleShot(0, this, [this, target] { if (target) drain(target); });
            return false;
        }
        if (event->type() != QEvent::KeyPress && event->type() != QEvent::KeyRelease)
            return false;
        if (QGuiApplication::focusWindow() == window && window->activeFocusItem()) {
            drain(window); // a new key must not overtake the scheduled drain
            return false;
        }
        auto &state = stateFor(window);
        expire(state);
        if (state.keys.size() == maximumEvents) {
            reportDrop(1);
        } else {
            state.keys.push_back({Clock::now(), std::unique_ptr<QKeyEvent>(static_cast<QKeyEvent *>(event)->clone())});
            arm(state);
        }
        event->accept();
        return true;
    }

private:
    using Clock = std::chrono::steady_clock;
    struct Key {
        Clock::time_point arrived;
        std::unique_ptr<QKeyEvent> event;
    };
    struct State {
        std::deque<Key> keys;
        std::unique_ptr<QTimer> timer;
        QMetaObject::Connection destroyed;
        QMetaObject::Connection retagged;
        bool draining = false;
        ~State() { QObject::disconnect(destroyed); QObject::disconnect(retagged); }
    };
    std::map<QQuickWindow *, std::unique_ptr<State>> windows;
    QSet<const QEvent *> replaying;

    static void reportDrop(size_t count) {
        if (count) qWarning("AerialLockSurfaceInput: dropped %zu key events", count);
    }
    static void expire(State &state) {
        const auto cutoff = Clock::now() - std::chrono::milliseconds(maximumAgeMs);
        size_t dropped = 0;
        while (!state.keys.empty() && state.keys.front().arrived <= cutoff) {
            state.keys.pop_front();
            ++dropped;
        }
        reportDrop(dropped);
    }
    static void arm(State &state) {
        if (state.keys.empty()) { state.timer->stop(); return; }
        auto age = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - state.keys.front().arrived).count();
        state.timer->start(qMax(1, maximumAgeMs - int(age)));
    }
    State &stateFor(QQuickWindow *window) {
        auto found = windows.find(window);
        if (found != windows.end()) return *found->second;
        auto state = std::make_unique<State>();
        state->timer = std::make_unique<QTimer>();
        state->timer->setSingleShot(true);
        connect(state->timer.get(), &QTimer::timeout, this, [this, window] {
            auto found = windows.find(window);
            if (found != windows.end()) { expire(*found->second); arm(*found->second); }
        });
        state->destroyed = connect(window, &QObject::destroyed, this, [this, window] {
            clear(window);
        });
        state->retagged = connect(window, &QObject::objectNameChanged, this, [this, window](const QString &name) {
            if (name != windowName()) clear(window);
        });
        auto *result = state.get();
        windows.emplace(window, std::move(state));
        return *result;
    }
    void clear(QQuickWindow *window) {
        auto found = windows.find(window);
        if (found != windows.end()) {
            reportDrop(found->second->keys.size());
            windows.erase(found);
        }
    }
    void drain(QQuickWindow *window) {
        auto found = windows.find(window);
        if (found == windows.end() || found->second->draining) return;
        found->second->draining = true;
        QPointer<QQuickWindow> target(window);
        while (target && QGuiApplication::focusWindow() == target && target->activeFocusItem()) {
            found = windows.find(window);
            if (found == windows.end()) return;
            auto &state = *found->second;
            expire(state);
            if (state.keys.empty()) break;
            auto event = std::move(state.keys.front().event);
            state.keys.pop_front();
            replaying.insert(event.get());
            QCoreApplication::sendEvent(target, event.get());
            replaying.remove(event.get());
        }
        found = windows.find(window);
        if (found != windows.end()) {
            found->second->draining = false;
            arm(*found->second);
        }
    }
};
