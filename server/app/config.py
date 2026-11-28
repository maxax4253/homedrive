"""Settings, read from environment variables."""

import os
import secrets
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Settings:
    files_root: Path
    data_dir: Path
    username: str
    password: str
    secret: str
    token_days: int = 30
    # Nightly backups: off unless a backup folder is mounted.
    backup_dir: Path | None = None
    backup_hour: int = 3
    run_scheduler: bool = True
    # Public address for share links, e.g. https://server.tailnet.ts.net (empty = links off).
    public_url: str = ""
    versions_to_keep: int = 10
    # Uploads stop when they'd leave less than this free on the server's disk.
    min_free_bytes: int = 2 * 1024 ** 3
    # Trash and old file versions are deleted for good after this many days (0 = keep forever).
    cleanup_days: int = 30


UPLOAD_TMP = ".upload-tmp"


def use_upload_tmp(files_root: Path) -> None:
    """Spool incoming uploads on the files drive instead of the container's /tmp.

    Otherwise a big upload is first written to the system disk (which may be much
    smaller than the files drive) and then copied again. Leftovers from a crash are
    cleared on startup.
    """
    if not os.access(files_root, os.W_OK):
        return  # read-only files (the share-link server): keep the default
    tmp = files_root / UPLOAD_TMP
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        tmp.mkdir(exist_ok=True)
    except OSError:
        return
    tempfile.tempdir = str(tmp)


def load_settings() -> Settings:
    files_root = Path(os.environ.get("HOMEDRIVE_FILES", "/files")).resolve()
    data_dir = Path(os.environ.get("HOMEDRIVE_DATA", "/data")).resolve()
    files_root.mkdir(parents=True, exist_ok=True)
    data_dir.mkdir(parents=True, exist_ok=True)
    use_upload_tmp(files_root)

    username = os.environ.get("HOMEDRIVE_USERNAME", "admin")
    password = os.environ.get("HOMEDRIVE_PASSWORD", "")
    if not password:
        raise RuntimeError("Set HOMEDRIVE_PASSWORD before starting HomeDrive.")

    # The signing secret survives restarts so logins stay valid.
    secret = os.environ.get("HOMEDRIVE_SECRET", "")
    if not secret:
        secret_file = data_dir / "secret.key"
        if secret_file.exists():
            secret = secret_file.read_text().strip()
        else:
            secret = secrets.token_hex(32)
            secret_file.write_text(secret)
            secret_file.chmod(0o600)

    backup = os.environ.get("HOMEDRIVE_BACKUP_DIR", "").strip()
    return Settings(
        files_root=files_root,
        data_dir=data_dir,
        username=username,
        password=password,
        secret=secret,
        token_days=int(os.environ.get("HOMEDRIVE_TOKEN_DAYS", "30")),
        backup_dir=Path(backup) if backup else None,
        backup_hour=int(os.environ.get("HOMEDRIVE_BACKUP_HOUR", "3")),
        public_url=os.environ.get("HOMEDRIVE_PUBLIC_URL", "").strip().rstrip("/"),
        min_free_bytes=int(float(os.environ.get("HOMEDRIVE_MIN_FREE_GB", "2")) * 1024 ** 3),
        cleanup_days=int(os.environ.get("HOMEDRIVE_CLEANUP_DAYS", "30")),
    )
