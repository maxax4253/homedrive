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
MIN_PASSWORD = 8


def check_new_password(password: str) -> None:
    if len(password) < MIN_PASSWORD:
        raise ValueError(f"Passwords need at least {MIN_PASSWORD} characters.")

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
        check_new_password(password)
        if self.get_user(username):
            raise FileExistsError(username)
        self._run(
            "INSERT INTO users (username, pw_hash, is_admin, quota_bytes, created) VALUES (?, ?, ?, ?, ?)",
            username, hash_password(password), int(is_admin), quota_bytes, time.time(),
        )
        return self.get_user(username)

    def set_password(self, username: str, password: str) -> None:
        """Also signs that user out everywhere (old tokens stop working)."""
        check_new_password(password)
        self._run(
            "UPDATE users SET pw_hash = ?, token_version = token_version + 1 WHERE username = ?",
            hash_password(password), username,
        )

    def set_quota(self, username: str, quota_bytes: int | None) -> None:
        self._run("UPDATE users SET quota_bytes = ? WHERE username = ?", quota_bytes, username)

    def delete_user(self, username: str) -> None:
        self._run("DELETE FROM users WHERE username = ?", username)

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

    # ------------------------------------------------------------ old share links

    def take_old_shares(self) -> list[dict]:
        """Share links from before they moved to their own database (links.db).
        Returns them and removes them from here, so this only happens once."""
        rows = self._all(
            "SELECT s.*, COALESCE(u.is_admin, 0) AS owner_is_admin FROM shares s "
            "LEFT JOIN users u ON u.username = s.owner")
        return [dict(r) for r in rows]

    def forget_old_shares(self) -> None:
        self._run("DELETE FROM shares")
