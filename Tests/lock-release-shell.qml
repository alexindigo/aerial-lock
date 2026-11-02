import QtQuick
import Quickshell
import Quickshell.Services.Pam
import "../Modules/Lock" as LockModule
import "../Services" as Services

// Real WlSessionLock and Loader teardown; only PAM's endpoint is synthetic.
ShellRoot {
    id: fixture
    settings.watchFiles: false
    property bool failed: false
    property int assertions: 0
    property int unlocks: 0
    property bool destroyed: false
    readonly property LockModule.Lock lock: loader.item as LockModule.Lock
    function check(ok, name) {
        assertions++
        if (!ok) { failed = true; console.error("LOCK_RELEASE_ASSERTION_FAILED " + name) }
    }
    Services.ConfigStore { id: cfg }
    QtObject {
        id: endpoint
        property bool active: false
        property bool responseRequired: false
        property bool responseVisible: false
        property string message: ""
        property bool messageIsError: false
        property string user: "synthetic-release"
        property string config: "synthetic"
        property int aborts: 0
        signal pamMessage()
        signal completed(int result)
        signal error(int error)
        function start() { active = true; return true }
        function respond(answer) {}
        function abort() {
            aborts++
            active = false
            completed(PamResult.Success) // cancellation must guard synchronous completion
        }
    }
    Loader {
        id: loader
        active: cfg.ready
        sourceComponent: Component {
            LockModule.Lock {
                config: cfg
                logger: Services.Logger
                pamEndpoint: endpoint
                Component.onDestruction: fixture.destroyed = true
                onUnlocked: {
                    fixture.unlocks++
                    fixture.check(attemptCancelled && !endpoint.active, "PAM attempt cancelled before unlock")
                    fixture.check(acceptedResponse === null && !unlockInProgress, "pending PAM state cleared")
                    loader.active = false
                    finished.start()
                }
            }
        }
    }
    Services.EngagementReport {
        path: Quickshell.env("AERIAL_LOCK_ENGAGEMENT_SOCKET") || ""
        secure: fixture.lock !== null && fixture.lock.secure
        onReleaseRequested: {
            fixture.check(fixture.lock !== null && fixture.lock.secure, "real lock confirmed")
            fixture.lock.tryUnlock() // leave a synthetic PAM call in flight
            fixture.check(endpoint.active && fixture.lock.unlockInProgress, "PAM active before release")
            fixture.lock.release()
            // Idempotence before deferred Loader destruction.
            if (fixture.lock !== null) fixture.lock.release()
        }
    }
    Timer {
        id: finished
        interval: 20
        onTriggered: {
            fixture.check(fixture.unlocks === 1, "unlocked emitted once")
            fixture.check(fixture.lock === null && fixture.destroyed, "normal Loader tree torn down")
            fixture.check(endpoint.aborts >= 1, "PAM aborted")
            console.log("LOCK_RELEASE_OUTCOME assertions=" + fixture.assertions + " failed=" + fixture.failed)
            Qt.exit(fixture.failed ? 1 : 0)
        }
    }
    Timer { interval: 20000; running: true; onTriggered: { console.error("LOCK_RELEASE_NOT_EXERCISED"); Qt.exit(1) } }
}
