PREFIX ?= /usr
DATADIR ?= $(PREFIX)/share/aerial-lock
BINDIR ?= $(PREFIX)/bin
PAMDIR ?= /etc/pam.d
CONFDIR ?= $(DATADIR)/Config
I18NDIR ?= $(CONFDIR)/i18n

PAM_MAX_RESP_SIZE ?=
DEBUG_DISMISS ?= 0
DEBUG_VERBOSE ?= 0

WAYLAND_PROTOCOLS ?= /usr/share/wayland-protocols
SESSION_LOCK_XML := $(WAYLAND_PROTOCOLS)/staging/ext-session-lock/ext-session-lock-v1.xml

.PHONY: all install uninstall dev clean pam-limits build-flags

all: pam-limits build-flags recovery/aerial-unlock supervisor/aerial-lock-supervisor

# Phony on purpose: the value can come from the environment, which Make
# cannot express as a file prerequisite. The generator is sub-second, so
# unconditional regeneration removes the stale-artifact bug class for free.
pam-limits:
ifdef PAM_MAX_RESP_SIZE
	@printf '{"maxResponseSize": %d, "source": "build-override"}\n' \
		$(PAM_MAX_RESP_SIZE) > Config/pam-limits.json
else
	@$(CC) -o gen-pam-limits.tmp gen-pam-limits.c
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

recovery/aerial-unlock: recovery/aerial-unlock.cpp recovery/ext-session-lock-v1-client.h recovery/ext-session-lock-v1-protocol.c
	$(CC) -c recovery/ext-session-lock-v1-protocol.c \
		$$(pkg-config --cflags wayland-client) -o /tmp/aerial-unlock-proto.o
	$(CXX) -c recovery/aerial-unlock.cpp -Irecovery \
		$$(pkg-config --cflags wayland-client) -o /tmp/aerial-unlock-main.o
	$(CXX) -o $@ /tmp/aerial-unlock-main.o /tmp/aerial-unlock-proto.o \
		$$(pkg-config --libs wayland-client)

supervisor/ext-session-lock-v1-client.h: $(SESSION_LOCK_XML)
	wayland-scanner client-header $< $@

supervisor/ext-session-lock-v1-protocol.c: $(SESSION_LOCK_XML)
	wayland-scanner private-code $< $@

supervisor/aerial-lock-supervisor.moc: supervisor/aerial-lock-supervisor.cpp
	/usr/lib/qt6/moc $< -o $@

supervisor/aerial-lock-supervisor: supervisor/aerial-lock-supervisor.cpp supervisor/aerial-lock-supervisor.moc supervisor/ext-session-lock-v1-client.h supervisor/ext-session-lock-v1-protocol.c
	$(CC) -c supervisor/ext-session-lock-v1-protocol.c \
		$$(pkg-config --cflags wayland-client) -o /tmp/aerial-supervisor-proto.o
	$(CXX) -fPIC -c supervisor/aerial-lock-supervisor.cpp -Isupervisor \
		$$(pkg-config --cflags Qt6Core Qt6DBus wayland-client) -o /tmp/aerial-supervisor-main.o
	$(CXX) -o $@ /tmp/aerial-supervisor-main.o /tmp/aerial-supervisor-proto.o \
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
	install -m 644 Services/qmldir $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/Logger.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/ConfigStore.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/PamLimits.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/PamProbe.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/BuildFlags.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/Compositor.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Config/defaults.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/pam-limits.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/build-flags.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/i18n/en.json $(DESTDIR)$(I18NDIR)/
	install -m 755 aerial-lock $(DESTDIR)$(BINDIR)/aerial-lock
	install -m 755 recovery/aerial-unlock $(DESTDIR)$(BINDIR)/aerial-unlock
	install -m 755 supervisor/aerial-lock-supervisor $(DESTDIR)$(BINDIR)/aerial-lock-supervisor
	install -d $(DESTDIR)$(PAMDIR)
	install -m 644 pam.d/aerial-lock $(DESTDIR)$(PAMDIR)/aerial-lock

uninstall:
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock
	rm -f $(DESTDIR)$(BINDIR)/aerial-unlock
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock-supervisor
	rm -f $(DESTDIR)$(PAMDIR)/aerial-lock

clean:
	rm -f gen-pam-limits.tmp Config/pam-limits.json Config/build-flags.json
	rm -f recovery/aerial-unlock recovery/ext-session-lock-v1-client.h recovery/ext-session-lock-v1-protocol.c
	rm -f supervisor/aerial-lock-supervisor supervisor/aerial-lock-supervisor.moc supervisor/ext-session-lock-v1-client.h supervisor/ext-session-lock-v1-protocol.c

dev: DEBUG_DISMISS=1
dev: DEBUG_VERBOSE=1
dev: all
	qs -p .
