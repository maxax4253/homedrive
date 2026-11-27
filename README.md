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

## What it does (v0.3)

Google Drive-style layout:

- Sidebar with a **+ New** button (New folder, File upload, Folder upload), plus My Drive, Recent, Starred and Trash, with storage use at the bottom
- **Transfers popup** in the bottom-right with a progress ring for each upload/download; click a finished download to show it in Finder
- **Sort** by clicking the Name / Last modified / File size / Date deleted headers (click again to flip)
- **Download folders as a zip**, streamed so big folders start right away. Selecting several items with a folder among them gives one zip
- **Drag out**: drag a file or folder from HomeDrive into Finder or onto the desktop (folders arrive as .zip)
- **Drag to move**: drop files onto a folder, or onto a folder name in the path at the top
- **Starred**: right-click, then Add to Starred. Stars stay attached when you rename or move things
- **My Drive** has clickable breadcrumbs and a list/grid toggle. The list has Name / Last modified / File size columns; the grid has folder cards and file cards with photo thumbnails (including iPhone HEIC)
- **Search in Drive** searches the whole drive, not just the current folder
- **Trash** with Restore, Delete forever and Empty trash; restored items go back to where they were
- Drag files or folders onto the window to upload; downloads go to ~/Downloads
- Previews with Quick Look: double-click a file or press Space
- Right-click or ⋮ for Preview, Show file location, Download, Rename, Move to trash
- Shortcuts: ⌘U uploads files, ⇧⌘U uploads a folder, ⇧⌘N makes a new folder, ⌘[ / ⌘] go back/forward, ⌘R refreshes
- The login token is stored in the macOS Keychain

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/health` | no auth |
| POST | `/api/login` | `{username, password}` → `{token}` |
| GET | `/api/me` | disk space |
| GET | `/api/list?path=` | folder contents |
| GET | `/api/download?path=` | supports Range requests |
| GET | `/api/zip?path=&path=` | streams a zip of files/folders |
| GET | `/api/starred` | starred items |
| POST | `/api/star` | `{path, starred}` |
| GET | `/api/thumbnail?path=&size=` | JPEG, cached |
| POST | `/api/upload?path=` | multipart, field `files` |
| POST | `/api/mkdir` | `{path}` |
| POST | `/api/move` | `{src, dst}` (also used for rename) |
| POST | `/api/delete` | `{path}` → moves to the trash |
| GET | `/api/recent?limit=` | newest files across the drive |
| GET | `/api/search?q=` | name search across the drive |
| GET | `/api/trash` | trashed items with their original location |
| POST | `/api/trash/restore` | `{name}` |
| POST | `/api/trash/delete` | `{name}` → gone for good |
| POST | `/api/trash/empty` | |

All endpoints except health and login need `Authorization: Bearer <token>`.

## Tests

```bash
cd server
pip install -r requirements.txt pytest httpx
python -m pytest
```
