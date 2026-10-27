# QML suites

Run in the project's authorized test VM, with a disk-backed `TMPDIR`:

```sh
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=opengl LIBGL_ALWAYS_SOFTWARE=1 \
  /usr/lib/qt6/bin/qmltestrunner -import Tests/imports -input Tests/tst_theme_host.qml
```

The same invocation supports every `Tests/tst_*.qml` suite. The test-only
`imports/Quickshell` modules let standalone QtTest load ThemeHost's types
without Quickshell's executable-linked plugins. They supply only its inactive
I/O boundary; any environment or file access throws. The handoff suite loads
the actual ThemeHost, Loader, timers, AuthInputState and candidate QML, while
driving a synthetic writer's composition and explicit release. Real native
IME handling belongs to the native input probe; real theme discovery and
Quickshell loading belong to the nested-shell camera gate.
