"""Complete-file publication for cross-process test receipts and markers."""
import fcntl
import os
from pathlib import Path
import tempfile


def publish(path, content, *, append=False):
    """Expose only closed, complete snapshots, including append-only journals.

    Serialize journal updates so overlapping runners cannot hide duplicate
    launches through lost updates. Dot-prefixed staging and lock names cannot
    match the fixtures' marker globs.
    """
    path = Path(path)
    payload = content.encode("utf-8") if isinstance(content, str) else content
    if append:
        with path.with_name("." + path.name + ".lock").open("ab") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            previous = path.read_bytes() if path.exists() else b""
            publish(path, previous + payload)
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + ".",
                                     mode="wb", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.close()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
