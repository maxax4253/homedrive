"""Settings, read from environment variables."""

import os
import secrets
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


def load_settings() -> Settings:
    files_root = Path(os.environ.get("HOMEDRIVE_FILES", "/files")).resolve()
    data_dir = Path(os.environ.get("HOMEDRIVE_DATA", "/data")).resolve()
    files_root.mkdir(parents=True, exist_ok=True)
    data_dir.mkdir(parents=True, exist_ok=True)

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

    return Settings(
        files_root=files_root,
        data_dir=data_dir,
        username=username,
        password=password,
        secret=secret,
        token_days=int(os.environ.get("HOMEDRIVE_TOKEN_DAYS", "30")),
    )
