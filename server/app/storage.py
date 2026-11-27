"""File operations, always confined to one user's space."""

import hashlib
import heapq
import json
import mimetypes
import os
import shutil
import time
from pathlib import Path

TRASH_NAME = ".trash"
SHARED_NAME = "Shared"
INDEX_NAME = ".index.json"


class PathError(ValueError):
    pass


class Space:
    """What one user can see.

    `home` is their own folder. `shared` is the everyone-can-see folder; for
    regular users it shows up as a "Shared" folder at the top of their drive.
    For the admin, home is the whole drive, so Shared is just a normal folder in it.
    """

    def __init__(self, home: Path, shared: Path | None = None):
        self.home = home.resolve()
        self.shared = shared.resolve() if shared else None
        # Only map "Shared/..." specially when the shared folder lives outside home.
        self._mapped = self.shared is not None and not _inside(self.shared, self.home)

    @property
    def trash_dir(self) -> Path:
        d = self.home / TRASH_NAME
        d.mkdir(parents=True, exist_ok=True)
        return d

    def resolve(self, rel: str) -> Path:
        """Turn a client path like 'Photos/a.jpg' into a safe absolute path."""
        rel = (rel or "").strip().strip("/")
        base, sub = self.home, rel
        if self._mapped:
            first, _, rest = rel.partition("/")
            if first == SHARED_NAME:
                base, sub = self.shared, rest
        target = (base / sub).resolve()
        if not _inside(target, base):
            raise PathError("Path is outside your drive")
        return target

    def rel(self, p: Path) -> str:
        if self._mapped and _inside(p, self.shared):
            tail = "" if p == self.shared else "/" + str(p.relative_to(self.shared))
            return SHARED_NAME + tail
        return "" if p == self.home else str(p.relative_to(self.home))

    def is_top(self, p: Path) -> bool:
        """The drive itself or the Shared folder: can't be moved, renamed or deleted."""
        return p == self.home or (self._mapped and p == self.shared)

    def roots(self) -> list[Path]:
        """Folders to walk for search/recent."""
        return [self.home] + ([self.shared] if self._mapped else [])


def _inside(p: Path, base: Path) -> bool:
    return p == base or base in p.parents


def entry(space: Space, p: Path) -> dict:
    st = p.stat()
    is_dir = p.is_dir()
    mime = None if is_dir else (mimetypes.guess_type(p.name)[0] or "application/octet-stream")
    return {
        "name": p.name,
        "path": space.rel(p),
        "is_dir": is_dir,
        "size": 0 if is_dir else st.st_size,
        "modified": st.st_mtime,  # seconds since 1970 (UTC)
        "mime": mime,
    }


def list_dir(space: Space, rel: str, show_hidden: bool = False) -> list[dict]:
    d = space.resolve(rel)
    if not d.is_dir():
        raise FileNotFoundError(rel)
    items = []
    for child in d.iterdir():
        if not show_hidden and child.name.startswith("."):
            continue
        try:
            items.append(entry(space, child))
        except (FileNotFoundError, PermissionError):
            continue
    if d == space.home and space._mapped and space.shared.is_dir():
        items.append(entry(space, space.shared))
    items.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return items


def unique_path(p: Path) -> Path:
    """'a.txt' -> 'a (1).txt' if a.txt already exists."""
    if not p.exists():
        return p
    stem, suffix = p.stem, p.suffix
    if p.is_dir():
        stem, suffix = p.name, ""
    n = 1
    while True:
        candidate = p.with_name(f"{stem} ({n}){suffix}")
        if not candidate.exists():
            return candidate
        n += 1


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    if name in ("", ".", ".."):
        raise PathError("Bad file name")
    return name


def move(space: Space, src: str, dst: str) -> Path:
    s = space.resolve(src)
    d = space.resolve(dst)
    if space.is_top(s):
        raise PathError("Can't move that folder")
    if not s.exists():
        raise FileNotFoundError(src)
    if d == s or s in d.parents:
        raise PathError("Can't move a folder into itself")
    if d.exists():
        raise FileExistsError(dst)
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    return d


# ---------------------------------------------------------------- trash

def _load_index(space: Space) -> dict:
    f = space.trash_dir / INDEX_NAME
    try:
        return json.loads(f.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _save_index(space: Space, index: dict) -> None:
    f = space.trash_dir / INDEX_NAME
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(index))
    tmp.replace(f)


def remove_path(p: Path) -> None:
    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()


def trash(space: Space, rel: str) -> None:
    p = space.resolve(rel)
    if space.is_top(p):
        raise PathError("Can't delete that folder")
    if not p.exists():
        raise FileNotFoundError(rel)
    trash_dir = space.trash_dir
    if _inside(p, trash_dir):
        raise PathError("Use the Trash view to delete things for good")
    original = space.rel(p)
    dest = unique_path(trash_dir / p.name)
    shutil.move(str(p), str(dest))
    index = _load_index(space)
    index[dest.name] = {"original": original, "deleted": time.time()}
    _save_index(space, index)


def list_trash(space: Space) -> list[dict]:
    trash_dir = space.trash_dir
    index = _load_index(space)
    items = []
    for child in trash_dir.iterdir():
        if child.name.startswith(".index"):
            continue
        info = index.get(child.name, {})
        e = entry(space, child)
        e["trash_name"] = child.name
        e["original"] = info.get("original", child.name)
        e["deleted"] = info.get("deleted", child.stat().st_mtime)
        items.append(e)
    items.sort(key=lambda e: e["deleted"], reverse=True)
    return items


def _trashed(space: Space, name: str) -> Path:
    name = safe_name(name)
    p = space.trash_dir / name
    if name.startswith(".index") or not p.exists():
        raise FileNotFoundError(name)
    return p


def restore(space: Space, name: str) -> Path:
    p = _trashed(space, name)
    index = _load_index(space)
    original = index.get(p.name, {}).get("original", p.name)
    try:
        dest = space.resolve(original)
    except PathError:
        dest = space.home / p.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest = unique_path(dest)
    shutil.move(str(p), str(dest))
    index.pop(p.name, None)
    _save_index(space, index)
    return dest


def delete_forever(space: Space, name: str) -> None:
    p = _trashed(space, name)
    remove_path(p)
    index = _load_index(space)
    index.pop(p.name, None)
    _save_index(space, index)


def empty_trash(space: Space) -> int:
    count = 0
    for child in space.trash_dir.iterdir():
        if not child.name.startswith(".index"):
            count += 1
        remove_path(child)
    return count


# ---------------------------------------------------------------- walking

def walk(space: Space, include_dirs: bool = True, skip_top: set[str] | None = None):
    """Every visible file (and folder), skipping hidden things and the trash."""
    for base in space.roots():
        for dirpath, dirnames, filenames in os.walk(base):
            here = Path(dirpath)
            dirnames[:] = [d for d in dirnames if not d.startswith(".")
                           and not (skip_top and here == space.home and d in skip_top)]
            if include_dirs:
                for d in dirnames:
                    yield here / d
            for f in filenames:
                if not f.startswith("."):
                    yield here / f


def recent(space: Space, limit: int = 50, skip_top: set[str] | None = None) -> list[dict]:
    files = []
    for p in walk(space, include_dirs=False, skip_top=skip_top):
        try:
            files.append((p.stat().st_mtime, p))
        except OSError:
            continue
    newest = heapq.nlargest(limit, files, key=lambda t: t[0])
    return [entry(space, p) for _, p in newest]


def search(space: Space, query: str, limit: int = 200, skip_top: set[str] | None = None) -> list[dict]:
    q = query.strip().lower()
    if not q:
        return []
    results = []
    for p in walk(space, skip_top=skip_top):
        if q in p.name.lower():
            try:
                results.append(entry(space, p))
            except OSError:
                continue
            if len(results) >= limit:
                break
    results.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return results


def tree(space: Space, rel: str) -> list[dict]:
    """All files under a folder (for offline copies). Paths are drive paths."""
    base = space.resolve(rel)
    if base.is_file():
        return [entry(space, base)]
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            if not f.startswith("."):
                try:
                    out.append(entry(space, Path(dirpath) / f))
                except OSError:
                    continue
    return out


def folder_size(p: Path) -> int:
    total = 0
    for dirpath, _, filenames in os.walk(p):
        for f in filenames:
            try:
                total += (Path(dirpath) / f).stat().st_size
            except OSError:
                continue
    return total


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(4 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def thumb_key(p: Path, size: int) -> str:
    st = p.stat()
    raw = f"{p}:{st.st_mtime_ns}:{st.st_size}:{size}"
    return hashlib.sha1(raw.encode()).hexdigest()
