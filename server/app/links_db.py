"""Share links, kept in their own small database (data/links/links.db).

The public share-link server only ever sees this folder, never the main database
with everyone's accounts, the login secret or the admin password. So even if the
public server were broken into, there'd be no way to sign in to HomeDrive with
what it can read.
"""

import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from .db import hash_password

SCHEMA = """
CREATE TABLE IF NOT EXISTS shares (
    token          TEXT PRIMARY KEY,
    owner          TEXT NOT NULL,
    owner_is_admin INTEGER NOT NULL DEFAULT 0,
    path           TEXT NOT NULL,
    is_dir         INTEGER NOT NULL,
    created        REAL NOT NULL,
    expires        REAL,
    pw_hash        TEXT,
    downloads      INTEGER NOT NULL DEFAULT 0,
    revoked        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS shares_owner ON shares(owner);
CREATE TABLE IF NOT EXISTS downloads (
    token TEXT NOT NULL,
    time  REAL NOT NULL,
    ip    TEXT
);
CREATE INDEX IF NOT EXISTS downloads_token ON downloads(token, time);
CREATE TABLE IF NOT EXISTS failures (
    token TEXT NOT NULL,
    time  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS failures_token ON failures(token, time);
"""

LINK_FAILURES = 10        # wrong passwords for one link (from anyone)...
LINK_LOCK_SECONDS = 900   # ...within 15 minutes pause it for 15 minutes, then it reopens by itself

KEEP_DOWNLOAD_LOG = 200   # most recent downloads remembered per link


@dataclass
class Share:
    token: str
    owner: str
    owner_is_admin: bool
    path: str
    is_dir: bool
    created: float
    expires: float | None
    pw_hash: str | None
    downloads: int
    revoked: bool

    @property
    def has_password(self) -> bool:
        return self.pw_hash is not None

    @property
    def active(self) -> bool:
        return not self.revoked and (self.expires is None or self.expires > time.time())


class LinksDB:
    def __init__(self, folder: Path):
        folder.mkdir(parents=True, exist_ok=True)
        self.folder = folder
        self.conn = sqlite3.connect(str(folder / "links.db"), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.lock = threading.Lock()
        with self.lock:
            self.conn.executescript(SCHEMA)

    def _one(self, sql, *args):
        with self.lock:
            return self.conn.execute(sql, args).fetchone()

    def _all(self, sql, *args):
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def _run(self, sql, *args) -> int:
        with self.lock:
            return self.conn.execute(sql, args).rowcount

    @staticmethod
    def _share(row) -> Share | None:
        if row is None:
            return None
        return Share(row["token"], row["owner"], bool(row["owner_is_admin"]), row["path"], bool(row["is_dir"]),
                     row["created"], row["expires"], row["pw_hash"], row["downloads"], bool(row["revoked"]))

    # ------------------------------------------------------------ used by the main server

    def add(self, owner: str, owner_is_admin: bool, path: str, is_dir: bool,
            expires: float | None, password: str | None) -> Share:
        token = secrets.token_urlsafe(24)
        self._run(
            "INSERT INTO shares (token, owner, owner_is_admin, path, is_dir, created, expires, pw_hash) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            token, owner, int(owner_is_admin), path, int(is_dir), time.time(), expires,
            hash_password(password) if password else None,
        )
        return self.get(token)

    def list_for(self, owner: str) -> list[Share]:
        rows = self._all("SELECT * FROM shares WHERE owner = ? AND revoked = 0 ORDER BY created DESC", owner)
        return [self._share(r) for r in rows]

    def revoke(self, token: str, owner: str) -> bool:
        return self._run("UPDATE shares SET revoked = 1 WHERE token = ? AND owner = ?", token, owner) > 0

    def revoke_all_for(self, owner: str) -> None:
        self._run("UPDATE shares SET revoked = 1 WHERE owner = ?", owner)

    def moved(self, owner: str, old: str, new: str) -> None:
        """Keep links working when the shared file (or a folder above it) is renamed or moved."""
        for row in self._all("SELECT token, path FROM shares WHERE owner = ? AND revoked = 0", owner):
            p = row["path"]
            if p == old or p.startswith(old + "/"):
                self._run("UPDATE shares SET path = ? WHERE token = ?", new + p[len(old):], row["token"])

    def locked_until(self, token: str) -> float | None:
        """When a link paused after too many wrong passwords opens again (None = not paused)."""
        now = time.time()
        rows = self._all("SELECT time FROM failures WHERE token = ? AND time > ? ORDER BY time DESC LIMIT ?",
                         token, now - LINK_LOCK_SECONDS, LINK_FAILURES)
        if len(rows) < LINK_FAILURES:
            return None
        return rows[0]["time"] + LINK_LOCK_SECONDS   # 15 minutes after the latest wrong guess

    def record_failure(self, token: str) -> None:
        now = time.time()
        with self.lock:
            self.conn.execute("INSERT INTO failures (token, time) VALUES (?, ?)", (token, now))
            self.conn.execute("DELETE FROM failures WHERE time < ?", (now - 2 * LINK_LOCK_SECONDS,))

    def recent_downloads(self, token: str, limit: int = 20) -> list[dict]:
        rows = self._all("SELECT time, ip FROM downloads WHERE token = ? ORDER BY time DESC LIMIT ?", token, limit)
        return [{"time": r["time"], "ip": r["ip"]} for r in rows]

    def import_old(self, rows: list[dict]) -> int:
        """One-time move of links from the old main database. Skips ones already here."""
        n = 0
        for r in rows:
            n += self._run(
                "INSERT OR IGNORE INTO shares (token, owner, owner_is_admin, path, is_dir, created, expires, "
                "pw_hash, downloads, revoked) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                r["token"], r["owner"], int(r["owner_is_admin"]), r["path"], int(r["is_dir"]), r["created"],
                r["expires"], r["pw_hash"], r["downloads"], int(r["revoked"]),
            )
        return n

    # ------------------------------------------------------------ used by the public server

    def get(self, token: str) -> Share | None:
        return self._share(self._one("SELECT * FROM shares WHERE token = ?", token))

    def count_download(self, token: str, ip: str | None) -> None:
        now = time.time()
        with self.lock:
            self.conn.execute("UPDATE shares SET downloads = downloads + 1 WHERE token = ?", (token,))
            self.conn.execute("INSERT INTO downloads (token, time, ip) VALUES (?, ?, ?)", (token, now, ip))
            self.conn.execute(
                "DELETE FROM downloads WHERE token = ? AND time < (SELECT time FROM downloads WHERE token = ? "
                "ORDER BY time DESC LIMIT 1 OFFSET ?)", (token, token, KEEP_DOWNLOAD_LOG - 1))


def signing_key(folder: Path) -> str:
    """Secret used only to sign "password was entered" unlock codes on share pages."""
    f = folder / "links.key"
    if f.exists():
        return f.read_text().strip()
    key = secrets.token_hex(32)
    f.write_text(key)
    f.chmod(0o600)
    return key
