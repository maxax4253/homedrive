"""Safety release: locked-down share-link server, login lockout, guards, download log."""

import sqlite3
import time

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.public import create_public_app
from test_v05 import world  # noqa: F401  (pytest fixture)


def test_public_server_runs_on_files_and_links_folder_only(world, tmp_path, monkeypatch):
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
    assert tables == {"shares", "downloads"}


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
    admin = world["admin"]
    r = admin.post("/api/users", json={"username": "shorty", "password": "1234567"})
    assert r.status_code == 400 and "8 characters" in r.json()["detail"]
    assert admin.post("/api/users", json={"username": "okay", "password": "12345678"}).status_code == 200
    assert admin.post("/api/users/okay/password", json={"password": "short"}).status_code == 400
    world["files"].joinpath("f.txt").write_text("x")
    r = admin.post("/api/shares", json={"path": "f.txt", "password": "ab"})
    assert r.status_code == 400


def test_upload_stops_before_the_disk_is_full(world):
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
