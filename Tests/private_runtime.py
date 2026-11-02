"""Own short private socket namespaces independently of fixture data paths."""
import os
from pathlib import Path
import tempfile

SOCKET_PATH_LIMIT = 107  # Linux sockaddr_un.sun_path, excluding the final NUL.


def assert_socket_paths(*paths):
    for path in paths:
        size = len(os.fsencode(path))
        assert size <= SOCKET_PATH_LIMIT, (
            f"AF_UNIX fixture socket path exceeds {SOCKET_PATH_LIMIT}-byte limit "
            f"({size} bytes): {path}")


class PrivateRuntime:
    """A direct TMPDIR child; descriptive fixture/case names never enter it."""
    def __init__(self, *socket_names):
        self._directory = tempfile.TemporaryDirectory(prefix="ai")
        self.path = Path(self._directory.name).resolve()
        try:
            assert_socket_paths(self.path / "aerial-lock/supervisor-9999999.sock",
                                *(self.path / name for name in socket_names))
        except BaseException:
            self.cleanup()
            raise

    def __enter__(self):
        return self.path

    def __exit__(self, *_):
        self.cleanup()

    def cleanup(self):
        self._directory.cleanup()
