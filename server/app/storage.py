"""File operations, all kept inside the files root."""

import hashlib
import heapq
import json
import mimetypes
import os
import shutil
import time
from pathlib import Path

TRASH_NAME = ".trash"


class PathError(ValueError):
    pass


def resolve(root: Path, rel: str) -> Path:
    """Turn a client path like 'Photos/a.jpg' into a safe absolute path."""
    rel = (rel or "").strip().strip("/")
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        raise PathError("Path is outside the drive")
    return target


def relpath(root: Path, p: Path) -> str:
    return "" if p == root else str(p.relative_to(root))


def entry(root: Path, p: Path) -> dict:
    st = p.stat()
    is_dir = p.is_dir()
    mime = None if is_dir else (mimetypes.guess_type(p.name)[0] or "application/octet-stream")
    return {
        "name": p.name,
        "path": relpath(root, p),
        "is_dir": is_dir,
        "size": 0 if is_dir else st.st_size,
        "modified": st.st_mtime,  # seconds since 1970 (UTC)
        "mime": mime,
    }


def list_dir(root: Path, rel: str, show_hidden: bool = False) -> list[dict]:
    d = resolve(root, rel)
    if not d.is_dir():
        raise FileNotFoundError(rel)
    items = []
    for child in d.iterdir():
        if not show_hidden and child.name.startswith("."):
            continue
        try:
            items.append(entry(root, child))
        except (FileNotFoundError, PermissionError):
            continue
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


def move(root: Path, src: str, dst: str) -> Path:
    s = resolve(root, src)
    d = resolve(root, dst)
    if s == root:
        raise PathError("Can't move the drive root")
    if not s.exists():
        raise FileNotFoundError(src)
    if d == s or s in d.parents:
        raise PathError("Can't move a folder into itself")
    if d.exists():
        raise FileExistsError(dst)
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    return d


INDEX_NAME = ".index.json"


def _trash_dir(root: Path) -> Path:
    d = root / TRASH_NAME
    d.mkdir(exist_ok=True)
    return d


def _load_index(root: Path) -> dict:
    f = _trash_dir(root) / INDEX_NAME
    try:
        return json.loads(f.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def _save_index(root: Path, index: dict) -> None:
    f = _trash_dir(root) / INDEX_NAME
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(index))
    tmp.replace(f)


def _remove(p: Path) -> None:
    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()


def trash(root: Path, rel: str) -> None:
    p = resolve(root, rel)
    if p == root:
        raise PathError("Can't delete the drive root")
    if not p.exists():
        raise FileNotFoundError(rel)
    trash_dir = _trash_dir(root)
    if trash_dir == p or trash_dir in p.parents:
        raise PathError("Use the Trash view to delete things for good")
    dest = unique_path(trash_dir / p.name)
    shutil.move(str(p), str(dest))
    index = _load_index(root)
    index[dest.name] = {"original": relpath(root, p), "deleted": time.time()}
    _save_index(root, index)


def list_trash(root: Path) -> list[dict]:
    trash_dir = _trash_dir(root)
    index = _load_index(root)
    items = []
    for child in trash_dir.iterdir():
        if child.name in (INDEX_NAME, INDEX_NAME.replace(".json", ".tmp")):
            continue
        info = index.get(child.name, {})
        e = entry(root, child)
        e["trash_name"] = child.name
        e["original"] = info.get("original", child.name)
        e["deleted"] = info.get("deleted", child.stat().st_mtime)
        items.append(e)
    items.sort(key=lambda e: e["deleted"], reverse=True)
    return items


def _trashed(root: Path, name: str) -> Path:
    name = safe_name(name)
    p = _trash_dir(root) / name
    if name == INDEX_NAME or not p.exists():
        raise FileNotFoundError(name)
    return p


def restore(root: Path, name: str) -> Path:
    p = _trashed(root, name)
    index = _load_index(root)
    original = index.get(p.name, {}).get("original", p.name)
    try:
        dest = resolve(root, original)
    except PathError:
        dest = root / p.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest = unique_path(dest)
    shutil.move(str(p), str(dest))
    index.pop(p.name, None)
    _save_index(root, index)
    return dest


def delete_forever(root: Path, name: str) -> None:
    p = _trashed(root, name)
    _remove(p)
    index = _load_index(root)
    index.pop(p.name, None)
    _save_index(root, index)


def empty_trash(root: Path) -> int:
    trash_dir = _trash_dir(root)
    count = 0
    for child in trash_dir.iterdir():
        if not child.name.startswith(".index"):
            count += 1
        _remove(child)
    return count


def walk(root: Path, include_dirs: bool = True):
    """Every file (and folder) in the drive, skipping hidden things and the trash."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        here = Path(dirpath)
        if include_dirs:
            for d in dirnames:
                yield here / d
        for f in filenames:
            if not f.startswith("."):
                yield here / f


def recent(root: Path, limit: int = 50) -> list[dict]:
    files = []
    for p in walk(root, include_dirs=False):
        try:
            files.append((p.stat().st_mtime, p))
        except OSError:
            continue
    newest = heapq.nlargest(limit, files, key=lambda t: t[0])
    return [entry(root, p) for _, p in newest]


def search(root: Path, query: str, limit: int = 200) -> list[dict]:
    q = query.strip().lower()
    if not q:
        return []
    results = []
    for p in walk(root):
        if q in p.name.lower():
            try:
                results.append(entry(root, p))
            except OSError:
                continue
            if len(results) >= limit:
                break
    results.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return results


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
