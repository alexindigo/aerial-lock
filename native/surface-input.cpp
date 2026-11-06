#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "surface-input.h"
#include <QGenericPlugin>
#include <cstdlib>
#include <dlfcn.h>
#include <unistd.h>

namespace {
char moduleAnchor;
bool authorized() {
    bool valid = false;
    auto owner = qgetenv("AERIAL_LOCK_SURFACE_INPUT_OWNER_PID").toLongLong(&valid);
    return valid && owner == static_cast<qlonglong>(getpid());
}
void pinModule() {
    Dl_info module{};
    if (!dladdr(&moduleAnchor, &module) || !module.dli_fname) ::_exit(72);
    // The service is app-owned, independent of Qt's disposable plugin facade.
    // Keep its code resident through GUI/factory teardown, as for the guard.
    if (!dlopen(module.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE)) ::_exit(72);
}
}

class AerialLockSurfaceInput final : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "surface-input.json")
public:
    QObject *create(const QString &name, const QString &specification) override {
        Q_UNUSED(specification)
        if (name.compare(QStringLiteral("AerialLockSurfaceInput"), Qt::CaseInsensitive) != 0)
            return nullptr;
        if (authorized()) {
            if (!qGuiApp) ::_exit(72);
            pinModule();
            new SurfaceInputFilter(qGuiApp);
            if (!qputenv("AERIAL_LOCK_SURFACE_INPUT_PID", QByteArray::number(getpid()))) ::_exit(72);
        }
        return new QObject;
    }
};

#include "surface-input.moc"
