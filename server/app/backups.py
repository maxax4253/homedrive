"""Nightly backups as hard-linked snapshots (like Time Machine).

Each night rsync copies the drive into backup/snapshots/<date>. Files that didn't
change are hard links to the previous night's copy, so they take no extra space;
every snapshot still looks like a complete copy you can browse or restore from.
"""

import json
import shutil
import subprocess
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

STAMP = "%Y-%m-%d_%H%M%S"


class Backups:
    def __init__(self, files_root: Path, backup_dir: Path | None, data_dir: Path, hour: int = 3):
        self.files_root = files_root
        self.backup_dir = backup_dir
        self.status_file = data_dir / "backup-status.json"
        self.hour = hour
        self.lock = threading.Lock()
        self.running = False

    @property
    def enabled(self) -> bool:
        return self.backup_dir is not None and self.backup_dir.is_dir()

    @property
    def snapshots_dir(self) -> Path:
        return self.backup_dir / "snapshots"

    # ------------------------------------------------------------ status

    def _read_status(self) -> dict:
        try:
            return json.loads(self.status_file.read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def _write_status(self, **changes) -> None:
        status = self._read_status()
        status.update(changes)
        tmp = self.status_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(status))
        tmp.replace(self.status_file)

    def snapshots(self) -> list[str]:
        if not self.enabled or not self.snapshots_dir.is_dir():
            return []
        names = [p.name for p in self.snapshots_dir.iterdir() if p.is_dir() and not p.name.endswith(".partial")]
        return sorted(names, reverse=True)

    def status(self) -> dict:
        s = self._read_status()
        free = total = None
        if self.enabled:
            usage = shutil.disk_usage(self.backup_dir)
            free, total = usage.free, usage.total
        return {
            "enabled": self.enabled,
            "running": self.running,
            "hour": self.hour,
            "last_run": s.get("last_run"),
            "last_success": s.get("last_success"),
            "last_error": s.get("last_error"),
            "last_duration": s.get("last_duration"),
            "snapshots": self.snapshots(),
            "free": free,
            "total": total,
        }

    # ------------------------------------------------------------ running

    def run(self) -> bool:
        """Take one snapshot now. Returns False if one is already running or backups are off."""
        if not self.enabled:
            return False
        with self.lock:
            if self.running:
                return False
            self.running = True
        started = time.time()
        try:
            self.snapshots_dir.mkdir(parents=True, exist_ok=True)
            name = datetime.now().strftime(STAMP)
            partial = self.snapshots_dir / f"{name}.partial"
            if partial.exists():
                shutil.rmtree(partial)
            # Skip half-finished uploads and every Trash (yours and other people's).
            cmd = ["rsync", "-a", "--delete", "--exclude=.upload-*", "--exclude=.trash/"]
            previous = self.snapshots()
            if previous:
                cmd.append(f"--link-dest={self.snapshots_dir / previous[0]}")
            cmd += [f"{self.files_root}/", f"{partial}/"]
            result = subprocess.run(cmd, capture_output=True, text=True)
            # rsync exit 24 = some files vanished while copying; the snapshot is still good.
            if result.returncode not in (0, 24):
                raise RuntimeError((result.stderr or "rsync failed").strip().splitlines()[-1])
            partial.rename(self.snapshots_dir / name)
            self.prune()
            self._write_status(last_run=started, last_success=time.time(), last_error=None,
                               last_duration=time.time() - started)
            return True
        except Exception as e:
            self._write_status(last_run=started, last_error=str(e), last_duration=time.time() - started)
            return False
        finally:
            self.running = False

    def run_in_background(self) -> bool:
        if not self.enabled or self.running:
            return False
        threading.Thread(target=self.run, daemon=True).start()
        return True

    def prune(self, now: datetime | None = None) -> list[str]:
        """Keep every snapshot from the last 7 days, one per week for 4 weeks,
        and one per month for 6 months. Returns the names it deleted."""
        now = now or datetime.now()
        keep: set[str] = set()
        weeks: set[tuple] = set()
        months: set[tuple] = set()
        for name in self.snapshots():  # newest first
            try:
                when = datetime.strptime(name, STAMP)
            except ValueError:
                keep.add(name)  # not ours, leave it alone
                continue
            age = now - when
            if age <= timedelta(days=7):
                keep.add(name)
            elif age <= timedelta(weeks=5) and when.isocalendar()[:2] not in weeks:
                weeks.add(when.isocalendar()[:2])
                keep.add(name)
            elif age <= timedelta(days=186) and (when.year, when.month) not in months:
                months.add((when.year, when.month))
                keep.add(name)
        deleted = [n for n in self.snapshots() if n not in keep]
        for name in deleted:
            shutil.rmtree(self.snapshots_dir / name, ignore_errors=True)
        return deleted

    def start_scheduler(self) -> None:
        """Check once a minute; take a snapshot once a day at the backup hour."""
        def loop():
            while True:
                time.sleep(60)
                try:
                    if not self.enabled or self.running:
                        continue
                    now = datetime.now()
                    if now.hour != self.hour:
                        continue
                    today = now.strftime("%Y-%m-%d")
                    if any(s.startswith(today) for s in self.snapshots()):
                        continue
                    self.run()
                except Exception:
                    continue
        threading.Thread(target=loop, daemon=True).start()

    # ------------------------------------------------------------ versions from backups

    def versions(self, physical: Path) -> list[dict]:
        """Distinct older copies of one file found in the snapshots."""
        if not self.enabled:
            return []
        try:
            rel = physical.relative_to(self.files_root)
        except ValueError:
            return []
        seen = set()
        out = []
        for name in self.snapshots():
            p = self.snapshots_dir / name / rel
            if not p.is_file():
                continue
            st = p.stat()
            key = (int(st.st_mtime), st.st_size)
            if key in seen:
                continue
            seen.add(key)
            when = datetime.strptime(name, STAMP).timestamp() if _is_stamp(name) else st.st_mtime
            out.append({"id": f"backup:{name}", "source": "backup", "modified": st.st_mtime,
                        "size": st.st_size, "saved": when})
        return out

    def version_path(self, physical: Path, snapshot: str) -> Path | None:
        if not self.enabled or "/" in snapshot or snapshot not in self.snapshots():
            return None
        try:
            rel = physical.relative_to(self.files_root)
        except ValueError:
            return None
        p = self.snapshots_dir / snapshot / rel
        return p if p.is_file() else None


def _is_stamp(name: str) -> bool:
    try:
        datetime.strptime(name, STAMP)
        return True
    except ValueError:
        return False
