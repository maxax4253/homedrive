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
    settings = Settings(files_root=files, data_dir=data, username="max", password="pw", secret="s3cret")
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
    names = [e["name"] for e in client.get("/api/list").json()["entries"]]
    assert names == ["hello.txt"]
    assert client.get("/api/download", params={"path": "hello.txt"}).content == b"hi there"


def test_upload_name_conflict(env):
    client, files = env
    client.post("/api/upload", files=[("files", ("a.txt", b"1"))])
    client.post("/api/upload", files=[("files", ("a.txt", b"2"))])
    names = sorted(e["name"] for e in client.get("/api/list").json()["entries"])
    assert names == ["a (1).txt", "a.txt"]


def test_folders_sorted_first_and_hidden_skipped(env):
    client, files = env
    (files / "zz.txt").write_text("x")
    (files / "Aaa").mkdir()
    (files / ".secret").write_text("x")
    names = [e["name"] for e in client.get("/api/list").json()["entries"]]
    assert names == ["Aaa", "zz.txt"]


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
