"""HomeDrive API server."""

import os
import shutil
import tempfile
from pathlib import Path
from urllib.parse import quote

from fastapi import Depends, FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

from . import auth, storage
from .extras import Stars, stream_zip
from .config import Settings, load_settings

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


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    root = settings.files_root
    thumbs_dir = settings.data_dir / "thumbs"
    thumbs_dir.mkdir(parents=True, exist_ok=True)

    stars = Stars(settings.data_dir)
    app = FastAPI(title="HomeDrive", version="0.4.0")

    def mark(entries: list[dict]) -> list[dict]:
        for e in entries:
            e["starred"] = stars.is_starred(e["path"])
        return entries

    def require_user(request: Request) -> str:
        header = request.headers.get("authorization", "")
        token = header[7:] if header.lower().startswith("bearer ") else ""
        user = auth.check_token(token, settings.secret) if token else None
        if not user:
            raise HTTPException(401, "Not logged in")
        return user

    def safe(rel: str) -> Path:
        try:
            return storage.resolve(root, rel)
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    @app.get("/api/health")
    def health():
        return {"ok": True, "name": "HomeDrive", "version": app.version}

    @app.post("/api/login")
    def login(body: LoginBody):
        if body.username != settings.username or not auth.check_password(body.password, settings.password):
            raise HTTPException(401, "Wrong username or password")
        return {"token": auth.make_token(body.username, settings.secret, settings.token_days), "username": body.username}

    @app.get("/api/me")
    def me(user: str = Depends(require_user)):
        usage = shutil.disk_usage(root)
        return {"username": user, "total": usage.total, "used": usage.used, "free": usage.free}

    @app.get("/api/list")
    def list_files(path: str = "", hidden: bool = False, user: str = Depends(require_user)):
        safe(path)
        try:
            return {"path": path.strip("/"), "entries": mark(storage.list_dir(root, path, hidden))}
        except FileNotFoundError:
            raise HTTPException(404, "Folder not found")

    @app.get("/api/download")
    def download(path: str, user: str = Depends(require_user)):
        p = safe(path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        return FileResponse(p, filename=p.name)

    @app.get("/api/zip")
    def download_zip(path: list[str] = Query(...), user: str = Depends(require_user)):
        """Zip one or more files/folders. Streams, so big folders start downloading right away."""
        items = []
        for rel in path:
            p = safe(rel)
            if p == root:
                raise HTTPException(400, "Can't zip the whole drive")
            if not p.exists():
                raise HTTPException(404, f"Not found: {rel}")
            items.append((p, p.name))
        if len(items) == 1:
            name = f"{items[0][0].stem if items[0][0].is_file() else items[0][0].name}.zip"
        else:
            name = "HomeDrive download.zip"
        headers = {"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"}
        return StreamingResponse(stream_zip(items), media_type="application/zip", headers=headers)

    @app.get("/api/starred")
    def starred(user: str = Depends(require_user)):
        entries = []
        for rel in stars.all():
            try:
                p = storage.resolve(root, rel)
            except storage.PathError:
                continue
            if p.exists() and p != root:
                entries.append(storage.entry(root, p))
        entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
        return {"entries": mark(entries)}

    @app.post("/api/star")
    def star(body: StarBody, user: str = Depends(require_user)):
        p = safe(body.path)
        if not p.exists() or p == root:
            raise HTTPException(404, "Not found")
        stars.set(storage.relpath(root, p), body.starred)
        return {"path": storage.relpath(root, p), "starred": body.starred}

    @app.get("/api/thumbnail")
    def thumbnail(path: str, size: int = Query(256, ge=32, le=1024), user: str = Depends(require_user)):
        p = safe(path)
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
                    img.convert("RGB").save(cached, "JPEG", quality=82)
            except Exception:
                raise HTTPException(415, "Couldn't make a thumbnail")
        return FileResponse(cached, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=86400"})

    @app.post("/api/upload")
    def upload(path: str = "", files: list[UploadFile] = File(...), user: str = Depends(require_user)):
        folder = safe(path)
        if not folder.is_dir():
            raise HTTPException(404, "Folder not found")
        saved = []
        for f in files:
            try:
                name = storage.safe_name(f.filename or "")
            except storage.PathError as e:
                raise HTTPException(400, str(e))
            dest = storage.unique_path(folder / name)
            # Write to a temp file first so a dropped upload never leaves half a file.
            with tempfile.NamedTemporaryFile(dir=folder, prefix=".upload-", delete=False) as tmp:
                shutil.copyfileobj(f.file, tmp, length=1024 * 1024)
                tmp.flush()
                os.fsync(tmp.fileno())
                tmp_path = Path(tmp.name)
            tmp_path.chmod(0o644)
            tmp_path.rename(dest)
            e = storage.entry(root, dest)
            # Fingerprint of what's actually on disk, so the app can confirm a
            # perfect copy before deleting anything from your Mac.
            e["sha256"] = storage.sha256(dest)
            saved.append(e)
        return {"saved": mark(saved)}

    @app.get("/api/hash")
    def file_hash(path: str, user: str = Depends(require_user)):
        p = safe(path)
        if not p.is_file():
            raise HTTPException(404, "File not found")
        return {"path": path, "size": p.stat().st_size, "sha256": storage.sha256(p)}

    @app.post("/api/mkdir")
    def mkdir(body: PathBody, user: str = Depends(require_user)):
        p = safe(body.path)
        if p.exists():
            raise HTTPException(409, "Something with that name already exists")
        p.mkdir(parents=True)
        return storage.entry(root, p)

    @app.post("/api/move")
    def move(body: MoveBody, user: str = Depends(require_user)):
        safe(body.src)
        safe(body.dst)
        try:
            moved = storage.move(root, body.src, body.dst)
            stars.moved(body.src.strip("/"), storage.relpath(root, moved))
            return mark([storage.entry(root, moved)])[0]
        except FileNotFoundError:
            raise HTTPException(404, "Not found")
        except FileExistsError:
            raise HTTPException(409, "Something with that name already exists")
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    @app.get("/api/recent")
    def recent(limit: int = Query(50, ge=1, le=500), user: str = Depends(require_user)):
        return {"entries": mark(storage.recent(root, limit))}

    @app.get("/api/search")
    def search(q: str, limit: int = Query(200, ge=1, le=1000), user: str = Depends(require_user)):
        return {"entries": mark(storage.search(root, q, limit))}

    @app.get("/api/trash")
    def trash_list(user: str = Depends(require_user)):
        return {"entries": storage.list_trash(root)}

    @app.post("/api/trash/restore")
    def trash_restore(body: NameBody, user: str = Depends(require_user)):
        try:
            return mark([storage.entry(root, storage.restore(root, body.name))])[0]
        except FileNotFoundError:
            raise HTTPException(404, "Not in the trash")
        except storage.PathError as e:
            raise HTTPException(400, str(e))

    @app.post("/api/trash/delete")
    def trash_delete(body: NameBody, user: str = Depends(require_user)):
        try:
            storage.delete_forever(root, body.name)
        except FileNotFoundError:
            raise HTTPException(404, "Not in the trash")
        except storage.PathError as e:
            raise HTTPException(400, str(e))
        return Response(status_code=204)

    @app.post("/api/trash/empty")
    def trash_empty(user: str = Depends(require_user)):
        return {"deleted": storage.empty_trash(root)}

    @app.post("/api/delete")
    def delete(body: PathBody, user: str = Depends(require_user)):
        safe(body.path)
        try:
            storage.trash(root, body.path)
        except FileNotFoundError:
            raise HTTPException(404, "Not found")
        except storage.PathError as e:
            raise HTTPException(400, str(e))
        return Response(status_code=204)

    return app
