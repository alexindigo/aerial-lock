PREFIX ?= /usr
DATADIR ?= $(PREFIX)/share/aerial-lock
BINDIR ?= $(PREFIX)/bin
PAMDIR ?= /etc/pam.d
CONFDIR ?= $(DATADIR)/Config
I18NDIR ?= $(CONFDIR)/i18n

PAM_MAX_RESP_SIZE ?=

.PHONY: all install uninstall dev clean

all: Config/pam-limits.json

Config/pam-limits.json: gen-pam-limits.c
ifdef PAM_MAX_RESP_SIZE
	@printf '{"maxResponseSize": %d, "source": "build-override"}\n' \
		$(PAM_MAX_RESP_SIZE) > $@
else
	@$(CC) -o gen-pam-limits.tmp gen-pam-limits.c
	@./gen-pam-limits.tmp > $@
	@rm -f gen-pam-limits.tmp
endif

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
	install -d $(DESTDIR)$(PAMDIR)
	install -m 644 pam.d/aerial-lock $(DESTDIR)$(PAMDIR)/aerial-lock

uninstall:
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(BINDIR)/aerial-lock
	rm -f $(DESTDIR)$(PAMDIR)/aerial-lock

clean:
	rm -f gen-pam-limits.tmp Config/pam-limits.json

dev: all
	qs -p .
