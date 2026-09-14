PREFIX ?= /usr
DATADIR ?= $(PREFIX)/share/aerial-lock
BINDIR ?= $(PREFIX)/bin
PAMDIR ?= /etc/pam.d
CONFDIR ?= $(DATADIR)/Config
I18NDIR ?= $(CONFDIR)/i18n

PAM_MAX_RESP_SIZE ?=

WAYLAND_PROTOCOLS ?= /usr/share/wayland-protocols
SESSION_LOCK_XML := $(WAYLAND_PROTOCOLS)/staging/ext-session-lock/ext-session-lock-v1.xml

.PHONY: all install uninstall dev clean

all: Config/pam-limits.json recovery/aerial-unlock

Config/pam-limits.json: gen-pam-limits.c
ifdef PAM_MAX_RESP_SIZE
	@printf '{"maxResponseSize": %d, "source": "build-override"}\n' \
		$(PAM_MAX_RESP_SIZE) > $@
else
	@$(CC) -o gen-pam-limits.tmp gen-pam-limits.c
	@./gen-pam-limits.tmp > $@
	@rm -f gen-pam-limits.tmp
endif

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
	install -m 644 Services/ConfigStore.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Services/PamLimits.qml $(DESTDIR)$(DATADIR)/Services/
	install -m 644 Config/defaults.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/pam-limits.json $(DESTDIR)$(CONFDIR)/
	install -m 644 Config/i18n/en.json $(DESTDIR)$(I18NDIR)/
	install -m 755 aerial-lock $(DESTDIR)$(BINDIR)/aerial-lock
	install -m 755 recovery/aerial-unlock $(DESTDIR)$(BINDIR)/aerial-unlock
	install -d $(DESTDIR)$(PAMDIR)
	install -m 644 pam.d/aerial-lock $(DESTDIR)$(PAMDIR)/aerial-lock

uninstall:
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock
	rm -f $(DESTDIR)$(BINDIR)/aerial-unlock
	rm -f $(DESTDIR)$(PAMDIR)/aerial-lock

clean:
	rm -f gen-pam-limits.tmp Config/pam-limits.json
	rm -f recovery/aerial-unlock recovery/ext-session-lock-v1-client.h recovery/ext-session-lock-v1-protocol.c

dev: all
	qs -p .
