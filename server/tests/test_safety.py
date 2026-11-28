import pytest
"""Safety release: locked-down share-link server, login lockout, guards, download log."""

import sqlite3
import time

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.public import create_public_app
from test_v05 import world  # noqa: F401  (pytest fixture)


def test_public_server_runs_on_files_and_links_folder_only(world, tmp_path, monkeypatch):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    admin, files, settings = world["admin"], world["files"], world["settings"]
    (files / "a.txt").write_text("hello")
    link = admin.post("/api/shares", json={"path": "a.txt"}).json()

    # Started the real way: two environment variables, no admin password, no main data folder.
    for var in ("HOMEDRIVE_PASSWORD", "HOMEDRIVE_SECRET", "HOMEDRIVE_DATA", "HOMEDRIVE_USERNAME"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("HOMEDRIVE_FILES", str(files))
    monkeypatch.setenv("HOMEDRIVE_LINKS_DATA", str(settings.data_dir / "links"))
    public = TestClient(create_public_app())
    assert public.get(f"/s/{link['token']}/download").content == b"hello"

    # The links folder holds nothing that could be used to sign in.
    names = {p.name for p in (settings.data_dir / "links").iterdir()}
    assert "homedrive.db" not in names and "secret.key" not in names
    db = sqlite3.connect(settings.data_dir / "links" / "links.db")
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert tables == {"shares", "downloads", "failures"}   # no users table


def test_old_links_move_to_the_links_database(tmp_path):
    files, data = tmp_path / "files", tmp_path / "data"
    files.mkdir(), data.mkdir()
    (files / "old.txt").write_text("still works")
    s = Settings(files_root=files, data_dir=data, username="max", password="pw", secret="s", run_scheduler=False)
    create_app(s)
    # A link saved by an older server, in the main database.
    db = sqlite3.connect(data / "homedrive.db")
    db.execute("INSERT INTO shares (token, owner, path, is_dir, created) VALUES ('oldtoken123', 'max', 'old.txt', 0, ?)",
               (time.time(),))
    db.commit()
    create_app(s)   # next start moves it
    assert db.execute("SELECT COUNT(*) FROM shares").fetchone()[0] == 0
    assert TestClient(create_public_app(s)).get("/s/oldtoken123/download").content == b"still works"


def test_download_log(world):
    admin, public, files = world["admin"], world["public"], world["files"]
    (files / "a.txt").write_text("x")
    t = admin.post("/api/shares", json={"path": "a.txt"}).json()["token"]
    public.get(f"/s/{t}/download", headers={"x-forwarded-for": "198.51.100.9"})
    sh = admin.get("/api/shares").json()["shares"][0]
    assert sh["downloads"] == 1
    assert sh["recent_downloads"][0]["ip"] == "198.51.100.9"


def test_deleting_a_user_kills_their_links(world):
    admin, public, login = world["admin"], world["public"], world["login"]
    admin.post("/api/users", json={"username": "sam", "password": "sam-pass1"})
    sam = login("sam", "sam-pass1")
    sam.post("/api/upload", files=[("files", ("s.txt", b"sam's"))])
    t = sam.post("/api/shares", json={"path": "s.txt"}).json()["token"]
    assert public.get(f"/s/{t}/download").content == b"sam's"
    admin.delete("/api/users/sam")
    assert public.get(f"/s/{t}").status_code == 404


def test_login_lockout(world):
    api = world["api"]
    for _ in range(10):
        assert api.post("/api/login", json={"username": "max", "password": "nope"}).status_code == 401
    r = api.post("/api/login", json={"username": "max", "password": "pw"})
    assert r.status_code == 429 and "paused" in r.json()["detail"]


def test_password_rules(world):
    # Short passwords are allowed (the app warns about them); empty ones aren't.
    admin = world["admin"]
    assert admin.post("/api/users", json={"username": "shorty", "password": "1234"}).status_code == 200
    assert admin.post("/api/users", json={"username": "empty", "password": ""}).status_code == 400
    assert admin.post("/api/users/shorty/password", json={"password": ""}).status_code == 400
    world["files"].joinpath("f.txt").write_text("x")
    assert admin.post("/api/shares", json={"path": "f.txt", "password": "ab"}).status_code == 200


def test_link_pauses_after_ten_wrong_passwords_then_reopens(world):
    import app.links_db as ldb
    admin, public, files = world["admin"], world["public"], world["files"]
    files.joinpath("s.txt").write_text("secret")
    link = admin.post("/api/shares", json={"path": "s.txt", "password": "right-one"}).json()
    t = link["token"]
    for i in range(10):   # ten different visitors, one guess each
        r = public.post(f"/s/{t}", data={"password": "nope"}, headers={"x-forwarded-for": f"203.0.113.{i}"})
        assert "isn" in r.text and "t right" in r.text
    r = public.post(f"/s/{t}", data={"password": "right-one"}, headers={"x-forwarded-for": "198.51.100.1"})
    assert "Too many wrong tries" in r.text
    # The app shows the link is paused, and until when.
    assert admin.get("/api/shares").json()["shares"][0]["locked_until"] > time.time()
    # 15 minutes later it opens again by itself.
    if world.get("go"):
        return   # (can't wind the clock forward inside the Go server)
    links = world["api"].app.state.links
    with links.lock:
        links.conn.execute("UPDATE failures SET time = time - ?", (ldb.LINK_LOCK_SECONDS + 1,))
    r = public.post(f"/s/{t}", data={"password": "right-one"}, headers={"x-forwarded-for": "198.51.100.1"})
    assert "Download" in r.text and "Too many" not in r.text


def test_upload_stops_before_the_disk_is_full(world):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    admin, settings = world["admin"], world["settings"]
    settings.min_free_bytes = 10 ** 18   # pretend the disk is nearly full
    r = admin.post("/api/upload", files=[("files", ("a.txt", b"x"))])
    assert r.status_code == 507 and "almost full" in r.json()["detail"]


def test_successful_login_resets_the_count(world):
    api = world["api"]
    for _ in range(9):
        api.post("/api/login", json={"username": "max", "password": "nope"})
    assert api.post("/api/login", json={"username": "max", "password": "pw"}).status_code == 200
    for _ in range(9):
        api.post("/api/login", json={"username": "max", "password": "nope"})
    assert api.post("/api/login", json={"username": "max", "password": "pw"}).status_code == 200


def test_old_trash_and_versions_are_cleaned_up(world):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    import json
    import os
    admin, files = world["admin"], world["files"]
    app = world["api"].app
    for name in ("old.txt", "new.txt"):
        admin.post("/api/upload", files=[("files", (name, b"v1"))])
        admin.post("/api/delete", json={"path": name})
    # Pretend old.txt was deleted 31 days ago.
    index_file = files / ".trash" / ".index.json"
    index = json.loads(index_file.read_text())
    index["old.txt"]["deleted"] -= 31 * 86400
    index_file.write_text(json.dumps(index))

    # An edit makes a version; pretend it was saved 31 days ago.
    admin.post("/api/upload", files=[("files", ("doc.txt", b"one"))])
    admin.post("/api/upload", params={"replace": "true"}, files=[("files", ("doc.txt", b"two"))])
    vdir = next(d for d in (world["settings"].data_dir / "versions").iterdir() if d.is_dir())
    meta = json.loads((vdir / "meta.json").read_text())
    for m in meta.values():
        m["saved"] -= 31 * 86400
    (vdir / "meta.json").write_text(json.dumps(meta))

    result = app.state.clean_up_old()
    assert result == {"trash": 1, "versions": 1}
    names = {e["name"] for e in admin.get("/api/trash").json()["entries"]}
    assert names == {"new.txt"}
    assert admin.get("/api/versions", params={"path": "doc.txt"}).json()["versions"] == [] or \
        all(v["source"] != "edit" for v in admin.get("/api/versions", params={"path": "doc.txt"}).json()["versions"])
    assert admin.get("/api/me").json()["cleanup_days"] == 30
    assert os.path.exists(files / "doc.txt")


def test_odd_file_names(world):
    admin = world["admin"]
    for name in (" leading space.txt", "trailing space .txt", "emoji 🎉.txt", "é.txt", "%20 # ?.txt"):
        r = admin.post("/api/upload", files=[("files", (name, name.encode()))])
        assert r.status_code == 200, r.text
        path = r.json()["saved"][0]["path"]
        assert admin.get("/api/download", params={"path": path}).content == name.encode(), name
        assert admin.post("/api/move", json={"src": path, "dst": "Odd/" + path}).status_code == 200


def test_recent_drops_deleted_files_right_away(world):
    admin = world["admin"]
    admin.post("/api/upload", files=[("files", ("a.txt", b"a"))])
    assert [e["name"] for e in admin.get("/api/recent").json()["entries"]] == ["a.txt"]
    admin.post("/api/delete", json={"path": "a.txt"})
    assert admin.get("/api/recent").json()["entries"] == []


def test_quick_successive_saves_are_still_told_apart(world, monkeypatch):
    if world.get("go"):
        pytest.skip("checks the Python server's internals")
    # Simulate a file system with coarse timestamps: every write gets the same time.
    admin, files = world["admin"], world["files"]
    first = admin.post("/api/upload", files=[("files", ("n.txt", b"one"))]).json()["saved"][0]
    real_replace = type(files).replace

    def same_time_replace(self, target):
        out = real_replace(self, target)
        os.utime(target, (first["modified"], first["modified"]))
        return out
    import os
    monkeypatch.setattr(type(files), "replace", same_time_replace)
    second = admin.post("/api/upload", params={"replace": "true", "if_modified": first["modified"]},
                        files=[("files", ("n.txt", b"two"))])
    assert second.status_code == 200 and second.json()["saved"][0]["modified"] > first["modified"]
    stale = admin.post("/api/upload", params={"replace": "true", "if_modified": first["modified"]},
                       files=[("files", ("n.txt", b"three"))])
    assert stale.status_code == 409


def test_quota_cant_be_dodged_with_a_missing_or_wrong_size(world):
    import httpx
    admin, login = world["admin"], world["login"]
    admin.post("/api/users", json={"username": "kid", "password": "kid-pass-a", "quota_gb": 0.000001})  # ~1 KB
    kid = login("kid", "kid-pass-a")
    body = (b"--b\r\nContent-Disposition: form-data; name=\"files\"; filename=\"big.bin\"\r\n\r\n"
            + b"x" * 50_000 + b"\r\n--b--\r\n")

    def chunked():   # no Content-Length at all
        for i in range(0, len(body), 4096):
            yield body[i:i + 4096]
    r = kid.post("/api/upload", content=chunked(), headers={"Content-Type": "multipart/form-data; boundary=b"})
    assert r.status_code == 413
    r = kid.post("/api/upload", content=body, headers={"Content-Type": "multipart/form-data; boundary=b",
                                                       "Content-Length": str(len(body))})
    assert r.status_code == 413
    files = world["files"] / "Users" / "kid"
    assert not [p for p in files.iterdir() if p.is_file()]
    assert httpx  # imported for the test client


def test_managed_folders_and_bad_names_are_blocked(world):
    admin = world["admin"]
    admin.post("/api/upload", files=[("files", ("a.txt", b"a"))])
    for path in (".trash", ".trash/x", ".upload-tmp", "Docs/.trash/x"):
        assert admin.get("/api/list", params={"path": path}).status_code == 400, path
        assert admin.post("/api/mkdir", json={"path": path}).status_code == 400, path
    assert admin.post("/api/move", json={"src": "a.txt", "dst": ".trash/a.txt"}).status_code == 400
    assert admin.post("/api/move", json={"src": "a.txt", "dst": ".upload-tmp/a.txt"}).status_code == 400
    for bad in (b"bell\x07.txt", b"tab\x09.txt", b"del\x7f.txt", b".trash"):
        # Sent raw, the way a hostile client would (normal clients escape these).
        body = b'--b\r\nContent-Disposition: form-data; name="files"; filename="' + bad + b'"\r\n\r\nx\r\n--b--\r\n'
        r = admin.post("/api/upload", content=body, headers={"Content-Type": "multipart/form-data; boundary=b"})
        assert r.status_code == 400, bad
    assert admin.post("/api/mkdir", json={"path": "new\nline"}).status_code == 400
    assert admin.get("/api/download", params={"path": "a\x00.txt"}).status_code == 400
    assert admin.post("/api/upload", files=[("files", ("x" * 300 + ".txt", b"x"))]).status_code == 400
