"""Throw random junk at every endpoint: the server must answer with a clean error,
never crash (HTTP 500) and never touch anything outside the drive."""

import os
import random
import string
from urllib.parse import quote

from test_v05 import world  # noqa: F401  (pytest fixture)

PIECES = ["..", ".", "/", "//", "\\\\", "%2e%2e", "~", "Shared", "Users", "max", "..%2f", "\u202e", "🎉",
          "a" * 300, " ", "\t", "\x00", "\n", ".trash", ".upload-tmp", "etc/passwd", "C:\\\\", "?", "#", "%00"]


def junk(rnd: random.Random) -> str:
    out = []
    for _ in range(rnd.randint(0, 6)):
        out.append(rnd.choice(PIECES) if rnd.random() < 0.6 else
                   "".join(rnd.choice(string.printable) for _ in range(rnd.randint(1, 12))))
    return "/".join(out) if rnd.random() < 0.5 else "".join(out)


def test_random_paths_never_crash_the_server(world, tmp_path):
    admin, public, files = world["admin"], world["public"], world["files"]
    outside = tmp_path / "outside.txt"
    outside.write_text("must not change")
    (files / "keep.txt").write_text("keep")
    rnd = random.Random(int(os.environ.get("FUZZ_SEED", "1234")))
    gets = ["list", "tree", "download", "thumbnail", "hash", "versions", "zip"]
    for _ in range(400):
        p = junk(rnd)
        r = admin.get(f"/api/{rnd.choice(gets)}", params={"path": p})
        assert r.status_code < 500, (p, r.status_code, r.text[:200])
        r = admin.post("/api/mkdir", json={"path": p})
        assert r.status_code < 500, (p, r.text[:200])
        r = admin.post("/api/move", json={"src": junk(rnd), "dst": p})
        assert r.status_code < 500, (p, r.text[:200])
        r = admin.post("/api/delete", json={"path": junk(rnd)})
        assert r.status_code < 500
        r = admin.post("/api/trash/restore", json={"name": p})
        assert r.status_code < 500
        r = admin.get("/api/search", params={"q": p})
        assert r.status_code < 500
        r = public.get("/s/" + quote(p, safe="/"))
        assert r.status_code < 500
    assert outside.read_text() == "must not change"
    assert not any(p.name == "outside.txt" for p in files.rglob("*"))
