PREFIX ?= /usr
DATADIR ?= $(PREFIX)/share/aerial-lock
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec/aerial-lock
PLUGINROOT ?= $(PREFIX)/lib/aerial-lock/qt-plugins
PAMDIR ?= /etc/pam.d
CONFDIR ?= $(DATADIR)/Config
I18NDIR ?= $(CONFDIR)/i18n

PAM_MAX_RESP_SIZE ?=
DEBUG_DISMISS ?= 0
DEBUG_VERBOSE ?= 0

WAYLAND_PROTOCOLS ?= /usr/share/wayland-protocols
SESSION_LOCK_XML := $(WAYLAND_PROTOCOLS)/staging/ext-session-lock/ext-session-lock-v1.xml

# Native objects stay inside this tree (gitignored, removed by `clean`), so
# concurrent builds of different checkouts never share or mix objects, and
# nothing is written to a global temporary directory. Every native rule
# honours the standard CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS (e.g. makepkg's
# hardening flags).
OBJDIR ?= build
UNLOCK_OBJS := $(OBJDIR)/aerial-unlock-proto.o $(OBJDIR)/aerial-unlock-main.o
SUPERVISOR_OBJS := $(OBJDIR)/aerial-supervisor-proto.o $(OBJDIR)/aerial-supervisor-main.o
GUARD_OBJS := $(OBJDIR)/connection-guard.o
GUARD_PLUGIN := native/qt-plugins/generic/libAerialLockConnectionGuard.so

.PHONY: all install uninstall dev clean pam-limits build-flags

all: pam-limits build-flags recovery/aerial-unlock supervisor/aerial-lock-supervisor $(GUARD_PLUGIN)

# Phony on purpose: the value can come from the environment, which Make
# cannot express as a file prerequisite. The generator is sub-second, so
# unconditional regeneration removes the stale-artifact bug class for free.
pam-limits:
ifdef PAM_MAX_RESP_SIZE
	@printf '{"maxResponseSize": %d, "source": "build-override"}\n' \
		$(PAM_MAX_RESP_SIZE) > Config/pam-limits.json
else
	@$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o gen-pam-limits.tmp gen-pam-limits.c
	@./gen-pam-limits.tmp > Config/pam-limits.json
	@rm -f gen-pam-limits.tmp
endif
	@cat Config/pam-limits.json

# Phony on purpose, same rationale as pam-limits: the values come from the
# environment, which Make cannot express as a file prerequisite. The two
# flags are independent — DEBUG_VERBOSE=1 alone gives a chatty build with no
# authentication bypass.
build-flags:
	@printf '{ "debugAllowDismiss": %s, "verbose": %s }\n' \
		$(if $(filter 1,$(DEBUG_DISMISS)),true,false) \
		$(if $(filter 1,$(DEBUG_VERBOSE)),true,false) > Config/build-flags.json
	@cat Config/build-flags.json

recovery/ext-session-lock-v1-client.h: $(SESSION_LOCK_XML)
	wayland-scanner client-header $< $@

recovery/ext-session-lock-v1-protocol.c: $(SESSION_LOCK_XML)
	wayland-scanner private-code $< $@

$(OBJDIR)/aerial-unlock-proto.o: recovery/ext-session-lock-v1-protocol.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< \
		$$(pkg-config --cflags wayland-client) -o $@

$(OBJDIR)/aerial-unlock-main.o: recovery/aerial-unlock.cpp recovery/ext-session-lock-v1-client.h
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -Irecovery \
		$$(pkg-config --cflags wayland-client) -o $@

recovery/aerial-unlock: $(UNLOCK_OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(OBJDIR)/aerial-unlock-main.o $(OBJDIR)/aerial-unlock-proto.o \
		$$(pkg-config --libs wayland-client)

supervisor/ext-session-lock-v1-client.h: $(SESSION_LOCK_XML)
	wayland-scanner client-header $< $@

supervisor/ext-session-lock-v1-protocol.c: $(SESSION_LOCK_XML)
	wayland-scanner private-code $< $@

supervisor/aerial-lock-supervisor.moc: supervisor/aerial-lock-supervisor.cpp
	/usr/lib/qt6/moc $< -o $@

$(OBJDIR)/aerial-supervisor-proto.o: supervisor/ext-session-lock-v1-protocol.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< \
		$$(pkg-config --cflags wayland-client) -o $@

$(OBJDIR)/aerial-supervisor-main.o: supervisor/aerial-lock-supervisor.cpp supervisor/aerial-lock-supervisor.moc supervisor/ext-session-lock-v1-client.h
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -fPIC -c $< -Isupervisor \
		-DAERIAL_LOCK_DEFAULT_SHELL='"$(DATADIR)"' \
		-DAERIAL_LOCK_DEFAULT_RUNNER='"$(LIBEXECDIR)/aerial-lock-run"' \
		-DAERIAL_LOCK_DEFAULT_PLUGIN_ROOT='"$(PLUGINROOT)"' \
		$$(pkg-config --cflags Qt6Core Qt6DBus wayland-client) -o $@

native/connection-guard.moc: native/connection-guard.cpp native/connection-guard.json
	/usr/lib/qt6/moc $$(pkg-config --cflags Qt6Core Qt6Gui wayland-client) $< -o $@

$(OBJDIR)/connection-guard.o: native/connection-guard.cpp native/connection-guard.moc native/connection-guard.json
	@mkdir -p $(@D)
	$(CXX) -std=c++17 $(CPPFLAGS) $(CXXFLAGS) -fPIC -pthread -c $< \
		$$(pkg-config --cflags Qt6Core Qt6Gui wayland-client) -o $@

$(GUARD_PLUGIN): $(GUARD_OBJS)
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -shared -pthread -o $@ $(GUARD_OBJS) \
		$$(pkg-config --libs Qt6Core Qt6Gui wayland-client) -ldl

supervisor/aerial-lock-supervisor: $(SUPERVISOR_OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(OBJDIR)/aerial-supervisor-main.o $(OBJDIR)/aerial-supervisor-proto.o \
		$$(pkg-config --libs Qt6Core Qt6DBus wayland-client)

install: all
	install -d $(DESTDIR)$(DATADIR)
	install -d $(DESTDIR)$(DATADIR)/Modules/Lock
	install -d $(DESTDIR)$(DATADIR)/Services
	install -d $(DESTDIR)$(CONFDIR)
	install -d $(DESTDIR)$(I18NDIR)
	install -d $(DESTDIR)$(BINDIR)
	install -m 644 shell.qml $(DESTDIR)$(DATADIR)/shell.qml
	install -m 644 Modules/Lock/qmldir $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/Lock.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/LockContent.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/LockBackground.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/AccentSampler.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/AccentTone.js $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/ThemeHost.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/AuthField.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/Avatar.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -m 644 Modules/Lock/FrostedText.qml $(DESTDIR)$(DATADIR)/Modules/Lock/
	install -d $(DESTDIR)$(DATADIR)/Themes
	install -m 644 Themes/Macintosh.qml $(DESTDIR)$(DATADIR)/Themes/
	install -m 644 Themes/Windows7.qml $(DESTDIR)$(DATADIR)/Themes/
	install -m 644 Themes/MaterialYou.qml $(DESTDIR)$(DATADIR)/Themes/
	install -m 644 Themes/Enfield.qml $(DESTDIR)$(DATADIR)/Themes/
	install -m 644 Themes/Clockwork.qml $(DESTDIR)$(DATADIR)/Themes/
	# d44 font bundles + attribution/notices (OFL 1.1; see Themes/ATTRIBUTION.md)
	install -m 644 Themes/ATTRIBUTION.md $(DESTDIR)$(DATADIR)/Themes/
	install -d $(DESTDIR)$(DATADIR)/Themes/fonts/google-sans
	install -m 644 "Themes/fonts/google-sans/GoogleSans-VariableFont_GRAD,opsz,wght.ttf" $(DESTDIR)$(DATADIR)/Themes/fonts/google-sans/
	install -m 644 Themes/fonts/google-sans/OFL.txt $(DESTDIR)$(DATADIR)/Themes/fonts/google-sans/
	install -m 644 Themes/fonts/google-sans/NOTICE $(DESTDIR)$(DATADIR)/Themes/fonts/google-sans/
	install -d $(DESTDIR)$(DATADIR)/Themes/fonts/orbitron
	install -m 644 Themes/fonts/orbitron/Orbitron-VariableFont_wght.ttf $(DESTDIR)$(DATADIR)/Themes/fonts/orbitron/
	install -m 644 Themes/fonts/orbitron/OFL.txt $(DESTDIR)$(DATADIR)/Themes/fonts/orbitron/
	install -m 644 Themes/fonts/orbitron/NOTICE $(DESTDIR)$(DATADIR)/Themes/fonts/orbitron/
	install -d $(DESTDIR)$(DATADIR)/Themes/fonts/outfit
	install -m 644 Themes/fonts/outfit/Outfit-Black.ttf $(DESTDIR)$(DATADIR)/Themes/fonts/outfit/
	install -m 644 Themes/fonts/outfit/OFL.txt $(DESTDIR)$(DATADIR)/Themes/fonts/outfit/
	install -m 644 Themes/fonts/outfit/NOTICE $(DESTDIR)$(DATADIR)/Themes/fonts/outfit/
	install -m 644 Services/qmldir $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/Logger.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/ConfigStore.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/PamLimits.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/PamProbe.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/BuildFlags.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/Compositor.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/SourceCache.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/ThemeSelection.js $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/LockContext.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/AuthInputState.qml $(DESTDIR)$(DATADIR)/Services/
	install -d $(DESTDIR)$(DATADIR)/Services/Compositor
	install -m 644 Services/Compositor/NiriBackend.qml $(DESTDIR)$(DATADIR)/Services/Compositor/
	install -m 644 Services/Compositor/HyprlandBackend.qml $(DESTDIR)$(DATADIR)/Services/Compositor/
	install -m 644 Config/defaults.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/pam-limits.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/build-flags.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/i18n/en.json $(DESTDIR)$(I18NDIR)/
	install -m 755 aerial-lock $(DESTDIR)$(BINDIR)/aerial-lock
	install -m 755 Scripts/aerial-lock-fetch $(DESTDIR)$(BINDIR)/aerial-lock-fetch
	install -m 755 recovery/aerial-unlock $(DESTDIR)$(BINDIR)/aerial-unlock
	install -m 755 supervisor/aerial-lock-supervisor $(DESTDIR)$(BINDIR)/aerial-lock-supervisor
	install -d $(DESTDIR)$(LIBEXECDIR) $(DESTDIR)$(PLUGINROOT)/generic
	install -m 755 Scripts/aerial-lock-run $(DESTDIR)$(LIBEXECDIR)/aerial-lock-run
	install -m 755 $(GUARD_PLUGIN) $(DESTDIR)$(PLUGINROOT)/generic/
	install -d $(DESTDIR)$(PAMDIR)
	install -m 644 pam.d/aerial-lock $(DESTDIR)$(PAMDIR)/aerial-lock

uninstall:
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock-fetch
	rm -f $(DESTDIR)$(BINDIR)/aerial-unlock
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock-supervisor
	rm -f $(DESTDIR)$(LIBEXECDIR)/aerial-lock-run $(DESTDIR)$(PLUGINROOT)/generic/libAerialLockConnectionGuard.so
	rm -f $(DESTDIR)$(PAMDIR)/aerial-lock

clean:
	rm -f gen-pam-limits.tmp Config/pam-limits.json Config/build-flags.json
	rm -f recovery/aerial-unlock recovery/ext-session-lock-v1-client.h recovery/ext-session-lock-v1-protocol.c
	rm -f supervisor/aerial-lock-supervisor supervisor/aerial-lock-supervisor.moc supervisor/ext-session-lock-v1-client.h supervisor/ext-session-lock-v1-protocol.c
	rm -f native/connection-guard.moc $(GUARD_PLUGIN)
	rm -f $(UNLOCK_OBJS) $(SUPERVISOR_OBJS) $(GUARD_OBJS)
	@rmdir $(OBJDIR) 2>/dev/null || true

dev: DEBUG_DISMISS=1
dev: DEBUG_VERBOSE=1
dev: all
	bash Scripts/dev/run.sh
