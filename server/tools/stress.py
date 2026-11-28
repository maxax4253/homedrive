#!/usr/bin/env python3
"""Stress test: a throwaway HomeDrive server with a lot of data, timing every endpoint.

    cd server && python3 tools/stress.py [--files 100000] [--big-gb 2]

It creates its own temporary drive (nothing touches your real one), starts the
server on a spare port, fills the drive, and reports how long things take and
whether anything breaks. Needs the server's Python packages installed.
"""

import argparse
import hashlib
import io
import json
import os
import random
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import selftest  # noqa: E402  (reuses its HTTP helpers)

ODD_NAMES = [
    "emoji 🎉📁.txt", "Ünïcödé ñame.txt", "日本語のファイル.txt", "Привет мир.txt", "مرحبا.txt",
    "spaces   inside.txt", " leading space.txt", "trailing dot.", "quote's \"double\".txt",
    "percent %20 hash # question ?.txt", "semi;colon,comma&amp.txt", "back`tick$dollar.txt",
    "x" * 240 + ".txt",   # near the 255-byte limit
    "é-decomposed.txt",   # é as e + accent (macOS style)
    "UPPER.TXT", "upper.txt", "no-extension", ".hidden-start", "-dash-start.txt",
]

results: list[tuple[str, float, str]] = []


def timed(label: str, fn, limit: float | None = None):
    t = time.time()
    try:
        out = fn()
        took = time.time() - t
        flag = "" if limit is None or took <= limit else f"SLOW (> {limit}s)"
        results.append((label, took, flag))
        print(f"  {took:7.2f}s  {label} {flag}")
        return out
    except Exception as e:  # noqa: BLE001
        took = time.time() - t
        results.append((label, took, f"FAILED: {e}"))
        print(f"  {took:7.2f}s  {label}  FAILED: {e}")
        return None


def make_tree(root: Path, n_files: int) -> dict:
    """Lots of small files in nested folders, written straight to disk (fast)."""
    rnd = random.Random(42)
    folders = [root / "Big"]
    for i in range(400):
        parent = rnd.choice(folders)
        if len(parent.relative_to(root).parts) >= 9:
            parent = root / "Big"
        folders.append(parent / f"folder {i:03d}")
    for f in folders:
        f.mkdir(parents=True, exist_ok=True)
    crowded = root / "Crowded"      # one folder with a lot of files in it
    crowded.mkdir()
    payload = b"x" * 512
    t = time.time()
    for i in range(n_files):
        folder = crowded if i % 10 == 0 else rnd.choice(folders)
        (folder / f"file {i:06d}.txt").write_bytes(payload)
    print(f"  made {n_files:,} files in {len(folders) + 1} folders ({time.time() - t:.1f}s)")
    return {"crowded": n_files // 10, "deepest": max(len(f.relative_to(root).parts) for f in folders)}


def rss_mb(pid: int) -> float:
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("VmRSS"):
                return int(line.split()[1]) / 1024
    except OSError:
        pass
    return 0.0


def stream_upload(client: selftest.Client, folder: str, name: str, size: int) -> dict:
    """Upload a big generated file without holding it in memory."""
    boundary = "stress" + secrets.token_hex(8)
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{name}\"\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n").encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    chunk = os.urandom(1024 * 1024)
    h = hashlib.sha256()

    def body():
        yield head
        sent = 0
        while sent < size:
            part = chunk[: min(len(chunk), size - sent)]
            h.update(part)
            sent += len(part)
            yield part
        yield tail

    url = client.url("upload", {"path": folder})
    req = urllib.request.Request(url, data=body(), method="POST")
    for k, v in selftest.auth_headers(client.token).items():
        req.add_header(k, v)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Content-Length", str(len(head) + size + len(tail)))
    with urllib.request.urlopen(req, timeout=3600) as r:
        saved = json.loads(r.read())["saved"][0]
    if saved["sha256"] != h.hexdigest():
        raise AssertionError("fingerprint mismatch on the big upload")
    return saved


def stream_download(client: selftest.Client, path: str) -> tuple[int, str]:
    req = urllib.request.Request(client.url("download", {"path": path}))
    for k, v in selftest.auth_headers(client.token).items():
        req.add_header(k, v)
    h, n = hashlib.sha256(), 0
    with urllib.request.urlopen(req, timeout=3600) as r:
        while chunk := r.read(4 * 1024 * 1024):
            h.update(chunk)
            n += len(chunk)
    return n, h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", type=int, default=100_000)
    ap.add_argument("--big-gb", type=float, default=2.0)
    ap.add_argument("--port", type=int, default=18190)
    ap.add_argument("--go", metavar="BINARY", help="test the all-in-one Go server binary instead of the Python one")
    args = ap.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="homedrive-stress-"))
    files, data = tmp / "files", tmp / "data"
    files.mkdir(), data.mkdir()
    print(f"\nStress test in {tmp}\n\nMaking data")
    info = make_tree(files, args.files)

    env = dict(os.environ, HOMEDRIVE_FILES=str(files), HOMEDRIVE_DATA=str(data),
               HOMEDRIVE_USERNAME="max", HOMEDRIVE_PASSWORD="stress-password", HOMEDRIVE_MIN_FREE_GB="0.5")
    if args.go:
        cmd = [args.go, "-listen", f"127.0.0.1:{args.port}"]
    else:
        cmd = [sys.executable, "-m", "uvicorn", "app.main:create_app", "--factory",
               "--port", str(args.port), "--log-level", "warning"]
    server = subprocess.Popen(cmd, cwd=HERE, env=env)
    selftest.URL = f"http://127.0.0.1:{args.port}"
    selftest.USER = "max"
    try:
        for _ in range(50):
            try:
                selftest.PAIRING = bool(selftest.Client().get("health").json().get("pairing"))
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.2)
        if args.go:
            selftest.PAIR_CODE = subprocess.run([args.go, "pair-code", "-data", str(data), "-user", "max"],
                                                capture_output=True, text=True, check=True).stdout.strip()
        admin = selftest.CODE_MAKER = selftest.login("max", "stress-password")

        print("\nBrowsing a big drive")
        timed("me (storage numbers, first time: walks the whole drive)", lambda: admin.get("me").json(), 5)
        timed("me again (should be cached)", lambda: admin.get("me").json(), 0.5)
        r = timed(f"list a folder with {info['crowded']:,} files", lambda: admin.get("list", {"path": "Crowded"}), 5)
        if r is not None and r.status == 200:
            print(f"           -> {len(r.json()['entries']):,} entries, {len(r.body) / 1e6:.1f} MB of JSON")
        timed("list the top level", lambda: admin.get("list"), 1)
        timed("recent (newest 200 of everything)", lambda: admin.get("recent", {"limit": 200}), 5)
        timed("search 'file 0999'", lambda: admin.get("search", {"q": "file 0999"}), 5)
        timed("search with no matches", lambda: admin.get("search", {"q": "zzz-nothing"}), 5)
        r = timed("tree of the whole Big folder (offline sync list)", lambda: admin.get("tree", {"path": "Big"}), 10)
        if r is not None and r.status == 200:
            print(f"           -> {len(r.json()['entries']):,} files, {len(r.body) / 1e6:.1f} MB of JSON")

        def zip_crowded():
            req = urllib.request.Request(admin.url("zip", {"path": "Crowded"}))
            for k, v in selftest.auth_headers(admin.token).items():
                req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=600) as resp:
                body = resp.read()
            names = zipfile.ZipFile(io.BytesIO(body)).namelist()
            assert len(names) == info["crowded"], f"zip has {len(names)} files"
            return len(body)
        n = timed(f"zip a folder with {info['crowded']:,} files", zip_crowded, 60)
        if n:
            print(f"           -> {n / 1e6:.0f} MB zip, server memory {rss_mb(server.pid):.0f} MB")

        print("\nOdd file names")
        for name in ODD_NAMES:
            def roundtrip(name=name):
                r = admin.upload("", name, name.encode())
                selftest.expect(r.status == 200, f"upload HTTP {r.status} {r.text[:120]}")
                saved = r.json()["saved"][0]
                d = admin.get("download", {"path": saved["path"]})
                selftest.expect(d.status == 200 and d.body == name.encode(), f"download HTTP {d.status}")
                m = admin.post("move", {"src": saved["path"], "dst": "Odd/" + saved["name"]})
                selftest.expect(m.status == 200, f"move HTTP {m.status} {m.text[:120]}")
            timed(f"upload/download/move {name[:40]!r}", roundtrip)
        timed("zip the odd names", lambda: selftest.expect(admin.get("zip", {"path": "Odd"}).status == 200, "zip failed"))
        timed("search finds emoji", lambda: selftest.expect(
            any("🎉" in e["name"] for e in admin.get("search", {"q": "🎉"}).json()["entries"]), "not found"))

        print(f"\nBig file ({args.big_gb:g} GB)")
        size = int(args.big_gb * 1024 ** 3)
        before = rss_mb(server.pid)
        saved = timed("upload (with fingerprint check)", lambda: stream_upload(admin, "", "big.bin", size))
        print(f"           -> server memory {before:.0f} MB before, {rss_mb(server.pid):.0f} MB after")
        if saved:
            got = timed("download", lambda: stream_download(admin, "big.bin"))
            if got:
                selftest.expect(got[0] == size, "download size differs")
                print(f"           -> {size / 1e6 / max(results[-1][1], 0.01):.0f} MB/s")
            timed("replace it (version history copies it)", lambda: selftest.expect(
                admin.upload("", "big.bin", b"small now", replace=True, if_modified=saved["modified"]).status == 200,
                "replace failed"), 120)

        print("\nMany requests at once")
        import concurrent.futures as cf

        def burst():
            with cf.ThreadPoolExecutor(20) as pool:
                codes = list(pool.map(lambda _: admin.get("list", {"path": "Big"}).status, range(200)))
            selftest.expect(all(c == 200 for c in codes), f"errors: {set(codes)}")
        timed("200 folder listings from 20 at once", burst, 20)
    finally:
        server.send_signal(signal.SIGINT)
        server.wait(timeout=20)
        shutil.rmtree(tmp, ignore_errors=True)

    bad = [r for r in results if r[2]]
    print(f"\n{len(results) - len(bad)} fine, {len(bad)} slow or failed")
    for label, took, flag in bad:
        print(f"  {label}: {flag} ({took:.1f}s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
