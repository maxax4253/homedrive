# HomeDrive

A small self-hosted drive with a **native Mac app**: no web page and no Finder sync.

- `server/` is a Python (FastAPI) API that runs in Docker on the home server and serves one folder (default `~/drive`).
- `mac/` is a SwiftUI Mac app for browsing, uploading, downloading and Quick Look previews.

The server listens only on the Tailscale IP, so it's reachable from your devices and nothing else.

## 1. Server (on the Mac Mini)

```bash
git clone https://github.com/maxax4253/homedrive.git
cd homedrive/server
./setup.sh
```

`setup.sh` asks for a username, password and the folder to serve, then starts the container on `http://<tailscale-ip>:8090`. The settings live in `server/.env`, which is not committed.

Update later with:

```bash
cd homedrive && git pull && cd server && ./setup.sh
```

## 2. Mac app (on your MacBook)

Needs the Xcode command line tools (`xcode-select --install`) or full Xcode.

```bash
git clone https://github.com/maxax4253/homedrive.git
cd homedrive/mac
./build-app.sh
```

This builds `HomeDrive.app`, copies it to `/Applications`, and opens it. Sign in with `http://<tailscale-ip>:8090` and the username/password from setup.

To work on the code, open `mac/Package.swift` in Xcode and press Run.

## What it does (v0.1)

- Browse folders as an icon grid with photo thumbnails (including iPhone HEIC) or as a sortable list
- Back/forward/up, breadcrumbs, search within a folder
- Upload by dragging files or folders onto the window, or with the Upload button (⌘U)
- Download to ~/Downloads
- Quick Look previews: double-click or press Space (images, PDFs, video, docs)
- New folder, rename, move to trash (the trash is the `.trash` folder on the server)
- Login token stored in the macOS Keychain

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/health` | no auth |
| POST | `/api/login` | `{username, password}` → `{token}` |
| GET | `/api/me` | disk space |
| GET | `/api/list?path=` | folder contents |
| GET | `/api/download?path=` | supports Range requests |
| GET | `/api/thumbnail?path=&size=` | JPEG, cached |
| POST | `/api/upload?path=` | multipart, field `files` |
| POST | `/api/mkdir` | `{path}` |
| POST | `/api/move` | `{src, dst}` (also used for rename) |
| POST | `/api/delete` | `{path}` → moves to `.trash` |

All endpoints except health and login need `Authorization: Bearer <token>`.

## Tests

```bash
cd server
pip install -r requirements.txt pytest httpx
python -m pytest
```
