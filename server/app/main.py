"""HomeDrive API server (Tailscale-only). Share-link pages live in public.py."""

import json
import os
import shutil
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

from fastapi import Depends, FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

from . import auth, storage
from .backups import Backups
from .config import Settings, load_settings
from .db import Database, User
from .extras import Stars, stream_zip
from .versions import VersionStore

__version__ = "0.7.0"

try:
    from PIL import Image, ImageOps

    try:
        from pillow_heif import register_heif_opener

        register_heif_opener()
    except ImportError:
        pass
    HAS_PIL = True
except ImportError:  # pragma: no cover
    HAS_PIL = False

THUMB_TYPES = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif"}
USERS_DIR = "Users"
GB = 1024 ** 3


class LoginBody(BaseModel):
    username: str
    password: str


class PathBody(BaseModel):
    path: str


class NameBody(BaseModel):
    name: str


class StarBody(BaseModel):
    path: str
    starred: bool = True


class MoveBody(BaseModel):
    src: str
    dst: str


class NewUserBody(BaseModel):
    username: str
    password: str
    quota_gb: float | None = None


class PasswordBody(BaseModel):
    password: str


class ChangePasswordBody(BaseModel):
    old_password: str
    new_password: str


class QuotaBody(BaseModel):
    quota_gb: float | None = None


class ShareBody(BaseModel):
    path: str
    expires_days: float | None = None
    password: str | None = None


class LinksBody(BaseModel):
    enabled: bool


class RestoreVersionBody(BaseModel):
    path: str
    version: str


def user_space(settings: Settings, username: str, is_admin: bool, create: bool = True) -> storage.Space:
    """Admin sees the whole drive. Everyone else gets Users/<name> plus Shared."""
    shared = settings.files_root / storage.SHARED_NAME
    home = settings.files_root if is_admin else settings.files_root / USERS_DIR / username
    if create:
        shared.mkdir(exist_ok=True)
        home.mkdir(parents=True, exist_ok=True)
    return storage.Space(home, shared)


@dataclass
class Session:
    user: User
    space: storage.Space
    stars: Stars


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    root = settings.files_root
    thumbs_dir = settings.data_dir / "thumbs"
    thumbs_dir.mkdir(parents=True, exist_ok=True)

    db = Database(settings.data_dir / "homedrive.db")
    db.ensure_admin(settings.username.strip().lower(), settings.password)
    versions = VersionStore(settings.data_dir, settings.versions_to_keep)
    backups = Backups(root, settings.backup_dir, settings.data_dir, settings.backup_hour)
    if settings.run_scheduler:
        backups.start_scheduler()

    app = FastAPI(title="HomeDrive", version=__version__)
    usage_cache: dict[str, tuple[float, int]] = {}
    usage_lock = threading.Lock()

    stars_cache: dict[str, Stars] = {}

    def stars_for(user: User) -> Stars:
        # One shared object per user, so its lock really serializes concurrent changes.
        # The admin keeps the original stars.json so existing stars survive the upgrade.
        with usage_lock:
            if user.username not in stars_cache:
                name = "stars.json" if user.is_admin else f"stars-{user.username}.json"
                stars_cache[user.username] = Stars(settings.data_dir, name)
            return stars_cache[user.username]

    def require(request: Request) -> Session:
        header = request.headers.get("authorization", "")
        token = header[7:] if header.lower().startswith("bearer ") else ""
        checked = auth.check_token(token, settings.secret) if token else None
        user = db.get_user(checked[0]) if checked else None
        if not user or user.token_version != checked[1]:
            raise HTTPException(401, "Not logged in")
        return Session(user, user_space(settings, user.username, user.is_admin), stars_for(user))

    def require_admin(s: Session = Depends(require)) -> Session:
        if not s.user.is_admin:
            raise HTTPException(403, "Only the admin can do that")
        return s

    def safe(s: Session, rel: str) -> Path:
        try:
            return s.space.resolve(rel)
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    def mark(s: Session, entries: list[dict]) -> list[dict]:
        for e in entries:
            e["starred"] = s.stars.is_starred(e["path"])
        return entries

    def usage(username: str, home: Path, fresh: bool = False) -> int:
        """Bytes in a user's home folder, cached for 30 seconds."""
        with usage_lock:
            cached = usage_cache.get(username)
        if cached and not fresh and time.time() - cached[0] < 30:
            return cached[1]
        used = storage.folder_size(home)
        with usage_lock:
            usage_cache[username] = (time.time(), used)
        return used

    def share_url(token: str) -> str | None:
        return f"{settings.public_url}/s/{token}" if settings.public_url else None

    # ------------------------------------------------------------ basics

    @app.get("/api/health")
    def health():
        return {"ok": True, "name": "HomeDrive", "version": app.version}

    @app.post("/api/login")
    def login(body: LoginBody):
        user = db.check_login(body.username.strip().lower(), body.password)
        if not user:
            raise HTTPException(401, "Wrong username or password")
        token = auth.make_token(user.username, user.token_version, settings.secret, settings.token_days)
        return {"token": token, "username": user.username, "is_admin": user.is_admin}

    @app.get("/api/me")
    def me(s: Session = Depends(require)):
        info = {
            "username": s.user.username,
            "is_admin": s.user.is_admin,
            "quota": s.user.quota_bytes,
            "links_enabled": bool(settings.public_url),
            "backups_enabled": backups.enabled,
        }
        # drive_used: how much your HomeDrive files take up (trash included).
        drive_used = usage(s.user.username, s.space.home)
        info["drive_used"] = drive_used
        if s.user.quota_bytes:
            # Your storage limit is the whole picture.
            info.update(total=s.user.quota_bytes, used=drive_used,
                        free=max(0, s.user.quota_bytes - drive_used), scope="quota")
        else:
            # No limit: show the server's whole disk, which also holds the OS and other apps.
            disk = shutil.disk_usage(root)
            info.update(total=disk.total, used=disk.used, free=disk.free, scope="disk")
        return info

    @app.post("/api/me/password")
    def change_my_password(body: ChangePasswordBody, s: Session = Depends(require)):
        if s.user.is_admin:
            raise HTTPException(400, "The admin password is set on the server: run 'homedrive password'.")
        if not db.check_login(s.user.username, body.old_password):
            raise HTTPException(401, "Your current password is wrong")
        try:
            db.set_password(s.user.username, body.new_password)
        except ValueError as e:
            raise HTTPException(400, str(e))
        user = db.get_user(s.user.username)
        return {"token": auth.make_token(user.username, user.token_version, settings.secret, settings.token_days)}

    # ------------------------------------------------------------ browsing

    @app.get("/api/list")
    def list_files(path: str = "", hidden: bool = False, s: Session = Depends(require)):
        safe(s, path)
        try:
            return {"path": path.strip("/"), "entries": mark(s, storage.list_dir(s.space, path, hidden))}
        except FileNotFoundError:
            raise HTTPException(404, "Folder not found")

    @app.get("/api/tree")
    def tree(path: str, s: Session = Depends(require)):
        """Every file under a folder (used to keep offline copies up to date)."""
        p = safe(s, path)
        if not p.exists():
            raise HTTPException(404, "Not found")
        return {"entries": storage.tree(s.space, path)}

    @app.get("/api/recent")
    def recent(limit: int = Query(50, ge=1, le=500), s: Session = Depends(require)):
        skip = {USERS_DIR} if s.user.is_admin else None
        return {"entries": mark(s, storage.recent(s.space, limit, skip))}

    @app.get("/api/search")
    def search(q: str, limit: int = Query(200, ge=1, le=1000), s: Session = Depends(require)):
        return {"entries": mark(s, storage.search(s.space, q, limit))}

    @app.get("/api/starred")
    def starred(s: Session = Depends(require)):
        entries = []
        for rel in s.stars.all():
            try:
                p = s.space.resolve(rel)
            except storage.PathError:
                continue
            if p.exists() and not s.space.is_top(p):
                entries.append(storage.entry(s.space, p))
        entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
        return {"entries": mark(s, entries)}

    @app.post("/api/star")
    def star(body: StarBody, s: Session = Depends(require)):
        p = safe(s, body.path)
        if not p.exists() or s.space.is_top(p):
            raise HTTPException(404, "Not found")
        s.stars.set(s.space.rel(p), body.starred)
        return {"path": s.space.rel(p), "starred": body.starred}

    # ------------------------------------------------------------ downloads

    @app.get("/api/download")
    def download(path: str, s: Session = Depends(require)):
        p = safe(s, path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        return FileResponse(p, filename=p.name)

    @app.get("/api/zip")
    def download_zip(path: list[str] = Query(...), s: Session = Depends(require)):
        """Zip one or more files/folders. Streams, so big folders start downloading right away."""
        items = []
        for rel in path:
            p = safe(s, rel)
            if p == s.space.home:
                raise HTTPException(400, "Can't zip the whole drive")
            if not p.exists():
                raise HTTPException(404, f"Not found: {rel}")
            items.append((p, p.name))
        name = f"{items[0][0].stem if items[0][0].is_file() else items[0][0].name}.zip" if len(items) == 1 \
            else "HomeDrive download.zip"
        headers = {"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"}
        return StreamingResponse(stream_zip(items), media_type="application/zip", headers=headers)

    @app.get("/api/thumbnail")
    def thumbnail(path: str, size: int = Query(256, ge=32, le=1024), s: Session = Depends(require)):
        p = safe(s, path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        if not HAS_PIL or p.suffix.lower() not in THUMB_TYPES:
            raise HTTPException(415, "No thumbnail for this file type")
        cached = thumbs_dir / f"{storage.thumb_key(p, size)}.jpg"
        if not cached.exists():
            try:
                with Image.open(p) as img:
                    img = ImageOps.exif_transpose(img)
                    img.thumbnail((size, size))
                    # Write then rename, so a second request never reads half a thumbnail.
                    tmp = cached.with_name(f".{cached.name}.{threading.get_ident()}")
                    img.convert("RGB").save(tmp, "JPEG", quality=82)
                    tmp.replace(cached)
            except Exception:
                raise HTTPException(415, "Couldn't make a thumbnail")
        return FileResponse(cached, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

    @app.get("/api/hash")
    def file_hash(path: str, s: Session = Depends(require)):
        p = safe(s, path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        return {"path": path, "size": p.stat().st_size, "sha256": storage.sha256(p)}

    # ------------------------------------------------------------ uploads & changes

    @app.post("/api/upload")
    def upload(request: Request, path: str = "", replace: bool = False, if_modified: float | None = None,
               files: list[UploadFile] = File(...), s: Session = Depends(require)):
        """Upload into a folder. With replace=true (one file), overwrite an existing file
        and keep the old copy in version history. if_modified guards against overwriting
        a file that changed on the server since you downloaded it (409)."""
        folder = safe(s, path)
        if not folder.is_dir():
            raise HTTPException(404, "Folder not found")
        if s.user.quota_bytes:
            incoming = int(request.headers.get("content-length") or 0)
            used = usage(s.user.username, s.space.home, fresh=True)
            if used + incoming > s.user.quota_bytes:
                raise HTTPException(413, f"Storage limit reached ({s.user.quota_bytes / GB:.1f} GB).")
        if replace and len(files) != 1:
            raise HTTPException(400, "Replace one file at a time")
        saved = []
        for f in files:
            try:
                name = storage.safe_name(f.filename or "")
            except storage.PathError as e:
                raise HTTPException(400, str(e))
            if replace:
                dest = folder / name
                if not dest.is_file():
                    raise HTTPException(404, "The file to replace isn't there anymore")
                if if_modified is not None and abs(dest.stat().st_mtime - if_modified) > 0.01:
                    raise HTTPException(409, "This file changed on the server since you opened it")
            else:
                dest = storage.unique_path(folder / name)
            # Write to a temp file first so a dropped upload never leaves half a file.
            tmp_path = None
            try:
                with tempfile.NamedTemporaryFile(dir=folder, prefix=".upload-", delete=False) as tmp:
                    tmp_path = Path(tmp.name)
                    shutil.copyfileobj(f.file, tmp, length=1024 * 1024)
                    tmp.flush()
                    os.fsync(tmp.fileno())
                tmp_path.chmod(0o644)
                if replace:
                    versions.save(dest)
                tmp_path.replace(dest)
            except BaseException:
                if tmp_path:
                    tmp_path.unlink(missing_ok=True)
                raise
            e = storage.entry(s.space, dest)
            # Fingerprint of what's actually on disk, so the app can confirm a
            # perfect copy before deleting anything from your Mac.
            e["sha256"] = storage.sha256(dest)
            saved.append(e)
        with usage_lock:
            usage_cache.pop(s.user.username, None)
        return {"saved": mark(s, saved)}

    @app.post("/api/mkdir")
    def mkdir(body: PathBody, s: Session = Depends(require)):
        p = safe(s, body.path)
        if p.exists():
            raise HTTPException(409, "Something with that name already exists")
        p.mkdir(parents=True)
        return storage.entry(s.space, p)

    @app.post("/api/move")
    def move(body: MoveBody, s: Session = Depends(require)):
        safe(s, body.src)
        safe(s, body.dst)
        try:
            moved = storage.move(s.space, body.src, body.dst)
            new = s.space.rel(moved)
            s.stars.moved(body.src.strip("/"), new)
            db.share_moved(s.user.username, body.src.strip("/"), new)
            return mark(s, [storage.entry(s.space, moved)])[0]
        except FileNotFoundError:
            raise HTTPException(404, "Not found")
        except FileExistsError:
            raise HTTPException(409, "Something with that name already exists")
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    # ------------------------------------------------------------ trash

    @app.post("/api/delete")
    def delete(body: PathBody, s: Session = Depends(require)):
        safe(s, body.path)
        try:
            storage.trash(s.space, body.path)
        except FileNotFoundError:
            raise HTTPException(404, "Not found")
        except storage.PathError as e:
            raise HTTPException(400, str(e))
        return Response(status_code=204)

    @app.get("/api/trash")
    def trash_list(s: Session = Depends(require)):
        return {"entries": storage.list_trash(s.space)}

    @app.post("/api/trash/restore")
    def trash_restore(body: NameBody, s: Session = Depends(require)):
        try:
            return mark(s, [storage.entry(s.space, storage.restore(s.space, body.name))])[0]
        except FileNotFoundError:
            raise HTTPException(404, "Not in the trash")
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    @app.post("/api/trash/delete")
    def trash_delete(body: NameBody, s: Session = Depends(require)):
        try:
            storage.delete_forever(s.space, body.name)
        except FileNotFoundError:
            raise HTTPException(404, "Not in the trash")
        except storage.PathError as e:
            raise HTTPException(400, str(e))
        return Response(status_code=204)

    @app.post("/api/trash/empty")
    def trash_empty(s: Session = Depends(require)):
        return {"deleted": storage.empty_trash(s.space)}

    # ------------------------------------------------------------ version history

    @app.get("/api/versions")
    def list_versions(path: str, s: Session = Depends(require)):
        p = safe(s, path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        st = p.stat()
        found = versions.list(p) + backups.versions(p)
        # Hide backup copies that are the same as what's there now (edit history is always real changes).
        found = [v for v in found if v["source"] == "edit"
                 or not (int(v["modified"]) == int(st.st_mtime) and v["size"] == st.st_size)]
        found.sort(key=lambda v: v["modified"], reverse=True)
        return {"current": {"modified": st.st_mtime, "size": st.st_size}, "versions": found}

    def version_file(p: Path, version: str) -> Path:
        source, _, vid = version.partition(":")
        found = versions.path(p, vid) if source == "edit" else backups.version_path(p, vid) if source == "backup" else None
        if not found:
            raise HTTPException(404, "That version isn't available")
        return found

    @app.get("/api/versions/download")
    def download_version(path: str, version: str, s: Session = Depends(require)):
        p = safe(s, path)
        return FileResponse(version_file(p, version), filename=p.name)

    @app.post("/api/versions/restore")
    def restore_version(body: RestoreVersionBody, s: Session = Depends(require)):
        """Put an older copy back. The current copy is kept in history, so this is undoable."""
        p = safe(s, body.path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        old = version_file(p, body.version)
        with tempfile.NamedTemporaryFile(dir=p.parent, prefix=".upload-", delete=False) as tmp:
            tmp_path = Path(tmp.name)
        try:
            # copyfile (not copy2): the restored file gets a new modified time, so it
            # shows in Recent and offline copies on Macs pick up the change.
            shutil.copyfile(old, tmp_path)
            tmp_path.chmod(0o644)
            versions.save(p)
            tmp_path.replace(p)
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise
        return mark(s, [storage.entry(s.space, p)])[0]

    # ------------------------------------------------------------ backups (admin)

    @app.get("/api/backups")
    def backup_status(s: Session = Depends(require_admin)):
        return backups.status()

    @app.post("/api/backups/run")
    def backup_now(s: Session = Depends(require_admin)):
        if not backups.enabled:
            raise HTTPException(400, "Backups are off. Set a backup folder with 'homedrive backup <folder>'.")
        if not backups.run_in_background():
            raise HTTPException(409, "A backup is already running")
        return {"started": True}

    # ------------------------------------------------------------ share links

    def share_json(sh, s: Session) -> dict:
        exists = True
        try:
            exists = s.space.resolve(sh.path).exists()
        except storage.PathError:
            exists = False
        return {
            "token": sh.token, "path": sh.path, "name": Path(sh.path).name, "is_dir": sh.is_dir,
            "created": sh.created, "expires": sh.expires, "has_password": sh.has_password,
            "downloads": sh.downloads, "active": sh.active and exists, "url": share_url(sh.token),
        }

    @app.post("/api/shares")
    def create_share(body: ShareBody, s: Session = Depends(require)):
        p = safe(s, body.path)
        if not p.exists() or s.space.is_top(p):
            raise HTTPException(404, "Not found")
        expires = time.time() + body.expires_days * 86400 if body.expires_days else None
        sh = db.add_share(s.user.username, s.space.rel(p), p.is_dir(), expires, body.password or None)
        return share_json(sh, s)

    @app.get("/api/shares")
    def my_shares(s: Session = Depends(require)):
        return {"links_enabled": bool(settings.public_url),
                "shares": [share_json(sh, s) for sh in db.list_shares(s.user.username)]}

    @app.delete("/api/shares/{token}")
    def revoke_share(token: str, s: Session = Depends(require)):
        if not db.revoke_share(token, s.user.username):
            raise HTTPException(404, "Link not found")
        return Response(status_code=204)

    # ------------------------------------------------------------ share links switch (admin)
    #
    # The API runs in a sealed container, so it can't run Tailscale or Docker itself.
    # Instead it drops a request file; a small helper on the server (a systemd path
    # unit installed by `homedrive install-agent`) runs `homedrive links on/off` and
    # writes its progress to status.json.

    agent_dir = settings.data_dir / "agent"

    def agent_status() -> dict:
        try:
            status = json.loads((agent_dir / "status.json").read_text())
        except (FileNotFoundError, ValueError):
            status = {}
        pending = (agent_dir / "request.json").exists()
        return {
            "enabled": bool(settings.public_url),
            "public_url": settings.public_url or None,
            "agent_installed": (agent_dir / "installed").exists(),
            "pending": pending,
            "state": "working" if pending else status.get("state", "idle"),
            "message": status.get("message"),
            "approve_url": status.get("approve_url"),
            "updated": status.get("updated"),
        }

    @app.get("/api/admin/links")
    def links_status(s: Session = Depends(require_admin)):
        return agent_status()

    def ask_agent(action: str) -> dict:
        if not (agent_dir / "installed").exists():
            raise HTTPException(409, "The server helper isn't installed yet. On the server, run: sudo homedrive install-agent")
        if (agent_dir / "request.json").exists():
            raise HTTPException(409, "The server is busy with another change. Try again in a minute.")
        agent_dir.mkdir(parents=True, exist_ok=True)
        tmp = agent_dir / "request.tmp"
        tmp.write_text(json.dumps({"action": action, "time": time.time()}))
        tmp.replace(agent_dir / "request.json")
        return agent_status()

    @app.post("/api/admin/links")
    def set_links(body: LinksBody, s: Session = Depends(require_admin)):
        return ask_agent("links-on" if body.enabled else "links-off")

    @app.post("/api/admin/update")
    def update_server(s: Session = Depends(require_admin)):
        """Pull the latest HomeDrive and rebuild. The server restarts partway through."""
        return ask_agent("update")

    # ------------------------------------------------------------ accounts (admin)

    def user_json(u: User) -> dict:
        home = user_space(settings, u.username, u.is_admin).home
        return {"username": u.username, "is_admin": u.is_admin, "quota": u.quota_bytes,
                "used": usage(u.username, home) if not u.is_admin else None}

    @app.get("/api/users")
    def list_users(s: Session = Depends(require_admin)):
        return {"users": [user_json(u) for u in db.list_users()]}

    @app.post("/api/users")
    def add_user(body: NewUserBody, s: Session = Depends(require_admin)):
        quota = int(body.quota_gb * GB) if body.quota_gb else None
        try:
            u = db.add_user(body.username.strip().lower(), body.password, quota_bytes=quota)
        except FileExistsError:
            raise HTTPException(409, "That username is taken")
        except ValueError as e:
            raise HTTPException(400, str(e))
        return user_json(u)

    @app.post("/api/users/{username}/password")
    def reset_password(username: str, body: PasswordBody, s: Session = Depends(require_admin)):
        u = db.get_user(username)
        if not u:
            raise HTTPException(404, "No such user")
        if u.is_admin:
            raise HTTPException(400, "Change the admin password on the server: run 'homedrive password'.")
        try:
            db.set_password(username, body.password)
        except ValueError as e:
            raise HTTPException(400, str(e))
        return Response(status_code=204)

    @app.post("/api/users/{username}/quota")
    def set_quota(username: str, body: QuotaBody, s: Session = Depends(require_admin)):
        u = db.get_user(username)
        if not u:
            raise HTTPException(404, "No such user")
        db.set_quota(username, int(body.quota_gb * GB) if body.quota_gb else None)
        return user_json(db.get_user(username))

    @app.delete("/api/users/{username}")
    def delete_user(username: str, s: Session = Depends(require_admin)):
        u = db.get_user(username)
        if not u:
            raise HTTPException(404, "No such user")
        if u.is_admin:
            raise HTTPException(400, "The admin account can't be deleted")
        db.delete_user(username)
        stars_cache.pop(username, None)
        # Their files stay in Users/<name> for the admin to keep or delete.
        return Response(status_code=204)

    app.state.db = db
    app.state.backups = backups
    app.state.versions = versions
    return app
