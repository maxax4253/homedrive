#!/usr/bin/env python3
"""End-to-end check of a running HomeDrive server.  Run it with:  homedrive selftest

It talks to the real server the same way the Mac app does, using a scratch folder
and a throwaway account, and cleans everything up when it's done (even if a check
fails). Standard library only, so it runs with the server's own python3.

Settings come from environment variables (the `homedrive` command fills these in):
  HD_URL       http://<tailscale-ip>:8090
  HD_USER      admin username
  HD_PASSWORD  admin password
  HD_PUBLIC    public share-link address (empty if share links are off)
"""

import hashlib
import io
import json
import os
import re
import secrets
import shlex
import struct
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib

URL = os.environ.get("HD_URL", "").rstrip("/")
USER = os.environ.get("HD_USER", "")
PASSWORD = os.environ.get("HD_PASSWORD", "")
PUBLIC = os.environ.get("HD_PUBLIC", "").rstrip("/")
DOCKER = os.environ.get("HD_DOCKER", "docker")   # "sudo docker" if needed

STAMP = time.strftime("%Y%m%d-%H%M%S")
FOLDER = f"_selftest-{STAMP}"           # scratch folder at the top of the admin's drive
TEST_USER = f"selftest-{secrets.token_hex(3)}"

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = DIM = RESET = ""

results: list[tuple[str, bool, str]] = []


# ---------------------------------------------------------------- HTTP helpers

class Reply:
    def __init__(self, status: int, body: bytes, headers):
        self.status, self.body, self.headers = status, body, headers

    def json(self):
        return json.loads(self.body or b"null")

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", "replace")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)


def request(method: str, url: str, *, token: str | None = None, body: bytes | None = None,
            content_type: str | None = None, timeout: float = 120) -> Reply:
    req = urllib.request.Request(url, data=body, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with opener.open(req, timeout=timeout) as r:
            return Reply(r.status, r.read(), r.headers)
    except urllib.error.HTTPError as e:
        return Reply(e.code, e.read(), e.headers)


class Client:
    def __init__(self, token: str | None = None):
        self.token = token

    def url(self, path: str, params: dict | list | None = None) -> str:
        q = f"?{urllib.parse.urlencode(params, doseq=True)}" if params else ""
        return f"{URL}/api/{path}{q}"

    def get(self, path, params=None, **kw) -> Reply:
        return request("GET", self.url(path, params), token=self.token, **kw)

    def post(self, path, data=None, params=None) -> Reply:
        body = json.dumps(data).encode() if data is not None else None
        return request("POST", self.url(path, params), token=self.token, body=body,
                       content_type="application/json" if body is not None else None)

    def delete(self, path) -> Reply:
        return request("DELETE", self.url(path), token=self.token)

    def upload(self, folder: str, name: str, data: bytes, **params) -> Reply:
        boundary = "selftest" + secrets.token_hex(8)
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{name}\"\r\n"
                f"Content-Type: application/octet-stream\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
        params = {"path": folder, **{k: str(v).lower() if isinstance(v, bool) else v for k, v in params.items()}}
        return request("POST", self.url("upload", params), token=self.token, body=body,
                       content_type=f"multipart/form-data; boundary={boundary}")


def login(username: str, password: str) -> Client:
    r = Client().post("login", {"username": username, "password": password})
    if r.status != 200:
        raise AssertionError(f"login as {username} failed: {r.status} {r.text[:200]}")
    return Client(r.json()["token"])


def form(url: str, fields: dict) -> Reply:
    return request("POST", url, body=urllib.parse.urlencode(fields).encode(),
                   content_type="application/x-www-form-urlencoded")


# ---------------------------------------------------------------- test plumbing

def check(name: str):
    """Decorator: run a check, record pass/fail, never stop the run."""
    def wrap(fn):
        def run(*a, **k):
            try:
                fn(*a, **k)
                results.append((name, True, ""))
                print(f"  {GREEN}✓{RESET} {name}")
            except Exception as e:  # noqa: BLE001
                detail = str(e) or e.__class__.__name__
                if not isinstance(e, AssertionError):
                    detail = f"{e.__class__.__name__}: {detail}"
                results.append((name, False, detail))
                print(f"  {RED}✗ {name}{RESET}\n    {detail}")
        return run
    return wrap


def warn(name: str, why: str):
    results.append((name, True, "warning"))
    warnings.append((name, why))
    print(f"  {YELLOW}!{RESET} {name}\n    {YELLOW}{why}{RESET}")


warnings: list[tuple[str, str]] = []


def skip(name: str, why: str):
    results.append((name, True, "skipped"))
    print(f"  {YELLOW}–{RESET} {name} {DIM}(skipped: {why}){RESET}")


def expect(cond, message: str):
    if not cond:
        raise AssertionError(message)


def status(r: Reply, want: int, what: str):
    expect(r.status == want, f"{what}: expected HTTP {want}, got {r.status} {r.text[:200]}")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tiny_png() -> bytes:
    """A real 64x48 PNG made with the standard library (for the thumbnail check)."""
    w, h = 64, 48
    rows = b"".join(b"\x00" + b"".join(bytes((x * 4 % 256, y * 5 % 256, 128)) for x in range(w))
                    for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def entry_names(r: Reply) -> set[str]:
    return {e["name"] for e in r.json()["entries"]}


# ---------------------------------------------------------------- the checks

users_folder_existed = True


def run_all() -> None:
    global users_folder_existed
    print(f"\nHomeDrive self-test against {URL}\n")
    ctx: dict = {}

    print("Server")

    @check("server is up and reports its version")
    def _():
        r = Client().get("health")
        status(r, 200, "health")
        ctx["version"] = r.json()["version"]
        print(f"    {DIM}version {ctx['version']}{RESET}")
    _()

    @check("wrong password is refused")
    def _():
        status(Client().post("login", {"username": USER, "password": PASSWORD + "-wrong"}), 401, "bad login")
    _()

    @check("admin can sign in")
    def _():
        ctx["admin"] = login(USER, PASSWORD)
    _()
    if len(PASSWORD) < 8:
        warn("admin password is long enough",
             "Your admin password is under 8 characters. Change it with: homedrive password")
    admin: Client | None = ctx.get("admin")
    if admin:
        users_folder_existed = "Users" in entry_names(admin.get("list"))
    if not admin:
        print(f"\n{RED}Can't sign in, so the rest of the checks can't run.{RESET}")
        return

    @check("requests without a login are refused")
    def _():
        status(Client().get("list"), 401, "list without token")
        status(Client("not-a-real-token").get("list"), 401, "list with a fake token")
    _()

    @check("storage numbers make sense")
    def _():
        me = admin.get("me").json()
        expect(me["total"] > 0 and 0 <= me["used"] <= me["total"], f"odd totals: {me}")
        expect("drive_used" in me, "server doesn't report HomeDrive's own usage")
        if me.get("scope") == "disk":
            expect(me["drive_used"] <= me["used"], "HomeDrive files bigger than the whole disk's used space")
        print(f"    {DIM}{me['drive_used'] / 1e6:.1f} MB in HomeDrive, "
              f"{me['used'] / 1e9:.1f} of {me['total'] / 1e9:.0f} GB used on the disk{RESET}")
    _()

    @check("paths outside the drive are blocked")
    def _():
        for bad in ("../", "../../etc", "/../../etc/passwd"):
            r = admin.get("list", {"path": bad})
            expect(r.status in (400, 404), f"list {bad!r} gave HTTP {r.status}")
        r = admin.get("download", {"path": "../../etc/passwd"})
        expect(r.status in (400, 404), f"download of /etc/passwd gave HTTP {r.status}")
    _()

    print("\nFiles")
    one = b"HomeDrive self-test, version one\n" * 50
    two = b"HomeDrive self-test, version two (edited)\n" * 50
    three = b"edited somewhere else\n"

    @check("create a folder")
    def _():
        status(admin.post("mkdir", {"path": FOLDER}), 200, "mkdir")
        status(admin.post("mkdir", {"path": FOLDER}), 409, "second mkdir with the same name")
        status(admin.post("mkdir", {"path": f"{FOLDER}/Sub"}), 200, "mkdir Sub")
    _()

    @check("upload is stored intact (fingerprint matches)")
    def _():
        r = admin.upload(FOLDER, "notes.txt", one)
        status(r, 200, "upload")
        saved = r.json()["saved"][0]
        expect(saved["sha256"] == sha(one), "server's fingerprint doesn't match what was sent")
        expect(saved["size"] == len(one), "size doesn't match")
        ctx["modified"] = saved["modified"]
    _()

    @check("download gives back the exact same bytes")
    def _():
        r = admin.get("download", {"path": f"{FOLDER}/notes.txt"})
        status(r, 200, "download")
        expect(r.body == one, "downloaded bytes differ from the upload")
        h = admin.get("hash", {"path": f"{FOLDER}/notes.txt"}).json()
        expect(h["sha256"] == sha(one), "hash endpoint disagrees")
    _()

    @check("uploading the same name again keeps both")
    def _():
        r = admin.upload(FOLDER, "notes.txt", b"second file")
        status(r, 200, "upload")
        expect(r.json()["saved"][0]["name"] == "notes (1).txt", f"got {r.json()['saved'][0]['name']}")
        expect({"notes.txt", "notes (1).txt"} <= entry_names(admin.get("list", {"path": FOLDER})),
               "folder doesn't show both files")
    _()

    @check("editing a file keeps the old version in history")
    def _():
        r = admin.upload(FOLDER, "notes.txt", two, replace=True, if_modified=ctx["modified"])
        status(r, 200, "replace")
        ctx["modified2"] = r.json()["saved"][0]["modified"]
        v = admin.get("versions", {"path": f"{FOLDER}/notes.txt"}).json()["versions"]
        edits = [x for x in v if x["source"] == "edit"]
        expect(edits, "no edit history after replacing the file")
        old = admin.get("versions/download", {"path": f"{FOLDER}/notes.txt", "version": edits[0]["id"]})
        expect(old.body == one, "the saved old version isn't the original")
        ctx["old_version"] = edits[0]["id"]
    _()

    @check("an edit based on an old copy is refused (no silent overwrite)")
    def _():
        r = admin.upload(FOLDER, "notes.txt", three, replace=True, if_modified=ctx["modified"])
        status(r, 409, "stale replace")
        expect(admin.get("download", {"path": f"{FOLDER}/notes.txt"}).body == two,
               "the file changed even though the edit was refused")
    _()

    @check("restoring an old version works and is undoable")
    def _():
        status(admin.post("versions/restore", {"path": f"{FOLDER}/notes.txt", "version": ctx["old_version"]}),
               200, "restore version")
        expect(admin.get("download", {"path": f"{FOLDER}/notes.txt"}).body == one, "restore didn't bring back v1")
        v = admin.get("versions", {"path": f"{FOLDER}/notes.txt"}).json()["versions"]
        kept = [x for x in v if x["source"] == "edit"]
        found = any(admin.get("versions/download", {"path": f"{FOLDER}/notes.txt", "version": x["id"]}).body == two
                    for x in kept)
        expect(found, "the edited version wasn't kept when restoring")
    _()

    @check("photo thumbnails")
    def _():
        status(admin.upload(FOLDER, "pixel.png", tiny_png()), 200, "upload png")
        r = admin.get("thumbnail", {"path": f"{FOLDER}/pixel.png", "size": 64})
        status(r, 200, "thumbnail")
        expect(r.body[:3] == b"\xff\xd8\xff", "thumbnail isn't a JPEG")
    _()

    @check("rename and move")
    def _():
        status(admin.post("move", {"src": f"{FOLDER}/notes (1).txt", "dst": f"{FOLDER}/Sub/moved.txt"}), 200, "move")
        names = entry_names(admin.get("list", {"path": f"{FOLDER}/Sub"}))
        expect("moved.txt" in names, "moved file isn't in Sub")
        status(admin.post("move", {"src": FOLDER, "dst": f"{FOLDER}/Sub/inside"}), 400, "folder into itself")
    _()

    @check("stars follow a file when it's renamed")
    def _():
        status(admin.post("star", {"path": f"{FOLDER}/pixel.png"}), 200, "star")
        status(admin.post("move", {"src": f"{FOLDER}/pixel.png", "dst": f"{FOLDER}/photo.png"}), 200, "rename")
        starred = {e["path"] for e in admin.get("starred").json()["entries"]}
        expect(f"{FOLDER}/photo.png" in starred, "star was lost on rename")
        admin.post("star", {"path": f"{FOLDER}/photo.png", "starred": False})
    _()

    @check("search and recent find new files")
    def _():
        found = {e["path"] for e in admin.get("search", {"q": "moved.txt"}).json()["entries"]}
        expect(f"{FOLDER}/Sub/moved.txt" in found, "search didn't find moved.txt")
        recent = {e["path"] for e in admin.get("recent", {"limit": 50}).json()["entries"]}
        expect(f"{FOLDER}/notes.txt" in recent, "notes.txt isn't in Recent")
    _()

    @check("download a folder as a zip")
    def _():
        r = admin.get("zip", {"path": FOLDER})
        status(r, 200, "zip")
        names = set(zipfile.ZipFile(io.BytesIO(r.body)).namelist())
        expect({f"{FOLDER}/notes.txt", f"{FOLDER}/Sub/moved.txt", f"{FOLDER}/photo.png"} <= names,
               f"zip is missing files: {sorted(names)}")
        expect(zipfile.ZipFile(io.BytesIO(r.body)).read(f"{FOLDER}/notes.txt") == one, "file inside the zip differs")
    _()

    @check("offline sync file list (tree)")
    def _():
        paths = {e["path"] for e in admin.get("tree", {"path": FOLDER}).json()["entries"]}
        expect(f"{FOLDER}/Sub/moved.txt" in paths and f"{FOLDER}/notes.txt" in paths, f"tree: {sorted(paths)}")
    _()

    @check("trash, restore and delete forever")
    def _():
        status(admin.post("delete", {"path": f"{FOLDER}/Sub/moved.txt"}), 204, "move to trash")
        expect("moved.txt" not in entry_names(admin.get("list", {"path": f"{FOLDER}/Sub"})), "still in the folder")
        trashed = [e for e in admin.get("trash").json()["entries"] if e["original"] == f"{FOLDER}/Sub/moved.txt"]
        expect(trashed, "not in the trash")
        status(admin.post("trash/restore", {"name": trashed[0]["trash_name"]}), 200, "restore")
        expect("moved.txt" in entry_names(admin.get("list", {"path": f"{FOLDER}/Sub"})), "restore didn't put it back")
        admin.post("delete", {"path": f"{FOLDER}/Sub/moved.txt"})
        trashed = [e for e in admin.get("trash").json()["entries"] if e["original"] == f"{FOLDER}/Sub/moved.txt"]
        status(admin.post("trash/delete", {"name": trashed[0]["trash_name"]}), 204, "delete forever")
    _()

    print("\nAccounts")

    @check("create a test account with a storage limit")
    def _():
        r = admin.post("users", {"username": TEST_USER, "password": "selftest-pw", "quota_gb": 0.00001})
        status(r, 200, "add user")
        ctx["user"] = login(TEST_USER, "selftest-pw")
    _()
    user: Client | None = ctx.get("user")

    if user:
        @check("other accounts can't see your files")
        def _():
            names = entry_names(user.get("list"))
            expect(FOLDER not in names, "the test account can see the admin's folder")
            expect("Shared" in names, "the test account has no Shared folder")
            r = user.get("download", {"path": f"../../{FOLDER}/notes.txt"})
            expect(r.status in (400, 404), f"reached the admin's file: HTTP {r.status}")
            expect(not any(e["path"].startswith(FOLDER) for e in user.get("search", {"q": "notes"}).json()["entries"]),
                   "search shows the admin's files")
        _()

        @check("storage limit is enforced")
        def _():
            status(user.upload("", "small.txt", b"x" * 100), 200, "small upload")
            status(user.upload("", "big.bin", b"x" * 50_000), 413, "upload over the limit")
        _()

        @check("only the admin can manage the server")
        def _():
            for path in ("users", "backups", "admin/links"):
                status(user.get(path), 403, f"GET {path}")
            status(user.post("admin/update"), 403, "update server")
        _()

        @check("password change signs out old logins")
        def _():
            old_token = user.token
            r = user.post("me/password", {"old_password": "selftest-pw", "new_password": "selftest-pw2"})
            status(r, 200, "change password")
            status(Client(old_token).get("list"), 401, "old login after password change")
            status(Client(r.json()["token"]).get("list"), 200, "new login")
        _()

        @check("empty passwords are refused")
        def _():
            status(admin.post("users", {"username": TEST_USER + "x", "password": ""}), 400, "empty password")
            status(admin.post(f"users/{TEST_USER}/password", {"password": ""}), 400, "empty reset")
        _()

        @check("repeated wrong passwords pause sign-in")
        def _():
            for _ in range(10):
                Client().post("login", {"username": TEST_USER, "password": "definitely-wrong"})
            r = Client().post("login", {"username": TEST_USER, "password": "selftest-pw2"})
            status(r, 429, "sign-in after 10 wrong passwords (even with the right one)")
        _()

    print("\nShare links")
    links_on = bool(admin.get("me").json().get("links_enabled"))
    if not links_on or not PUBLIC:
        skip("public share links", "share links are off; turn them on to test them")
    else:
        @check("create links")
        def _():
            r = admin.post("shares", {"path": f"{FOLDER}/notes.txt", "expires_days": 1, "password": "open sesame"})
            status(r, 200, "password link")
            ctx["pw_link"] = r.json()
            r = admin.post("shares", {"path": f"{FOLDER}/photo.png", "expires_days": 1})
            status(r, 200, "open link")
            ctx["open_link"] = r.json()
            r = admin.post("shares", {"path": FOLDER, "expires_days": 1})
            status(r, 200, "folder link")
            ctx["folder_link"] = r.json()
            expect(ctx["pw_link"]["url"].startswith(PUBLIC + "/s/"), f"link URL is {ctx['pw_link']['url']}")
        _()

        def pub(path: str) -> str:
            return f"{PUBLIC}{path}"

        if "pw_link" in ctx:
            @check("public page is reachable over the internet address")
            def _():
                r = request("GET", ctx["open_link"]["url"], timeout=30)
                status(r, 200, "open link page")
                expect("photo.png" in r.text and "Download" in r.text, "page doesn't show the file")
                expect("default-src 'none'" in r.headers.get("Content-Security-Policy", ""), "security headers missing")
            _()

            @check("link without a password downloads the file")
            def _():
                r = request("GET", pub(f"/s/{ctx['open_link']['token']}/download"), timeout=30)
                status(r, 200, "download")
                expect(r.body == tiny_png(), "downloaded file differs")
                mine = [s for s in admin.get("shares").json()["shares"] if s["token"] == ctx["open_link"]["token"]]
                expect(mine and mine[0]["downloads"] >= 1, "download wasn't counted")
                expect(mine[0].get("recent_downloads"), "download wasn't logged (time and address)")
            _()

            @check("password link: wrong password refused, right one works")
            def _():
                t = ctx["pw_link"]["token"]
                page = request("GET", pub(f"/s/{t}"), timeout=30)
                expect("password" in page.text.lower(), "no password prompt")
                expect(b"version one" not in request("GET", pub(f"/s/{t}/download"), timeout=30).body,
                       "file downloaded without the password")
                wrong = form(pub(f"/s/{t}"), {"password": "nope"})
                expect("isn" in wrong.text and "right" in wrong.text, "wrong password wasn't rejected")
                right = form(pub(f"/s/{t}"), {"password": "open sesame"})
                m = re.search(r'href="(/s/[^"]+/download\?k=[^"]+)"', right.text)
                expect(m, "right password didn't give a download link")
                dl = request("GET", pub(m.group(1).replace("&amp;", "&")), timeout=30)
                expect(dl.body == one, "downloaded file differs")
            _()

            @check("folder link downloads as a zip")
            def _():
                r = request("GET", pub(f"/s/{ctx['folder_link']['token']}/download"), timeout=60)
                status(r, 200, "folder download")
                names = zipfile.ZipFile(io.BytesIO(r.body)).namelist()
                expect(f"{FOLDER}/notes.txt" in names, f"zip contents: {names}")
            _()

            @check("public address exposes nothing without signing in")
            def _():
                # Older servers hide the API from the public address entirely (404); the
                # all-in-one server serves it there but only to signed-in apps (401).
                for path in ("/api/list", "/api/users", "/api/trash"):
                    r = request("GET", pub(path), timeout=30)
                    expect(r.status in (401, 404), f"{path} gave HTTP {r.status}")
                for path in ("/s/not-a-real-link", "/docs", "/openapi.json"):
                    r = request("GET", pub(path), timeout=30)
                    expect(r.status == 404, f"{path} gave HTTP {r.status}")
            _()

            @check("a link pauses after 10 wrong passwords")
            def _():
                r = admin.post("shares", {"path": f"{FOLDER}/notes.txt", "expires_days": 1, "password": "selftest-link"})
                status(r, 200, "create link")
                ctx["lock_link"] = r.json()
                t = ctx["lock_link"]["token"]
                for _ in range(10):
                    form(pub(f"/s/{t}"), {"password": "wrong"})
                r = form(pub(f"/s/{t}"), {"password": "selftest-link"})
                expect("Too many wrong tries" in r.text, "the link still accepted passwords after 10 wrong ones")
                mine = [s for s in admin.get("shares").json()["shares"] if s["token"] == t]
                expect(mine and mine[0].get("locked_until"), "the app isn't told the link is paused")
            _()

            @check("revoked links stop working")
            def _():
                for key in ("pw_link", "open_link", "folder_link", "lock_link"):
                    if key in ctx:
                        status(admin.delete(f"shares/{ctx[key]['token']}"), 204, "revoke")
                r = request("GET", ctx["open_link"]["url"], timeout=30)
                status(r, 404, "revoked link")
            _()

    print("\nLockdown")
    containers = docker_inspect()
    if containers is None:
        skip("containers are locked down", "couldn't run docker inspect")
    else:
        @check("main server container is locked down")
        def _():
            c = containers.get("homedrive")
            expect(c, "main server container not found")
            locked_down(c)
        _()

        if "links" in containers:
            @check("share-link server can't see the admin password or accounts")
            def _():
                c = containers["links"]
                env = {e.split("=", 1)[0] for e in c["Config"]["Env"]}
                leaked = env & {"HOMEDRIVE_PASSWORD", "HOMEDRIVE_SECRET", "HOMEDRIVE_USERNAME"}
                expect(not leaked, f"it has {', '.join(sorted(leaked))} (update the server)")
                mounts = {m["Destination"]: m for m in c["Mounts"]}
                expect(set(mounts) == {"/files", "/data/links"}, f"it can see {sorted(mounts)} (update the server)")
                expect(not mounts["/files"]["RW"], "it can change your files (should be read-only)")
                locked_down(c)
            _()
        else:
            skip("share-link server can't see the admin password or accounts", "share links are off")

    print("\nServer extras")

    @check("backup status")
    def _():
        b = admin.get("backups")
        status(b, 200, "backups")
        s = b.json()
        print(f"    {DIM}backups {'on' if s['enabled'] else 'off'}"
              f"{', ' + str(len(s['snapshots'])) + ' snapshots' if s['enabled'] else ''}{RESET}")
        if s["enabled"] and s.get("last_error"):
            raise AssertionError(f"last backup failed: {s['last_error']}")
    _()

    @check("app helper (share-link switch, server updates)")
    def _():
        s = admin.get("admin/links").json()
        expect(s["agent_installed"], "not installed: run 'sudo homedrive install-agent'")
        expect(s["state"] != "error", f"last helper job failed: {s.get('message')}")
    _()


def docker_inspect() -> dict | None:
    """Settings of the running HomeDrive containers, keyed by service name."""
    try:
        ids = subprocess.run(shlex.split(DOCKER) + ["ps", "-q", "--filter", "label=com.docker.compose.project=server"],
                             capture_output=True, text=True, timeout=30)
        if ids.returncode != 0 or not ids.stdout.split():
            return None
        out = subprocess.run(shlex.split(DOCKER) + ["inspect"] + ids.stdout.split(),
                             capture_output=True, text=True, timeout=30)
        return {c["Config"]["Labels"].get("com.docker.compose.service"): c for c in json.loads(out.stdout)}
    except Exception:  # noqa: BLE001
        return None


def locked_down(c: dict) -> None:
    hc = c["HostConfig"]
    expect(hc.get("ReadonlyRootfs"), "its program files can be changed (not read-only)")
    expect("ALL" in (hc.get("CapDrop") or []), "it still has special system powers")
    expect(any("no-new-privileges" in o for o in (hc.get("SecurityOpt") or [])), "it can gain privileges")
    expect(c["Config"].get("User") not in ("", "root", "0"), "it runs as root")


# ---------------------------------------------------------------- cleanup

def cleanup() -> None:
    """Remove everything the test made, whatever happened above."""
    try:
        admin = login(USER, PASSWORD)
    except Exception:  # noqa: BLE001
        print(f"\n{YELLOW}Couldn't sign in to clean up. Delete '{FOLDER}' and the account '{TEST_USER}' by hand.{RESET}")
        return
    problems = []
    for sh in admin.get("shares").json().get("shares", []):
        if sh["path"] == FOLDER or sh["path"].startswith(FOLDER + "/"):
            admin.delete(f"shares/{sh['token']}")
    if admin.get("users").status == 200 and any(u["username"] == TEST_USER for u in admin.get("users").json()["users"]):
        if admin.delete(f"users/{TEST_USER}").status != 204:
            problems.append(f"account {TEST_USER}")
    to_trash = [FOLDER, f"Users/{TEST_USER}"]
    if not users_folder_existed:
        # The test account created the Users folder; take it away again if nothing else is in it.
        admin.post("delete", {"path": f"Users/{TEST_USER}"})
        if not admin.get("list", {"path": "Users"}).json().get("entries"):
            to_trash.append("Users")
    for path in to_trash:
        r = admin.post("delete", {"path": path})
        if r.status not in (204, 400, 404):
            problems.append(path)
    originals = set(to_trash)
    for e in admin.get("trash").json()["entries"]:
        if e["original"] in originals or e["original"].startswith(FOLDER + "/"):
            admin.post("trash/delete", {"name": e["trash_name"]})
    if problems:
        print(f"\n{YELLOW}Cleanup left behind: {', '.join(problems)}{RESET}")
    else:
        print(f"\n{DIM}Cleaned up the test folder, links and account.{RESET}")


def main() -> int:
    if not (URL and USER and PASSWORD):
        print("Run this with:  homedrive selftest")
        return 2
    started = time.time()
    try:
        run_all()
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        results.append(("self-test itself", False, "crashed"))
    finally:
        cleanup()
    failed = [r for r in results if not r[1]]
    passed = len(results) - len(failed)
    print(f"\n{GREEN if not failed else RED}{passed} passed, {len(failed)} failed{RESET}"
          f" {DIM}({time.time() - started:.0f}s){RESET}")
    for name, _, detail in failed:
        print(f"  {RED}✗{RESET} {name}: {detail}")
    for name, why in warnings:
        print(f"  {YELLOW}!{RESET} {name}: {why}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
