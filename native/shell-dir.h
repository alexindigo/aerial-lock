#pragma once

#include <QString>

// The supervisor's QML payload and the idle reader must use the same bundle.
static QString shellDir(const QString &compiledDefault)
{
    const QString shell = qEnvironmentVariable("AERIAL_LOCK_SHELL");
    return shell.isEmpty() ? compiledDefault : shell;
}
