"""Regression tests for fixes from the full code review."""

import io
import zipfile

from test_v05 import world  # noqa: F401  (pytest fixture)


def test_zip_skips_symlinks_out_of_the_drive(world, tmp_path):
    admin, public, files = world["admin"], world["public"], world["files"]
    outside = tmp_path / "outside.txt"
    outside.write_text("private")
    (files / "Pics").mkdir()
    (files / "Pics" / "a.jpg").write_bytes(b"A")
    (files / "Pics" / "sneaky.txt").symlink_to(outside)
    (files / "Pics" / "sneakydir").symlink_to(tmp_path)

    z = zipfile.ZipFile(io.BytesIO(admin.get("/api/zip", params={"path": "Pics"}).content))
    assert z.namelist() == ["Pics/a.jpg"]

    link = admin.post("/api/shares", json={"path": "Pics"}).json()
    page = public.get(f"/s/{link['token']}")
    assert "1 file " in page.text
    z = zipfile.ZipFile(io.BytesIO(public.get(f"/s/{link['token']}/download").content))
    assert z.namelist() == ["Pics/a.jpg"]


def test_faked_forwarded_for_does_not_dodge_the_lockout(world):
    admin, public, files = world["admin"], world["public"], world["files"]
    (files / "s.txt").write_text("x")
    t = admin.post("/api/shares", json={"path": "s.txt", "password": "right"}).json()["token"]
    for i in range(11):
        # A visitor rotating the first X-Forwarded-For entry; Funnel adds the real one last.
        r = public.post(f"/s/{t}", data={"password": "guess"},
                        headers={"x-forwarded-for": f"10.0.0.{i}, 203.0.113.7"})
    assert "Too many wrong tries" in r.text


def test_link_wide_lockout_across_many_addresses(world):
    admin, public, files = world["admin"], world["public"], world["files"]
    (files / "s.txt").write_text("x")
    t = admin.post("/api/shares", json={"path": "s.txt", "password": "right"}).json()["token"]
    for i in range(11):
        r = public.post(f"/s/{t}", data={"password": "guess"}, headers={"x-forwarded-for": f"198.51.100.{i}"})
    assert "Too many wrong tries" in r.text


def test_failed_upload_leaves_no_temp_file(world, monkeypatch):
    admin, files = world["admin"], world["files"]
    import app.main as main

    def boom(*a, **k):
        raise OSError("disk full")

    monkeypatch.setattr(main.os, "fsync", boom)
    try:
        admin.post("/api/upload", files=[("files", ("a.txt", b"hello"))])
    except OSError:
        pass
    assert not [p for p in files.iterdir() if p.name.startswith(".upload-") and p.is_file()]
    assert not (files / "a.txt").exists()


def test_stars_survive_concurrent_sessions(world):
    admin, files = world["admin"], world["files"]
    (files / "a.txt").write_text("a")
    (files / "b.txt").write_text("b")
    other = world["login"]("max", "pw")
    admin.post("/api/star", json={"path": "a.txt"})
    other.post("/api/star", json={"path": "b.txt"})
    names = {e["name"] for e in admin.get("/api/starred").json()["entries"]}
    assert names == {"a.txt", "b.txt"}


def test_restored_version_gets_a_new_modified_time(world):
    admin = world["admin"]
    admin.post("/api/upload", files=[("files", ("n.txt", b"one"))])
    first = admin.get("/api/list").json()["entries"][0]["modified"]
    admin.post("/api/upload", params={"replace": "true"}, files=[("files", ("n.txt", b"two"))])
    v = [x for x in admin.get("/api/versions", params={"path": "n.txt"}).json()["versions"] if x["source"] == "edit"][0]
    restored = admin.post("/api/versions/restore", json={"path": "n.txt", "version": v["id"]}).json()
    assert restored["modified"] >= first
    assert admin.get("/api/download", params={"path": "n.txt"}).content == b"one"


def test_me_reports_homedrive_usage_separately(world):
    admin = world["admin"]
    admin.post("/api/upload", files=[("files", ("a.bin", b"x" * 5000))])
    me = admin.get("/api/me").json()
    assert me["scope"] == "disk" and me["drive_used"] >= 5000
    assert me["used"] >= me["drive_used"]           # whole disk includes everything else


def test_server_update_request(world):
    import json
    admin, login, settings = world["admin"], world["login"], world["settings"]
    agent = settings.data_dir / "agent"
    assert admin.post("/api/admin/update").status_code == 409      # helper not installed
    agent.mkdir(parents=True, exist_ok=True)
    (agent / "installed").write_text("1")
    r = admin.post("/api/admin/update")
    assert r.status_code == 200 and r.json()["state"] == "working"
    assert json.loads((agent / "request.json").read_text())["action"] == "update"
    assert admin.post("/api/admin/update").status_code == 409      # already busy
    admin.post("/api/users", json={"username": "sam", "password": "sam-pass1"})
    assert login("sam", "sam-pass1").post("/api/admin/update").status_code == 403
