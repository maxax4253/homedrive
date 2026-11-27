"""File operations, all kept inside the files root."""

import hashlib
import mimetypes
import shutil
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


def trash(root: Path, rel: str) -> None:
    p = resolve(root, rel)
    if p == root:
        raise PathError("Can't delete the drive root")
    if not p.exists():
        raise FileNotFoundError(rel)
    trash_dir = root / TRASH_NAME
    trash_dir.mkdir(exist_ok=True)
    if trash_dir == p or trash_dir in p.parents:
        # Already in the trash: delete for real.
        shutil.rmtree(p) if p.is_dir() else p.unlink()
        return
    shutil.move(str(p), str(unique_path(trash_dir / p.name)))


def thumb_key(p: Path, size: int) -> str:
    st = p.stat()
    raw = f"{p}:{st.st_mtime_ns}:{st.st_size}:{size}"
    return hashlib.sha1(raw.encode()).hexdigest()
