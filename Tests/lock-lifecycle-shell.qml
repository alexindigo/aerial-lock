import QtQuick
import Quickshell
import Quickshell.Services.Pam
import "../Modules/Lock" as LockModule
import "../Services" as Services

ShellRoot {
    id: fixture
    settings.watchFiles: false
    property bool failed: false
    property int assertions: 0
    property int writer: -1
    property int phase: 0
    readonly property LockModule.Lock lock: lockLoader.item as LockModule.Lock
    function check(condition, name) {
        assertions++
        if (!condition) {
            failed = true
            console.error("LOCK_LIFECYCLE_ASSERTION_FAILED " + name)
        }
    }
    function draft(text) {
        var input = fixture.lock.context.auth.input
        if (writer < 0) {
            writer = input.registerWriter()
            check(input.claimWriter(writer), "fixture writer claim")
        }
        check(input.applyEdit(writer, input.revision, text, text.length, text.length), "fixture coherent synthetic draft")
    }
    Services.ConfigStore { id: fixtureConfig }
    QtObject {
        id: endpoint
        property bool active: false
        property string message: ""
        property bool messageIsError: false
        property bool responseRequired: false
        property bool responseVisible: false
        property string user: "synthetic-fixture"
        property string config: "synthetic"
        property string startMode: "inline"
        property string respondMode: "prompt"
        property int starts: 0
        property int responses: 0
        property string lastResponse: ""
        signal pamMessage()
        signal completed(int result)
        signal error(int error)
        function prompt() {
            message = ""
            responseRequired = true
            pamMessage()
        }
        function start() {
            starts++
            if (startMode === "reject") return false
            active = true
            if (startMode === "inline") prompt()
            else if (startMode === "error") error(1)
            else if (startMode === "complete") { active = false; completed(PamResult.Success) }
            else if (startMode === "silent") {} // in flight, no PAM traffic at all
            else Qt.callLater(endpoint.prompt)
            return true
        }
        function abort() { active = false; responseRequired = false }
        function respond(answer) {
            responses++
            lastResponse = answer
            if (respondMode === "prompt") prompt()
            else if (respondMode === "async-prompt") Qt.callLater(endpoint.prompt)
            else if (respondMode === "error") { active = false; responseRequired = false; error(1) }
            else {
                active = false
                responseRequired = false
                completed(PamResult.Success)
            }
        }
    }
    Loader {
        id: lockLoader
        active: fixtureConfig.ready
        sourceComponent: Component {
            LockModule.Lock {
                config: fixtureConfig
                logger: Services.Logger
                locked: false // exercise the real controller without locking this startup fixture
                pamEndpoint: endpoint
            }
        }
        onLoaded: sequence.start()
    }
    Timer {
        id: sequence
        interval: 20
        onTriggered: {
            var lock = fixture.lock
            if (phase === 0) {
                check(Quickshell.env("AERIAL_LOCK_CONNECTION_GUARD_PID") === String(Quickshell.processId), "guard PID matches")
                lock.tryUnlock() // empty initial response: expose prompt, never queue an answer
                check(endpoint.starts === 1 && endpoint.responses === 0, "empty initial starts without queued answer")
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "synchronous empty request visibly prompting")
                check(lock.statusMessage.length > 0, "empty PAM message uses translated fallback")
                endpoint.abort()
                draft("synthetic-prefix")
                lock.tryUnlock()
                check(endpoint.responses === 1 && endpoint.lastResponse === "synthetic-prefix", "queued answer existed before synchronous first prompt")
                check(lock.acceptedResponse === null, "queued answer removed before respond")
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "synchronous next prompt not overwritten in queued respond")
                check(lock.context.auth.input.text === "", "accepted draft consumed exactly once")
                lock.tryUnlock() // active empty answer is meaningful
                check(endpoint.responses === 2 && endpoint.lastResponse === "", "active empty answer sent unchanged")
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "direct respond prompt not overwritten")
                endpoint.respondMode = "complete"
                draft("synthetic-completion")
                lock.tryUnlock()
                check(lock.authState === lock.authSuccess && !lock.unlockInProgress, "synchronous direct completion not overwritten")
                check(lock.context.auth.input.text === "", "completed consumed draft cannot reappear")
                endpoint.abort()
                endpoint.startMode = "inline"
                draft("synthetic-queued-completion")
                lock.tryUnlock()
                check(lock.authState === lock.authSuccess && !lock.unlockInProgress, "synchronous queued-respond completion not overwritten")
                check(lock.acceptedResponse === null && lock.context.auth.input.text === "", "queued completion consumes only accepted draft")
                endpoint.startMode = "async"
                endpoint.respondMode = "prompt"
                lock.tryUnlock()
                check(lock.authState === lock.authAuthenticating && lock.unlockInProgress, "async start awaits explicit prompt")
                phase = 1
                sequence.restart()
            } else if (phase === 1) {
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "asynchronous explicit request visibly prompting")
                endpoint.abort()
                endpoint.startMode = "reject"
                draft("synthetic-rejected-start")
                lock.tryUnlock()
                check(lock.authState === lock.authError && !lock.unlockInProgress && lock.acceptedResponse === null, "failed start cleanup settles once")
                check(lock.context.auth.input.text === "", "rejected accepted draft does not resurrect")
                endpoint.startMode = "error"
                lock.tryUnlock()
                check(lock.authState === lock.authError && !lock.unlockInProgress && lock.acceptedResponse === null, "inline start error not overwritten")
                endpoint.abort()
                endpoint.startMode = "complete"
                lock.tryUnlock()
                check(lock.authState === lock.authSuccess && !lock.unlockInProgress, "inline start completion not overwritten")
                endpoint.abort()
                endpoint.startMode = "inline"
                endpoint.respondMode = "error"
                lock.tryUnlock()
                draft("synthetic-direct-error")
                lock.tryUnlock()
                check(lock.authState === lock.authError && !lock.unlockInProgress && lock.acceptedResponse === null, "inline direct respond error not overwritten")
                check(lock.context.auth.input.text === "", "direct error accepted draft remains consumed")
                endpoint.abort()
                draft("synthetic-queued-error")
                lock.tryUnlock()
                check(lock.authState === lock.authError && !lock.unlockInProgress && lock.acceptedResponse === null, "inline queued respond error not overwritten")
                endpoint.abort()
                endpoint.respondMode = "async-prompt"
                lock.tryUnlock()
                draft("synthetic-async-direct")
                lock.tryUnlock()
                check(lock.authState === lock.authAuthenticating && lock.unlockInProgress, "async direct respond awaits explicit prompt")
                phase = 2
                sequence.restart()
            } else if (phase === 2) {
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "async direct respond request visibly prompting")
                endpoint.abort()
                draft("synthetic-async-queued")
                lock.tryUnlock()
                check(lock.authState === lock.authAuthenticating && lock.unlockInProgress && lock.acceptedResponse === null, "async queued respond awaits explicit prompt without duplicate answer")
                phase = 3
                sequence.restart()
            } else if (phase === 3) {
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress, "async queued respond request visibly prompting")
                check(lock.context.auth.input.text === "", "async queued accepted draft does not resurrect")
                // PAM now waits for the user. Outlast the inactivity watchdog.
                check(fixtureConfig.data.pamWatchdogTimeoutMs > 0 && fixtureConfig.data.pamWatchdogTimeoutMs <= 2000,
                      "fixture config uses a short PAM watchdog")
                phase = 4
                watchdogWait.restart()
            }
        }
    }
    Timer {
        id: watchdogWait
        interval: fixtureConfig.data.pamWatchdogTimeoutMs + 500
        onTriggered: {
            var lock = fixture.lock
            if (phase === 4) {
                check(lock.authState === lock.authPrompting && !lock.unlockInProgress
                      && lock.statusMessage !== lock.context.labels.timedOut,
                      "waiting for the user is never timed out")
                check(endpoint.active && !lock.attemptCancelled, "prompt awaiting the user is not aborted")
                endpoint.abort()
                endpoint.startMode = "silent"
                lock.tryUnlock()
                check(lock.authState === lock.authAuthenticating && lock.unlockInProgress, "silent PAM call in flight")
                phase = 5
                watchdogWait.restart()
            } else {
                check(lock.authState === lock.authError && !lock.unlockInProgress
                      && lock.statusMessage === lock.context.labels.timedOut,
                      "in-flight PAM call without traffic times out")
                check(!endpoint.active && lock.attemptCancelled, "timed-out PAM call aborted")
                console.log("LOCK_LIFECYCLE_OUTCOME assertions=" + assertions + " failed=" + failed)
                Qt.exit(failed ? 1 : 0)
            }
        }
    }
    Timer { interval: 20000; running: true; onTriggered: { console.error("LOCK_LIFECYCLE_NOT_EXERCISED"); Qt.exit(1) } }
}
