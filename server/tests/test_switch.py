"""`homedrive switch`: the old server's data copied into the new server's format.

Fills an old (Python) server, runs tools/move_to_new_server.py, and checks the
result. With HD_GO_BINARY set (as in CI) it also starts the new server on the
copied data and signs in, reads files and history, and opens the old share link.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.public import create_public_app

MOVER = Path(__file__).resolve().parent.parent / "tools" / "move_to_new_server.py"
GO_BINARY = os.environ.get("HD_GO_BINARY")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def old(tmp_path):
    files, data = tmp_path / "files", tmp_path / "old-data"
    files.mkdir()
    data.mkdir()
    settings = Settings(files_root=files, data_dir=data, username="max", password="old-admin-pw", secret="s3cret",
                        run_scheduler=False, public_url="https://box.example.ts.net")
    api = TestClient(create_app(settings))
    public = TestClient(create_public_app(settings))

    def login(user, pw):
        c = TestClient(api.app)
        c.headers["Authorization"] = "Bearer " + c.post("/api/login", json={"username": user, "password": pw}).json()["token"]
        return c

    admin = login("max", "old-admin-pw")
    assert admin.post("/api/mkdir", json={"path": "Docs"}).status_code == 200
    admin.post("/api/upload", params={"path": "Docs"}, files={"files": ("notes.txt", b"version one")})
    time.sleep(0.01)
    assert admin.post("/api/upload", params={"path": "Docs", "replace": "true"},
                      files={"files": ("notes.txt", b"version two!")}).status_code == 200
    admin.post("/api/star", json={"path": "Docs/notes.txt", "starred": True})
    admin.post("/api/users", json={"username": "mom", "password": "mom-old-pw", "quota_gb": 2})
    mom = login("mom", "mom-old-pw")
    mom.post("/api/upload", params={"path": ""}, files={"files": ("mom.txt", b"hi from mom")})
    link = admin.post("/api/shares", json={"path": "Docs/notes.txt", "password": "linkpw"}).json()
    r = public.post(f"/s/{link['token']}", data={"password": "linkpw"}, follow_redirects=True)
    key = re.search(r'download\?k=([^"&]+)', r.text).group(1)
    assert public.get(f"/s/{link['token']}/download", params={"k": key}).content == b"version two!"
    return {"files": files, "data": data, "link": link["token"], "tmp": tmp_path}


def move(old, new):
    env = dict(os.environ, HD_OLD_FILES_PATH=str(old["files"]))
    return subprocess.run([sys.executable, str(MOVER), str(old["data"]), str(new), str(old["files"]), "max"],
                          capture_output=True, text=True, env=env)


def test_data_is_copied_in_the_new_format(old):
    new = old["tmp"] / "new-data"
    r = move(old, new)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "2 accounts, 1 share links" in r.stdout

    users = json.loads((new / "users.json").read_text())
    assert users["max"]["is_admin"] and not users["mom"]["is_admin"]
    assert users["mom"]["quota_bytes"] == 2 * 1024 ** 3
    assert users["max"]["pw_hash"].startswith("scrypt$")
    links = json.loads((new / "links" / "links.json").read_text())
    s = links[old["link"]]
    assert s["downloads"] == 1 and len(s["log"]) == 1 and s["pw_hash"] and not s["revoked"]
    assert (new / "links" / "links.key").read_bytes() == (old["data"] / "links" / "links.key").read_bytes()
    if (old["data"] / "secret.key").exists():  # (this test's old server got its secret directly)
        assert (new / "secret.key").read_text() == (old["data"] / "secret.key").read_text()
    assert json.loads((new / "stars.json").read_text()) == ["Docs/notes.txt"]
    assert len(list((new / "versions").iterdir())) == 1
    app_settings = json.loads((new / "app.json").read_text())
    assert app_settings["files_root"] == str(old["files"].resolve()) and app_settings["username"] == "max"
    for f in ("users.json", "app.json", "links/links.key"):
        assert oct((new / f).stat().st_mode & 0o777) == "0o600", f

    # The old data is untouched, and it won't copy over existing new data.
    assert (old["data"] / "homedrive.db").is_file()
    again = move(old, new)
    assert again.returncode == 1 and "already has" in again.stdout


@pytest.mark.skipif(not GO_BINARY, reason="needs the new server (HD_GO_BINARY)")
def test_new_server_runs_on_the_copied_data(old):
    new = old["tmp"] / "new-data"
    assert move(old, new).returncode == 0
    port, pub = free_port(), free_port()
    proc = subprocess.Popen([GO_BINARY, "app", "-no-tray", "-data", str(new), "-listen", f"127.0.0.1:{port}",
                             "-public-listen", f"127.0.0.1:{pub}"],
                            env=dict(os.environ, HOME=str(old["tmp"])), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        base = f"http://127.0.0.1:{port}"
        for _ in range(50):
            try:
                if httpx.get(base + "/api/health").status_code == 200:
                    break
            except httpx.HTTPError:
                pass
            time.sleep(0.2)

        def pair(user, pw):
            code = subprocess.run([GO_BINARY, "pair-code", "-data", str(new), "-user", user],
                                  capture_output=True, text=True, check=True).stdout.strip()
            c = httpx.Client(base_url=base)
            r = c.post("/api/pair", json={"code": code, "username": user, "password": pw, "device_name": "t"})
            assert r.status_code == 200, r.text
            c.headers.update({"Authorization": "Bearer " + r.json()["token"], "X-HomeDrive-Device": r.json()["device_key"]})
            return c

        max_ = pair("max", "old-admin-pw")   # same password as before
        assert max_.get("/api/download", params={"path": "Docs/notes.txt"}).content == b"version two!"
        v = max_.get("/api/versions", params={"path": "Docs/notes.txt"}).json()["versions"]
        assert max_.get("/api/versions/download", params={"path": "Docs/notes.txt", "version": v[0]["id"]}).content == b"version one"
        assert [e["path"] for e in max_.get("/api/starred").json()["entries"]] == ["Docs/notes.txt"]
        mom = pair("mom", "mom-old-pw")
        assert [e["name"] for e in mom.get("/api/list").json()["entries"]] == ["Shared", "mom.txt"]
        assert mom.get("/api/list", params={"path": "Docs"}).status_code == 404

        # The old share link, on the share-link address (where Tailscale Funnel points).
        p = httpx.Client(base_url=f"http://127.0.0.1:{pub}", follow_redirects=True)
        assert "isn&#39;t right" in p.post(f"/s/{old['link']}", data={"password": "nope"}).text
        r = p.post(f"/s/{old['link']}", data={"password": "linkpw"})
        key = re.search(r'download\?k=([^"&]+)', r.text).group(1)
        assert p.get(f"/s/{old['link']}/download", params={"k": key}).content == b"version two!"
        assert p.get("/api/list").status_code == 404 and p.get("/app/").status_code == 404
    finally:
        proc.terminate()
        proc.wait()
