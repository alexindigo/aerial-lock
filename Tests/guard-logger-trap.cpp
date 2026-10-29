#include <QtCore/qlogging.h>
#include <QString>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <unistd.h>

// Only preloaded into the credential-free guard fixture. Forward the real QS
// logger except for one static marker, where logging is deliberately blocked.
static QtMessageHandler previous = nullptr;
static void trap(QtMsgType type, const QMessageLogContext &context, const QString &message) {
    if (message == QStringLiteral("GUARD_TEST_BLOCK_LOGGER")) {
        const char ready[] = "CONNECTION_LOSS_LOGGER_HELD\n";
        ::write(STDERR_FILENO, ready, sizeof(ready) - 1);
        for (;;) ::pause();
    }
    if (previous) previous(type, context, message);
}

QtMessageHandler qInstallMessageHandler(QtMessageHandler handler) {
    const auto real = reinterpret_cast<decltype(&qInstallMessageHandler)>(dlsym(RTLD_NEXT,
        "_Z22qInstallMessageHandlerPFv9QtMsgTypeRK18QMessageLogContextRK7QStringE"));
    if (!real) ::_exit(90);
    const char *mode = std::getenv("AERIAL_TEST_FULL_CALLER_FAULT");
    if (mode && !std::strcmp(mode, "guard-logger") && handler && handler != trap) {
        previous = handler;
        return real(trap);
    }
    return real(handler);
}
