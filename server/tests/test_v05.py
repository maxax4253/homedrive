"""Accounts, version history, backups and share links."""

import io
import os
import shutil
import time
import zipfile
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.backups import STAMP, Backups
from app.config import Settings
from app.main import create_app
from app.public import create_public_app


GO_BINARY = os.environ.get("HD_GO_BINARY")   # run the same tests against the Go server


def go_world(tmp_path, files, data, backup):
    """The same `world`, but backed by a running all-in-one Go server binary."""
    import socket
    import subprocess

    import httpx
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    base = f"http://127.0.0.1:{port}"
    env = dict(os.environ, HOMEDRIVE_FILES=str(files), HOMEDRIVE_DATA=str(data), HOMEDRIVE_USERNAME="max",
               HOMEDRIVE_PASSWORD="pw", HOMEDRIVE_SECRET="s3cret", HOMEDRIVE_PUBLIC_URL="https://box.example.ts.net",
               HOMEDRIVE_MIN_FREE_GB="0")
    proc = subprocess.Popen([GO_BINARY, "-listen", f"127.0.0.1:{port}"], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            httpx.get(base + "/api/health")
            break
        except httpx.HTTPError:
            time.sleep(0.05)
    public = httpx.Client(base_url=base, timeout=60)
    devices = {}   # every device must be paired first: the admin's with a code made on the server

    def login(user, pw):
        c = httpx.Client(base_url=base, timeout=60)
        if user not in devices:
            if user == "max":
                code = subprocess.run([GO_BINARY, "pair-code", "-data", str(data), "-user", "max"],
                                      capture_output=True, text=True, check=True).stdout.strip()
            else:
                code = admin.post("/api/devices/code", json={"username": user}).json()["code"]
            r = c.post("/api/pair", json={"code": code, "username": user, "password": pw, "device_name": "pytest"})
            assert r.status_code == 200, r.text
            devices[user] = r.json()["device_key"]
        else:
            r = c.post("/api/login", json={"username": user, "password": pw},
                       headers={"X-HomeDrive-Device": devices[user]})
            assert r.status_code == 200, r.text
        c.headers["Authorization"] = "Bearer " + r.json()["token"]
        c.headers["X-HomeDrive-Device"] = devices[user]
        return c

    admin = login("max", "pw")
    api = httpx.Client(base_url=base, timeout=60, headers={"X-HomeDrive-Device": devices["max"]})
    return proc, {"settings": None, "files": files, "backup": backup, "admin": admin,
                  "public": public, "login": login, "api": api, "go": True}


@pytest.fixture
def world(tmp_path):
    files, data, backup = tmp_path / "files", tmp_path / "data", tmp_path / "backup"
    for d in (files, data, backup):
        d.mkdir()
    if GO_BINARY:
        proc, w = go_world(tmp_path, files, data, backup)
        yield w
        proc.terminate()
        proc.wait()
        return
    settings = Settings(files_root=files, data_dir=data, username="max", password="pw", secret="s3cret",
                        run_scheduler=False, backup_dir=backup, public_url="https://box.example.ts.net")
    api = TestClient(create_app(settings))
    public = TestClient(create_public_app(settings))

    def login(user, pw):
        c = TestClient(api.app)
        r = c.post("/api/login", json={"username": user, "password": pw})
        assert r.status_code == 200, r.text
        c.headers["Authorization"] = "Bearer " + r.json()["token"]
        return c

    admin = login("max", "pw")
    yield {"settings": settings, "files": files, "backup": backup, "admin": admin,
           "public": public, "login": login, "api": api}


# ---------------------------------------------------------------- accounts

def test_accounts_are_private_but_share_a_folder(world):
    admin, files, login = world["admin"], world["files"], world["login"]
    assert admin.get("/api/me").json()["is_admin"] is True

    r = admin.post("/api/users", json={"username": "Mom", "password": "secret-pw1", "quota_gb": 1})
    assert r.status_code == 200 and r.json()["username"] == "mom"
    assert admin.post("/api/users", json={"username": "mom", "password": "another-pw"}).status_code == 409
    assert admin.post("/api/users", json={"username": "bad name!", "password": "x"}).status_code == 400

    mom = login("mom", "secret-pw1")
    me = mom.get("/api/me").json()
    assert me["is_admin"] is False and me["total"] == 1024 ** 3

    # Mom's drive starts with just the Shared folder.
    assert [e["path"] for e in mom.get("/api/list").json()["entries"]] == ["Shared"]
    mom.post("/api/upload", files=[("files", ("recipes.txt", b"pie"))])
    mom.post("/api/upload", params={"path": "Shared"}, files=[("files", ("family.jpg", b"img"))])

    # It lands in Users/mom and Shared on disk.
    assert (files / "Users" / "mom" / "recipes.txt").read_bytes() == b"pie"
    assert (files / "Shared" / "family.jpg").exists()

    # Admin sees everything; a second user can't see Mom's private files.
    assert admin.get("/api/download", params={"path": "Users/mom/recipes.txt"}).content == b"pie"
    admin.post("/api/users", json={"username": "sam", "password": "sam-pass2"})
    sam = login("sam", "sam-pass2")
    assert sam.get("/api/download", params={"path": "../mom/recipes.txt"}).status_code == 400
    assert sam.get("/api/download", params={"path": "Shared/../../mom/recipes.txt"}).status_code == 400
    assert sam.get("/api/download", params={"path": "Shared/family.jpg"}).content == b"img"
    assert [e["path"] for e in sam.get("/api/search", params={"q": "recipes"}).json()["entries"]] == []

    # Regular users can't use admin endpoints or delete/move the Shared folder.
    assert sam.get("/api/users").status_code == 403
    assert sam.post("/api/delete", json={"path": "Shared"}).status_code == 400
    assert sam.post("/api/move", json={"src": "Shared", "dst": "Mine"}).status_code == 400

    # Deleting from Shared goes to your own trash and restores back to Shared.
    assert sam.post("/api/delete", json={"path": "Shared/family.jpg"}).status_code == 204
    item = sam.get("/api/trash").json()["entries"][0]
    assert item["original"] == "Shared/family.jpg"
    sam.post("/api/trash/restore", json={"name": item["trash_name"]})
    assert (files / "Shared" / "family.jpg").exists()


def test_quota_and_password_reset(world):
    admin, login = world["admin"], world["login"]
    admin.post("/api/users", json={"username": "kid", "password": "kid-pass-a", "quota_gb": 0.000001})  # ~1 KB
    kid = login("kid", "kid-pass-a")
    r = kid.post("/api/upload", files=[("files", ("big.bin", b"x" * 5000))])
    assert r.status_code == 413

    # Resetting the password signs them out everywhere.
    assert admin.post("/api/users/kid/password", json={"password": "kid-pass-b"}).status_code == 204
    assert kid.get("/api/me").status_code == 401
    kid = login("kid", "kid-pass-b")

    # Changing your own password returns a fresh token.
    r = kid.post("/api/me/password", json={"old_password": "nope", "new_password": "kid-pass-c"})
    assert r.status_code == 401
    r = kid.post("/api/me/password", json={"old_password": "kid-pass-b", "new_password": "kid-pass-c"})
    assert r.status_code == 200
    login("kid", "kid-pass-c")

    assert admin.delete("/api/users/max").status_code == 400
    assert admin.delete("/api/users/kid").status_code == 204
    assert world["api"].post("/api/login", json={"username": "kid", "password": "kid-pass-c"}).status_code == 401


# ---------------------------------------------------------------- versions

def test_replace_keeps_versions_and_detects_conflicts(world):
    admin, files = world["admin"], world["files"]
    admin.post("/api/upload", files=[("files", ("essay.txt", b"draft 1"))])
    mtime = admin.get("/api/list").json()["entries"][-1]["modified"]

    r = admin.post("/api/upload", params={"replace": "true", "if_modified": mtime},
                   files=[("files", ("essay.txt", b"draft 2"))])
    assert r.status_code == 200
    assert (files / "essay.txt").read_bytes() == b"draft 2"

    # Someone else's stale copy can't overwrite the newer file.
    r = admin.post("/api/upload", params={"replace": "true", "if_modified": mtime - 100},
                   files=[("files", ("essay.txt", b"stale"))])
    assert r.status_code == 409

    vs = admin.get("/api/versions", params={"path": "essay.txt"}).json()["versions"]
    assert len(vs) == 1 and vs[0]["source"] == "edit"
    old = admin.get("/api/versions/download", params={"path": "essay.txt", "version": vs[0]["id"]})
    assert old.content == b"draft 1"

    # Restoring brings draft 1 back and keeps draft 2 in history.
    assert admin.post("/api/versions/restore", json={"path": "essay.txt", "version": vs[0]["id"]}).status_code == 200
    assert (files / "essay.txt").read_bytes() == b"draft 1"
    assert len(admin.get("/api/versions", params={"path": "essay.txt"}).json()["versions"]) >= 1
    assert admin.get("/api/versions/download", params={"path": "essay.txt", "version": "edit:../../x"}).status_code == 404


# ---------------------------------------------------------------- backups

def test_backups_snapshot_and_restore(world):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    admin, files, backup = world["admin"], world["files"], world["backup"]
    backups = world["api"].app.state.backups
    (files / "notes.txt").write_text("v1")
    os.utime(files / "notes.txt", (time.time() - 500, time.time() - 500))
    (files / "big.bin").write_bytes(b"z" * 10000)

    assert admin.get("/api/backups").json()["enabled"] is True
    assert backups.run() is True
    first = backups.snapshots()[0]
    assert (backup / "snapshots" / first / "notes.txt").read_text() == "v1"

    # Second snapshot: unchanged files are hard links (no extra space).
    time.sleep(1.1)
    (files / "notes.txt").write_text("v2")
    assert backups.run() is True
    second = backups.snapshots()[0]
    assert second != first
    a, b = backup / "snapshots" / first / "big.bin", backup / "snapshots" / second / "big.bin"
    assert a.stat().st_ino == b.stat().st_ino

    vs = admin.get("/api/versions", params={"path": "notes.txt"}).json()["versions"]
    assert [v["source"] for v in vs] == ["backup"]
    admin.post("/api/versions/restore", json={"path": "notes.txt", "version": vs[0]["id"]})
    assert (files / "notes.txt").read_text() == "v1"
    status = admin.get("/api/backups").json()
    assert status["last_error"] is None and len(status["snapshots"]) == 2


def test_backup_retention(tmp_path):
    snaps = tmp_path / "b" / "snapshots"
    now = datetime(2026, 11, 27, 3, 0)
    ages = [0, 1, 2, 6, 8, 9, 15, 16, 23, 40, 70, 75, 100, 200, 400]
    for days in ages:
        (snaps / (now - timedelta(days=days)).strftime(STAMP)).mkdir(parents=True)
    b = Backups(tmp_path, tmp_path / "b", tmp_path, 3)
    b.prune(now)
    kept_ages = sorted((now - datetime.strptime(n, STAMP)).days for n in b.snapshots())
    assert kept_ages[:4] == [0, 1, 2, 6]          # every day this week
    assert 400 not in kept_ages and 200 not in kept_ages
    assert len(kept_ages) < len(ages)


def test_backups_admin_only_and_off_without_folder(world, tmp_path):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    admin, login = world["admin"], world["login"]
    admin.post("/api/users", json={"username": "sam", "password": "sam-pass1"})
    assert login("sam", "sam-pass1").get("/api/backups").status_code == 403
    off = Backups(tmp_path, None, tmp_path)
    assert off.enabled is False and off.run() is False


# ---------------------------------------------------------------- share links

def test_share_link_flow(world):
    admin, public, files = world["admin"], world["public"], world["files"]
    (files / "Trip").mkdir()
    (files / "Trip" / "a.jpg").write_bytes(b"AAA")
    admin.post("/api/upload", files=[("files", ("cv.pdf", b"%PDF-cv"))])

    link = admin.post("/api/shares", json={"path": "cv.pdf", "expires_days": 7}).json()
    assert link["url"].startswith("https://box.example.ts.net/s/")
    token = link["token"]

    page = public.get(f"/s/{token}")
    assert page.status_code == 200 and "cv.pdf" in page.text and "Download" in page.text
    assert "default-src 'none'" in page.headers["content-security-policy"]
    dl = public.get(f"/s/{token}/download")
    assert dl.content == b"%PDF-cv"
    assert admin.get("/api/shares").json()["shares"][0]["downloads"] == 1

    # The public server exposes nothing else.
    # The all-in-one Go server serves the API at the same address, but only to signed-in apps.
    assert public.get("/api/list").status_code in ((401, 404) if world.get("go") else (404,))
    assert public.get("/api/health").status_code in ((200, 404) if world.get("go") else (404,))
    assert public.get("/s/not-a-real-token").status_code == 404

    # Links follow renames, and turning one off kills it.
    admin.post("/api/move", json={"src": "cv.pdf", "dst": "resume.pdf"})
    assert public.get(f"/s/{token}/download").content == b"%PDF-cv"
    assert admin.delete(f"/api/shares/{token}").status_code == 204
    assert public.get(f"/s/{token}").status_code == 404

    # Folder links download as a zip.
    folder = admin.post("/api/shares", json={"path": "Trip"}).json()
    z = zipfile.ZipFile(io.BytesIO(public.get(f"/s/{folder['token']}/download").content))
    assert z.namelist() == ["Trip/a.jpg"]


def test_share_link_password_and_expiry(world):
    admin, public, files = world["admin"], world["public"], world["files"]
    (files / "secret.txt").write_text("shh")
    link = admin.post("/api/shares", json={"path": "secret.txt", "password": "open sesame"}).json()
    t = link["token"]

    assert "Password" in public.get(f"/s/{t}").text
    assert "shh" not in public.get(f"/s/{t}/download").text       # no password, no file
    wrong = public.post(f"/s/{t}", data={"password": "nope"})
    assert "That password isn" in wrong.text and "t right" in wrong.text
    right = public.post(f"/s/{t}", data={"password": "open sesame"})
    href = right.text.split('href="')[1].split('"')[0].replace("&amp;", "&")
    assert public.get(href).text == "shh"

    # Brute force gets locked out.
    for _ in range(11):
        r = public.post(f"/s/{t}", data={"password": "guess"})
    assert "Too many wrong tries" in r.text
    # Even the right password waits until the pause is over.
    assert "Too many wrong tries" in public.post(f"/s/{t}", data={"password": "open sesame"}).text

    # Expired links are dead.
    if world.get("go"):
        return   # (needs the Python server's internals to make an already-expired link)
    links = world["api"].app.state.links
    expired = links.add("max", True, "secret.txt", False, time.time() - 1, None)
    assert public.get(f"/s/{expired.token}").status_code == 404


def test_links_off_without_public_url(tmp_path):
    files, data = tmp_path / "f", tmp_path / "d"
    files.mkdir(); data.mkdir()
    s = Settings(files_root=files, data_dir=data, username="max", password="pw", secret="x", run_scheduler=False)
    c = TestClient(create_app(s))
    c.headers["Authorization"] = "Bearer " + c.post("/api/login", json={"username": "max", "password": "pw"}).json()["token"]
    (files / "a.txt").write_text("a")
    link = c.post("/api/shares", json={"path": "a.txt"}).json()
    assert link["url"] is None
    assert c.get("/api/shares").json()["links_enabled"] is False


def test_tree_for_offline(world):
    admin, files = world["admin"], world["files"]
    (files / "School" / "ECE").mkdir(parents=True)
    (files / "School" / "ECE" / "hw1.pdf").write_text("1")
    (files / "School" / "notes.md").write_text("n")
    (files / "School" / ".DS_Store").write_text("junk")
    paths = sorted(e["path"] for e in admin.get("/api/tree", params={"path": "School"}).json()["entries"])
    assert paths == ["School/ECE/hw1.pdf", "School/notes.md"]


def test_links_switch_requests(world):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    admin, login, settings = world["admin"], world["login"], world["settings"]
    agent = settings.data_dir / "agent"

    st = admin.get("/api/admin/links").json()
    assert st["enabled"] is True and st["agent_installed"] is False
    # Without the server helper installed, the app is told how to install it.
    r = admin.post("/api/admin/links", json={"enabled": False})
    assert r.status_code == 409 and "install-agent" in r.json()["detail"]

    agent.mkdir(parents=True, exist_ok=True)
    (agent / "installed").write_text("1")
    r = admin.post("/api/admin/links", json={"enabled": False})
    assert r.status_code == 200 and r.json()["state"] == "working"
    import json as _json
    assert _json.loads((agent / "request.json").read_text())["action"] == "links-off"

    # The helper reports back through status.json.
    (agent / "request.json").unlink()
    (agent / "status.json").write_text(_json.dumps({"state": "needs_approval", "message": "Approve it",
                                                     "approve_url": "https://login.tailscale.com/f/funnel?x=1"}))
    st = admin.get("/api/admin/links").json()
    assert st["state"] == "needs_approval" and st["approve_url"].startswith("https://login.tailscale.com/")

    admin.post("/api/users", json={"username": "sam", "password": "sam-pass1"})
    assert login("sam", "sam-pass1").post("/api/admin/links", json={"enabled": True}).status_code == 403
