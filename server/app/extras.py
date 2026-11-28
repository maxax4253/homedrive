"""Starred items and streaming zip downloads."""

import json
import os
import threading
import time
from collections import defaultdict, deque
import zipfile
from pathlib import Path
from typing import Iterator


class Limiter:
    """Counts recent events per key (an address, an account) in a sliding window."""

    def __init__(self, forget_after: float = 3600):
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()
        self.forget_after = forget_after

    def allow(self, key: str, limit: int, window: float, record: bool = True) -> bool:
        now = time.time()
        with self.lock:
            if len(self.hits) > 20000:
                # Forget visitors with nothing recent, so memory can't grow forever.
                for k in [k for k, q in self.hits.items() if not q or q[-1] < now - self.forget_after]:
                    del self.hits[k]
            q = self.hits[key]
            while q and q[0] < now - window:
                q.popleft()
            if len(q) >= limit:
                return False
            if record:
                q.append(now)
            return True

    def clear(self, key: str) -> None:
        with self.lock:
            self.hits.pop(key, None)

    def record(self, key: str) -> None:
        with self.lock:
            self.hits[key].append(time.time())



class Stars:
    """Starred paths, saved as a JSON list in the data folder."""

    def __init__(self, data_dir: Path, filename: str = "stars.json"):
        self.file = data_dir / filename
        self.lock = threading.Lock()
        try:
            self.paths: set[str] = set(json.loads(self.file.read_text()))
        except (FileNotFoundError, ValueError):
            self.paths = set()

    def _save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps(sorted(self.paths)))
        tmp.replace(self.file)

    def is_starred(self, path: str) -> bool:
        return path in self.paths

    def set(self, path: str, starred: bool) -> None:
        with self.lock:
            if starred:
                self.paths.add(path)
            else:
                self.paths.discard(path)
            self._save()

    def moved(self, old: str, new: str) -> None:
        """Keep stars attached when something (or a folder above it) is renamed or moved."""
        with self.lock:
            changed = False
            for p in list(self.paths):
                if p == old or p.startswith(old + "/"):
                    self.paths.discard(p)
                    self.paths.add(new + p[len(old):])
                    changed = True
            if changed:
                self._save()

    def all(self) -> list[str]:
        return sorted(self.paths)


def visible_files(folder: Path) -> Iterator[Path]:
    """Every regular file under a folder, skipping hidden things and symlinks
    (a symlink could point outside the drive)."""
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            f = Path(dirpath) / name
            if not name.startswith(".") and not f.is_symlink() and f.is_file():
                yield f


class _Sink:
    """File-like object that collects what ZipFile writes so we can stream it out."""

    def __init__(self):
        self.chunks: list[bytes] = []
        self.pos = 0

    def write(self, b) -> int:
        self.chunks.append(bytes(b))
        self.pos += len(b)
        return len(b)

    def tell(self) -> int:
        return self.pos

    def flush(self) -> None:
        pass

    def take(self) -> bytes:
        data = b"".join(self.chunks)
        self.chunks = []
        return data


def stream_zip(items: list[tuple[Path, str]]) -> Iterator[bytes]:
    """Yield a zip of the given (absolute path, name inside zip) items, folders included.

    Files are stored uncompressed: it's fast and most big files (photos, video) are
    already compressed. Memory use stays at about one chunk.
    """
    sink = _Sink()
    with zipfile.ZipFile(sink, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
        for path, arcname in items:
            if path.is_dir():
                empty = True
                for f in visible_files(path):
                    empty = False
                    yield from _add_file(zf, sink, f, f"{arcname}/{f.relative_to(path).as_posix()}")
                if empty:
                    zf.writestr(arcname.rstrip("/") + "/", b"")
            elif path.is_file():
                yield from _add_file(zf, sink, path, arcname)
    tail = sink.take()
    if tail:
        yield tail


def _add_file(zf: zipfile.ZipFile, sink: _Sink, path: Path, arcname: str) -> Iterator[bytes]:
    info = zipfile.ZipInfo.from_file(path, arcname)
    info.compress_type = zipfile.ZIP_STORED
    with path.open("rb") as src, zf.open(info, "w", force_zip64=True) as dst:
        while chunk := src.read(1024 * 1024):
            dst.write(chunk)
            data = sink.take()
            if data:
                yield data
    data = sink.take()
    if data:
        yield data
