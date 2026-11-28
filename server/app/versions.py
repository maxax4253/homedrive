"""Older copies of files: from edits (saved when a file is replaced) and from backups."""

import hashlib
import json
import shutil
import time
from pathlib import Path


class VersionStore:
    """Keeps the previous copy each time a file is overwritten (edit and save back)."""

    def __init__(self, data_dir: Path, keep: int = 10):
        self.root = data_dir / "versions"
        self.root.mkdir(parents=True, exist_ok=True)
        self.keep = keep

    def _dir(self, physical: Path) -> Path:
        return self.root / hashlib.sha1(str(physical).encode()).hexdigest()

    def save(self, physical: Path) -> None:
        """Copy the current file into history before it gets replaced."""
        if not physical.is_file():
            return
        d = self._dir(physical)
        d.mkdir(parents=True, exist_ok=True)
        st = physical.stat()
        version_id = f"{time.time():.6f}"
        shutil.copy2(physical, d / version_id)
        meta = self._meta(d)
        meta[version_id] = {"modified": st.st_mtime, "size": st.st_size, "saved": time.time()}
        # Trim to the newest `keep` versions.
        for old in sorted(meta, key=lambda k: meta[k]["saved"])[:-self.keep]:
            (d / old).unlink(missing_ok=True)
            meta.pop(old)
        (d / "meta.json").write_text(json.dumps(meta))

    def _meta(self, d: Path) -> dict:
        try:
            return json.loads((d / "meta.json").read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def purge_older_than(self, days: float) -> int:
        """Drop saved copies older than `days` (and folders left empty)."""
        if days <= 0:
            return 0
        cutoff = time.time() - days * 86400
        removed = 0
        for d in self.root.iterdir():
            if not d.is_dir():
                continue
            meta = self._meta(d)
            old = [vid for vid, m in meta.items() if m.get("saved", 0) < cutoff]
            for vid in old:
                (d / vid).unlink(missing_ok=True)
                meta.pop(vid)
                removed += 1
            if not meta:
                shutil.rmtree(d, ignore_errors=True)
            elif old:
                (d / "meta.json").write_text(json.dumps(meta))
        return removed

    def list(self, physical: Path) -> list[dict]:
        d = self._dir(physical)
        meta = self._meta(d)
        return [
            {"id": f"edit:{vid}", "source": "edit", "modified": m["modified"], "size": m["size"], "saved": m["saved"]}
            for vid, m in meta.items() if (d / vid).exists()
        ]

    def path(self, physical: Path, version_id: str) -> Path | None:
        if "/" in version_id or version_id.startswith("."):
            return None
        p = self._dir(physical) / version_id
        return p if p.is_file() and version_id != "meta.json" else None
