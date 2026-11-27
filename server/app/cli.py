"""Small commands run inside the container by the `homedrive` script."""

import json
import sys

from .backups import Backups
from .config import load_settings


def main() -> None:
    s = load_settings()
    backups = Backups(s.files_root, s.backup_dir, s.data_dir, s.backup_hour)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "backup-now":
        if not backups.enabled:
            print("Backups are off. Turn them on with: homedrive backup <folder>")
            sys.exit(1)
        print("Backing up... (big drives take a while the first time)")
        ok = backups.run()
        status = backups.status()
        print("Done." if ok else f"Failed: {status['last_error']}")
        sys.exit(0 if ok else 1)
    elif cmd == "backup-status":
        print(json.dumps(backups.status(), indent=2))
    else:
        print("usage: python -m app.cli backup-now | backup-status")
        sys.exit(2)


if __name__ == "__main__":
    main()
