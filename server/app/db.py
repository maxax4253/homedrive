"""SQLite database: user accounts and share links."""

import hashlib
import hmac
import re
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,31}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    username      TEXT PRIMARY KEY,
    pw_hash       TEXT NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
    quota_bytes   INTEGER,
    token_version INTEGER NOT NULL DEFAULT 1,
    created       REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS shares (
    token      TEXT PRIMARY KEY,
    owner      TEXT NOT NULL,
    path       TEXT NOT NULL,
    is_dir     INTEGER NOT NULL,
    created    REAL NOT NULL,
    expires    REAL,
    pw_hash    TEXT,
    downloads  INTEGER NOT NULL DEFAULT 0,
    revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS shares_owner ON shares(owner);
"""


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return f"scrypt${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, salt_hex, digest_hex = stored.split("$")
    except ValueError:
        return False
    if scheme != "scrypt":
        return False
    digest = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt_hex), n=2**14, r=8, p=1, dklen=32)
    return hmac.compare_digest(digest.hex(), digest_hex)


@dataclass
class User:
    username: str
    is_admin: bool
    quota_bytes: int | None
    token_version: int


@dataclass
class Share:
    token: str
    owner: str
    path: str
    is_dir: bool
    created: float
    expires: float | None
    has_password: bool
    pw_hash: str | None
    downloads: int
    revoked: bool

    @property
    def active(self) -> bool:
        return not self.revoked and (self.expires is None or self.expires > time.time())


class Database:
    def __init__(self, path: Path):
        self.conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.lock = threading.Lock()
        with self.lock:
            self.conn.executescript(SCHEMA)

    def _one(self, sql: str, *args):
        with self.lock:
            return self.conn.execute(sql, args).fetchone()

    def _all(self, sql: str, *args):
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def _run(self, sql: str, *args) -> int:
        with self.lock:
            return self.conn.execute(sql, args).rowcount

    # ------------------------------------------------------------ users

    @staticmethod
    def _user(row) -> User | None:
        if row is None:
            return None
        return User(row["username"], bool(row["is_admin"]), row["quota_bytes"], row["token_version"])

    def get_user(self, username: str) -> User | None:
        return self._user(self._one("SELECT * FROM users WHERE username = ?", username))

    def list_users(self) -> list[User]:
        return [self._user(r) for r in self._all("SELECT * FROM users ORDER BY is_admin DESC, username")]

    def check_login(self, username: str, password: str) -> User | None:
        row = self._one("SELECT * FROM users WHERE username = ?", username)
        if row is None:
            # Spend the same time as a real check so usernames can't be probed by timing.
            verify_password(password, hash_password("x"))
            return None
        return self._user(row) if verify_password(password, row["pw_hash"]) else None

    def add_user(self, username: str, password: str, is_admin: bool = False, quota_bytes: int | None = None) -> User:
        if not USERNAME_RE.match(username):
            raise ValueError("Usernames are lowercase letters, numbers, dots, dashes or underscores (max 32).")
        if not password:
            raise ValueError("Password can't be empty.")
        if self.get_user(username):
            raise FileExistsError(username)
        self._run(
            "INSERT INTO users (username, pw_hash, is_admin, quota_bytes, created) VALUES (?, ?, ?, ?, ?)",
            username, hash_password(password), int(is_admin), quota_bytes, time.time(),
        )
        return self.get_user(username)

    def set_password(self, username: str, password: str) -> None:
        """Also signs that user out everywhere (old tokens stop working)."""
        if not password:
            raise ValueError("Password can't be empty.")
        self._run(
            "UPDATE users SET pw_hash = ?, token_version = token_version + 1 WHERE username = ?",
            hash_password(password), username,
        )

    def set_quota(self, username: str, quota_bytes: int | None) -> None:
        self._run("UPDATE users SET quota_bytes = ? WHERE username = ?", quota_bytes, username)

    def delete_user(self, username: str) -> None:
        self._run("DELETE FROM users WHERE username = ?", username)
        self._run("UPDATE shares SET revoked = 1 WHERE owner = ?", username)

    def ensure_admin(self, username: str, password: str) -> None:
        """The admin comes from the server's .env; keep the DB in step with it."""
        row = self._one("SELECT * FROM users WHERE username = ?", username)
        if row is None:
            self._run(
                "INSERT INTO users (username, pw_hash, is_admin, created) VALUES (?, ?, 1, ?)",
                username, hash_password(password), time.time(),
            )
        elif not verify_password(password, row["pw_hash"]) or not row["is_admin"]:
            self._run(
                "UPDATE users SET pw_hash = ?, is_admin = 1, token_version = token_version + 1 WHERE username = ?",
                hash_password(password), username,
            )

    # ------------------------------------------------------------ shares

    @staticmethod
    def _share(row) -> Share | None:
        if row is None:
            return None
        return Share(row["token"], row["owner"], row["path"], bool(row["is_dir"]), row["created"],
                     row["expires"], row["pw_hash"] is not None, row["pw_hash"], row["downloads"],
                     bool(row["revoked"]))

    def add_share(self, owner: str, path: str, is_dir: bool, expires: float | None, password: str | None) -> Share:
        token = secrets.token_urlsafe(24)
        pw = hash_password(password) if password else None
        self._run(
            "INSERT INTO shares (token, owner, path, is_dir, created, expires, pw_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
            token, owner, path, int(is_dir), time.time(), expires, pw,
        )
        return self.get_share(token)

    def get_share(self, token: str) -> Share | None:
        return self._share(self._one("SELECT * FROM shares WHERE token = ?", token))

    def list_shares(self, owner: str) -> list[Share]:
        rows = self._all("SELECT * FROM shares WHERE owner = ? AND revoked = 0 ORDER BY created DESC", owner)
        return [self._share(r) for r in rows]

    def revoke_share(self, token: str, owner: str) -> bool:
        return self._run("UPDATE shares SET revoked = 1 WHERE token = ? AND owner = ?", token, owner) > 0

    def count_download(self, token: str) -> None:
        self._run("UPDATE shares SET downloads = downloads + 1 WHERE token = ?", token)

    def share_moved(self, owner: str, old: str, new: str) -> None:
        """Keep links working when the shared file (or a folder above it) is renamed or moved."""
        for row in self._all("SELECT token, path FROM shares WHERE owner = ? AND revoked = 0", owner):
            p = row["path"]
            if p == old or p.startswith(old + "/"):
                self._run("UPDATE shares SET path = ? WHERE token = ?", new + p[len(old):], row["token"])
