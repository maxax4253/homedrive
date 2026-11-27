import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app


@pytest.fixture
def env(tmp_path):
    files = tmp_path / "files"
    data = tmp_path / "data"
    files.mkdir()
    data.mkdir()
    settings = Settings(files_root=files, data_dir=data, username="max", password="pw", secret="s3cret",
                        run_scheduler=False)
    client = TestClient(create_app(settings))
    token = client.post("/api/login", json={"username": "max", "password": "pw"}).json()["token"]
    client.headers["Authorization"] = f"Bearer {token}"
    return client, files


def test_login_rejects_bad_password(env):
    client, _ = env
    r = client.post("/api/login", json={"username": "max", "password": "nope"})
    assert r.status_code == 401


def test_requires_auth(env):
    client, _ = env
    r = client.get("/api/list", headers={"Authorization": "Bearer garbage"})
    assert r.status_code == 401


def test_upload_list_download(env):
    client, files = env
    r = client.post("/api/upload", files=[("files", ("hello.txt", b"hi there"))])
    assert r.status_code == 200
    names = [e["name"] for e in client.get("/api/list").json()["entries"] if not e["is_dir"]]
    assert names == ["hello.txt"]
    assert client.get("/api/download", params={"path": "hello.txt"}).content == b"hi there"


def test_upload_name_conflict(env):
    client, files = env
    client.post("/api/upload", files=[("files", ("a.txt", b"1"))])
    client.post("/api/upload", files=[("files", ("a.txt", b"2"))])
    names = sorted(e["name"] for e in client.get("/api/list").json()["entries"] if not e["is_dir"])
    assert names == ["a (1).txt", "a.txt"]


def test_folders_sorted_first_and_hidden_skipped(env):
    client, files = env
    (files / "zz.txt").write_text("x")
    (files / "Aaa").mkdir()
    (files / ".secret").write_text("x")
    names = [e["name"] for e in client.get("/api/list").json()["entries"]]
    assert names == ["Aaa", "Shared", "zz.txt"]


def test_path_traversal_blocked(env):
    client, _ = env
    assert client.get("/api/list", params={"path": "../.."}).status_code == 400
    assert client.get("/api/download", params={"path": "../data/secret.key"}).status_code == 400
    r = client.post("/api/upload", files=[("files", ("../../evil.txt", b"x"))])
    assert r.status_code == 200
    assert r.json()["saved"][0]["path"] == "evil.txt"


def test_mkdir_move_delete(env):
    client, files = env
    assert client.post("/api/mkdir", json={"path": "Docs"}).status_code == 200
    assert client.post("/api/mkdir", json={"path": "Docs"}).status_code == 409
    client.post("/api/upload", params={"path": "Docs"}, files=[("files", ("n.txt", b"x"))])
    r = client.post("/api/move", json={"src": "Docs/n.txt", "dst": "Docs/notes.txt"})
    assert r.status_code == 200 and r.json()["name"] == "notes.txt"
    assert client.post("/api/move", json={"src": "Docs", "dst": "Docs/inner"}).status_code == 400
    assert client.post("/api/delete", json={"path": "Docs/notes.txt"}).status_code == 204
    assert not (files / "Docs" / "notes.txt").exists()
    assert (files / ".trash" / "notes.txt").exists()
    assert client.post("/api/delete", json={"path": ""}).status_code == 400


def test_trash_restore_delete_empty(env):
    client, files = env
    client.post("/api/mkdir", json={"path": "Docs"})
    client.post("/api/upload", params={"path": "Docs"}, files=[("files", ("a.txt", b"a"))])
    client.post("/api/upload", files=[("files", ("b.txt", b"b"))])
    client.post("/api/delete", json={"path": "Docs/a.txt"})
    client.post("/api/delete", json={"path": "b.txt"})

    items = client.get("/api/trash").json()["entries"]
    assert {i["trash_name"] for i in items} == {"a.txt", "b.txt"}
    assert {i["original"] for i in items} == {"Docs/a.txt", "b.txt"}

    # Restore puts it back where it came from, even if the folder is gone.
    client.post("/api/delete", json={"path": "Docs"})
    r = client.post("/api/trash/restore", json={"name": "a.txt"})
    assert r.status_code == 200 and r.json()["path"] == "Docs/a.txt"
    assert (files / "Docs" / "a.txt").read_text() == "a"

    assert client.post("/api/trash/delete", json={"name": "b.txt"}).status_code == 204
    # "../x" is reduced to "x" inside the trash, so it can't escape.
    assert client.post("/api/trash/delete", json={"name": "../x"}).status_code == 404
    assert client.post("/api/trash/empty").json()["deleted"] == 1  # the Docs folder
    assert client.get("/api/trash").json()["entries"] == []


def test_recent_and_search(env):
    client, files = env
    import os
    import time

    (files / "Photos" / "2024").mkdir(parents=True)
    old = files / "Photos" / "2024" / "beach.jpg"
    old.write_text("x")
    os.utime(old, (time.time() - 1000, time.time() - 1000))
    (files / "notes.txt").write_text("x")
    (files / ".trash").mkdir()
    (files / ".trash" / "beach-old.jpg").write_text("x")

    recent = [e["path"] for e in client.get("/api/recent").json()["entries"]]
    assert recent == ["notes.txt", "Photos/2024/beach.jpg"]

    found = [e["path"] for e in client.get("/api/search", params={"q": "BEACH"}).json()["entries"]]
    assert found == ["Photos/2024/beach.jpg"]
    found = [e["path"] for e in client.get("/api/search", params={"q": "20"}).json()["entries"]]
    assert found == ["Photos/2024"]


def test_thumbnail(env):
    client, files = env
    buf = io.BytesIO()
    Image.new("RGB", (800, 400), "red").save(buf, "PNG")
    client.post("/api/upload", files=[("files", ("pic.png", buf.getvalue()))])
    r = client.get("/api/thumbnail", params={"path": "pic.png", "size": 128})
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    img = Image.open(io.BytesIO(r.content))
    assert max(img.size) == 128
    client.post("/api/upload", files=[("files", ("doc.txt", b"x"))])
    assert client.get("/api/thumbnail", params={"path": "doc.txt"}).status_code == 415


def test_me_reports_space(env):
    client, _ = env
    body = client.get("/api/me").json()
    assert body["username"] == "max" and body["free"] > 0


def test_zip_folder_and_multi(env):
    import zipfile

    client, files = env
    (files / "Trip" / "day1").mkdir(parents=True)
    (files / "Trip" / "day1" / "a.jpg").write_bytes(b"A" * 3000)
    (files / "Trip" / "notes.txt").write_text("hi")
    (files / "Trip" / ".DS_Store").write_text("junk")
    (files / "solo.txt").write_text("solo")

    r = client.get("/api/zip", params={"path": "Trip"})
    assert r.status_code == 200
    assert "Trip.zip" in r.headers["content-disposition"]
    z = zipfile.ZipFile(io.BytesIO(r.content))
    assert sorted(z.namelist()) == ["Trip/day1/a.jpg", "Trip/notes.txt"]
    assert z.read("Trip/day1/a.jpg") == b"A" * 3000

    r = client.get("/api/zip", params=[("path", "Trip/notes.txt"), ("path", "solo.txt")])
    z = zipfile.ZipFile(io.BytesIO(r.content))
    assert sorted(z.namelist()) == ["notes.txt", "solo.txt"]

    assert client.get("/api/zip", params={"path": ""}).status_code == 400
    assert client.get("/api/zip", params={"path": "../x"}).status_code == 400


def test_starred(env):
    client, files = env
    (files / "Docs").mkdir()
    (files / "Docs" / "cv.pdf").write_text("x")

    assert client.post("/api/star", json={"path": "Docs/cv.pdf"}).status_code == 200
    listed = client.get("/api/list", params={"path": "Docs"}).json()["entries"]
    assert listed[0]["starred"] is True
    assert [e["path"] for e in client.get("/api/starred").json()["entries"]] == ["Docs/cv.pdf"]

    # Stars follow renames of the file and of folders above it.
    client.post("/api/move", json={"src": "Docs", "dst": "Papers"})
    assert [e["path"] for e in client.get("/api/starred").json()["entries"]] == ["Papers/cv.pdf"]

    client.post("/api/star", json={"path": "Papers/cv.pdf", "starred": False})
    assert client.get("/api/starred").json()["entries"] == []
    assert client.post("/api/star", json={"path": "nope.txt"}).status_code == 404


def test_upload_returns_sha256(env):
    import hashlib

    client, files = env
    data = b"offload me" * 10000
    r = client.post("/api/upload", files=[("files", ("big.bin", data))])
    saved = r.json()["saved"][0]
    assert saved["sha256"] == hashlib.sha256(data).hexdigest()
    assert saved["size"] == len(data)
    h = client.get("/api/hash", params={"path": "big.bin"}).json()
    assert h["sha256"] == saved["sha256"]
    assert not any(p.name.startswith(".upload-") for p in files.iterdir())
