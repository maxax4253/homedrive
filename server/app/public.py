"""Public share-link pages. This is the ONLY thing exposed to the internet.

It runs as its own little server (port 8091) with no login, no browsing and no
API: just /s/<token> pages that let someone download the one file or folder
a link points to. Everything else returns 404.
"""

import html
import os
import time
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, Form, Request
from fastapi.responses import FileResponse, HTMLResponse, Response, StreamingResponse

from . import auth, storage
from .db import verify_password
from .extras import Limiter, stream_zip, visible_files
from .links_db import LinksDB, signing_key
from .main import USERS_DIR

UNLOCK_SECONDS = 600
MAX_FAILURES = 8          # wrong passwords per IP...
FAILURE_WINDOW = 600      # ...per 10 minutes
MAX_HITS = 120            # page/download requests per IP per minute
MAX_LINK_FAILURES = 30    # wrong passwords for one link from everyone together, per 10 minutes

SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'",
    "X-Robots-Tag": "noindex, nofollow",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}


def _size(n: int) -> str:
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n} bytes"


def _page(title: str, body: str, status: int = 200) -> HTMLResponse:
    doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · HomeDrive</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ margin: 0; min-height: 100vh; display: grid; place-items: center;
         font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #f8fafd; color: #1f1f1f; }}
  .card {{ background: #fff; border-radius: 20px; padding: 36px 40px; width: min(420px, 86vw);
          box-shadow: 0 1px 3px rgba(0,0,0,.12), 0 8px 24px rgba(0,0,0,.06); text-align: center; }}
  .brand {{ color: #0b57d0; font-weight: 600; letter-spacing: .2px; margin-bottom: 22px; }}
  .icon {{ font-size: 54px; line-height: 1; margin-bottom: 10px; }}
  h1 {{ font-size: 19px; font-weight: 500; margin: 0 0 4px; word-break: break-word; }}
  .meta {{ color: #5f6368; font-size: 13px; margin-bottom: 26px; }}
  .btn {{ display: inline-block; background: #0b57d0; color: #fff; border: 0; border-radius: 999px;
         padding: 12px 28px; font: inherit; font-weight: 500; text-decoration: none; cursor: pointer; }}
  input {{ width: 100%; box-sizing: border-box; padding: 12px 16px; border-radius: 12px; font: inherit;
          border: 1px solid #c4c7c5; margin-bottom: 14px; background: transparent; color: inherit; }}
  .err {{ color: #b3261e; font-size: 13px; margin: -6px 0 12px; }}
  .foot {{ color: #80868b; font-size: 12px; margin-top: 26px; }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #1b1c1d; color: #e3e3e3; }}
    .card {{ background: #131314; box-shadow: none; border: 1px solid #3c4043; }}
    .brand {{ color: #a8c7fa; }} .btn {{ background: #a8c7fa; color: #062e6f; }}
    .meta, .foot {{ color: #9aa0a6; }}
  }}
</style></head>
<body><main class="card"><div class="brand">HomeDrive</div>{body}</main></body></html>"""
    return HTMLResponse(doc, status_code=status, headers=SECURITY_HEADERS)


def _gone() -> HTMLResponse:
    return _page("Link unavailable", """<div class="icon">🔗</div><h1>This link isn't available</h1>
<div class="meta">It may have expired or been turned off by the person who shared it.</div>""", 404)


def create_public_app(settings=None) -> FastAPI:
    """`settings` is only passed by the tests. In real use everything comes from two
    environment variables, and this server is given nothing else: no accounts, no
    login secret, no admin password. Just the files (read-only) and the links folder."""
    if settings is not None:
        files_root, links_dir = settings.files_root, settings.data_dir / "links"
    else:
        files_root = Path(os.environ.get("HOMEDRIVE_FILES", "/files")).resolve()
        links_dir = Path(os.environ.get("HOMEDRIVE_LINKS_DATA", "/data/links"))
    db = LinksDB(links_dir)
    secret = signing_key(links_dir)
    limiter = Limiter(forget_after=FAILURE_WINDOW)
    app = FastAPI(title="HomeDrive links", docs_url=None, redoc_url=None, openapi_url=None)

    def client_ip(request: Request) -> str:
        # Tailscale Funnel adds the visitor's address to the END of X-Forwarded-For.
        # Anything before it was sent by the visitor and can be faked, so use the last one.
        fwd = request.headers.get("x-forwarded-for", "")
        last = fwd.split(",")[-1].strip()
        return last or (request.client.host if request.client else "?")

    def lookup(token: str):
        """The share and the file it points to, or None if the link is dead."""
        if len(token) > 64 or not token.replace("-", "").replace("_", "").isalnum():
            return None
        sh = db.get(token)
        if not sh or not sh.active:
            return None
        # Same layout as the main server: the admin's space is the whole drive,
        # everyone else's is Users/<name> plus the Shared folder.
        home = files_root if sh.owner_is_admin else files_root / USERS_DIR / sh.owner
        space = storage.Space(home, files_root / storage.SHARED_NAME)
        try:
            p = space.resolve(sh.path)
        except storage.PathError:
            return None
        if not p.exists() or p.is_dir() != sh.is_dir:
            return None
        return sh, p

    def describe(sh, p: Path) -> str:
        if p.is_dir():
            files = sum(1 for _ in visible_files(p))
            what = f"Folder · {files} file{'s' if files != 1 else ''} · downloads as .zip"
        else:
            what = _size(p.stat().st_size)
        if sh.expires:
            days = max(0, int((sh.expires - time.time()) // 86400))
            what += f" · expires in {days} day{'s' if days != 1 else ''}" if days else " · expires today"
        return what

    def download_page(sh, p: Path, unlock: str = "") -> HTMLResponse:
        icon = "📁" if p.is_dir() else "📄"
        href = f"/s/{sh.token}/download" + (f"?k={quote(unlock)}" if unlock else "")
        return _page(p.name, f"""<div class="icon">{icon}</div><h1>{html.escape(p.name)}</h1>
<div class="meta">{html.escape(describe(sh, p))}</div>
<a class="btn" href="{href}">Download</a>
<div class="foot">Shared from someone's HomeDrive</div>""")

    def password_page(sh, p: Path, error: str = "") -> HTMLResponse:
        err = f'<div class="err">{html.escape(error)}</div>' if error else ""
        return _page("Password needed", f"""<div class="icon">🔒</div><h1>{html.escape(p.name)}</h1>
<div class="meta">This link is protected with a password.</div>
<form method="post" action="/s/{sh.token}">
<input type="password" name="password" placeholder="Password" autofocus required>{err}
<button class="btn" type="submit">Unlock</button></form>""")

    @app.middleware("http")
    async def throttle(request: Request, call_next):
        if not limiter.allow("hit:" + client_ip(request), MAX_HITS, 60):
            return _page("Slow down", "<h1>Too many requests</h1><div class='meta'>Try again in a minute.</div>", 429)
        return await call_next(request)

    @app.get("/")
    def home():
        return _page("HomeDrive", "<h1>Nothing to see here</h1><div class='meta'>Open the full link you were sent.</div>")

    @app.get("/s/{token}")
    def share_page(token: str):
        found = lookup(token)
        if not found:
            return _gone()
        sh, p = found
        return password_page(sh, p) if sh.has_password else download_page(sh, p)

    @app.post("/s/{token}")
    def unlock(token: str, request: Request, password: str = Form("")):
        found = lookup(token)
        if not found:
            return _gone()
        sh, p = found
        if not sh.has_password:
            return download_page(sh, p)
        key = f"fail:{client_ip(request)}"
        link_key = f"linkfail:{sh.token}"   # also caps guessing spread over many addresses
        if not (limiter.allow(key, MAX_FAILURES, FAILURE_WINDOW, record=False)
                and limiter.allow(link_key, MAX_LINK_FAILURES, FAILURE_WINDOW, record=False)):
            return password_page(sh, p, "Too many wrong tries. Wait a few minutes and try again.")
        if not verify_password(password, sh.pw_hash):
            limiter.record(key)
            limiter.record(link_key)
            return password_page(sh, p, "That password isn't right.")
        return download_page(sh, p, auth.sign_value(sh.token, secret, UNLOCK_SECONDS))

    @app.get("/s/{token}/download")
    def share_download(token: str, request: Request, k: str = ""):
        found = lookup(token)
        if not found:
            return _gone()
        sh, p = found
        if sh.has_password and not auth.check_signed_value(sh.token, k, secret):
            return password_page(sh, p, "Enter the password again to download.")
        db.count_download(sh.token, client_ip(request))
        if p.is_dir():
            headers = {"Content-Disposition": f"attachment; filename*=UTF-8''{quote(p.name + '.zip')}"}
            headers.update(SECURITY_HEADERS)
            return StreamingResponse(stream_zip([(p, p.name)]), media_type="application/zip", headers=headers)
        return FileResponse(p, filename=p.name, headers=SECURITY_HEADERS)

    @app.api_route("/{rest:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
    def everything_else(rest: str):
        return Response(status_code=404)

    return app
