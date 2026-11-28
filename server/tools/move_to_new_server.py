#!/usr/bin/env python3
"""Copy the old (Docker) HomeDrive server's data into the new server's format.

    python3 move_to_new_server.py OLD_DATA NEW_DATA FILES_DIR ADMIN_NAME

Copies (never moves or changes the old data, so switching back is instant):
  - accounts, with the same passwords (same password format)
  - share links: same addresses, passwords, expiry, download counts and log
  - the share-link key and login secret (so codes and signatures stay valid)
  - stars
  - old file versions (the old server filed them under the path inside Docker,
    /files/<path>; the new one under <path>)
Your files themselves stay where they are: both servers use the same folder.

Only the Python standard library is used, so it runs on any Linux with Python 3.
"""

import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time
from pathlib import Path

KEEP_DOWNLOAD_LOG = 200
FAILURE_WINDOW = 15 * 60
DOCKER_FILES = os.environ.get("HD_OLD_FILES_PATH", "/files")  # where the old server saw the files folder


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def copy_private(src: Path, dst: Path) -> bool:
    if not src.is_file():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    os.chmod(dst, 0o600)
    return True


def read_db(path: Path, sql: str, *args) -> list[dict]:
    if not path.is_file():
        return []
    # Read-only, so nothing in the old database can change.
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(sql, args)]
    except sqlite3.OperationalError:
        return []  # table not there (older install)
    finally:
        con.close()


def move_users(old: Path, new: Path) -> int:
    users = {}
    for r in read_db(old / "homedrive.db", "SELECT * FROM users"):
        users[r["username"]] = {
            "username": r["username"],
            "pw_hash": r["pw_hash"],
            "is_admin": bool(r["is_admin"]),
            "quota_bytes": r.get("quota_bytes"),
            "token_version": r.get("token_version") or 1,
            "created": r.get("created") or time.time(),
        }
    write_json(new / "users.json", users)
    return len(users)


def move_links(old: Path, new: Path) -> int:
    db = old / "links" / "links.db"
    shares = {}
    for r in read_db(db, "SELECT * FROM shares"):
        log = read_db(db, "SELECT time, ip FROM downloads WHERE token = ? ORDER BY time DESC LIMIT ?",
                      r["token"], KEEP_DOWNLOAD_LOG)
        fails = read_db(db, "SELECT time FROM failures WHERE token = ? AND time > ? ORDER BY time",
                        r["token"], time.time() - FAILURE_WINDOW)
        s = {
            "token": r["token"],
            "owner": r["owner"],
            "owner_is_admin": bool(r.get("owner_is_admin")),
            "path": r["path"],
            "is_dir": bool(r["is_dir"]),
            "created": r["created"],
            "expires": r.get("expires"),
            "pw_hash": r.get("pw_hash"),
            "downloads": r.get("downloads") or 0,
            "revoked": bool(r.get("revoked")),
        }
        if log:
            s["log"] = [{"time": d["time"], "ip": d["ip"] or ""} for d in reversed(log)]
        if fails:
            s["failures"] = [f["time"] for f in fails]
        shares[r["token"]] = s
    write_json(new / "links" / "links.json", shares)
    copy_private(old / "links" / "links.key", new / "links" / "links.key")
    return len(shares)


def move_versions(old: Path, new: Path, files: Path) -> int:
    old_root, new_root = old / "versions", new / "versions"
    if not old_root.is_dir():
        return 0
    moved = 0
    for dirpath, dirnames, filenames in os.walk(files):
        dirnames[:] = [d for d in dirnames if d not in (".upload-tmp",)]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), files).replace(os.sep, "/")
            src = old_root / hashlib.sha1(f"{DOCKER_FILES}/{rel}".encode()).hexdigest()
            if not src.is_dir():
                continue
            dst = new_root / hashlib.sha1(rel.encode()).hexdigest()
            if dst.exists():
                continue
            shutil.copytree(src, dst)
            moved += 1
    return moved


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    old, new, files, admin = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
    if not (old / "homedrive.db").is_file():
        print(f"No old HomeDrive data in {old}")
        return 1
    if not files.is_dir():
        print(f"The files folder {files} isn't there")
        return 1
    if (new / "users.json").exists():
        print(f"{new} already has HomeDrive data; not copying over it.")
        return 1
    new.mkdir(parents=True, exist_ok=True)
    os.chmod(new, 0o700)

    users = move_users(old, new)
    links = move_links(old, new)
    copy_private(old / "secret.key", new / "secret.key")
    stars = 0
    for f in old.glob("stars*.json"):
        stars += copy_private(f, new / f.name)
    versions = move_versions(old, new, files)
    # The new server's own settings: same folder and admin, Tailscale built in.
    write_json(new / "app.json", {"files_root": str(files.resolve()), "username": admin, "tailscale": True,
                                  "tailscale_name": "homedrive", "funnel": True})
    print(f"Copied {users} accounts, {links} share links, {stars} star lists and history for {versions} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
