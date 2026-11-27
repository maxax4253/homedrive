# HomeDrive

A small self-hosted drive with a **native Mac app**: no web page and no Finder sync.

- `server/` is a Python (FastAPI) API that runs in Docker on the home server and serves one folder (default `~/drive`).
- `mac/` is a SwiftUI Mac app for browsing, uploading, downloading and Quick Look previews.

The server listens only on the Tailscale IP, so it's reachable from your devices and nothing else.

## Install

**Server** (on the Linux machine that holds your files: Debian, Ubuntu or Mint):

```bash
curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install.sh | bash
```

It installs Docker and Tailscale if they're missing, asks for a username, password and storage folder, and starts HomeDrive on `http://<tailscale-ip>:8090`. Afterwards:

```bash
homedrive status     # running? address, free space
homedrive update     # get the latest version
homedrive logs       # follow the server log
homedrive password   # change the login password
```

**Mac app:**

```bash
curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-mac.sh | bash
```

It downloads the latest build from GitHub Releases (Apple silicon and Intel) into `/Applications`. Sign in with the address from `homedrive url`.

To build the Mac app yourself instead, you need the Xcode command line tools: `xcode-select --install`, then `mac/build-app.sh`. To work on the code, open `mac/Package.swift` in Xcode.

### Releasing a new Mac build

Push a version tag. GitHub Actions builds the app and attaches `HomeDrive.zip` to a release:

```bash
git tag v0.4.0 && git push origin v0.4.0
```

## What it does (v0.4)

**Free up space on your Mac:**

- **Move to HomeDrive:** right-click files or folders in Finder, then **Services → Move to HomeDrive** (or **+ New → Move from Mac…**, ⌥⌘U). Each file is uploaded, then its SHA-256 fingerprint is compared with the copy the server wrote to disk. Only if every file matches are the originals moved to your Mac's Trash. Anything that can't be verified stays where it was.
- **Copy to HomeDrive:** the same Finder service, but it keeps the originals.
- The sidebar shows how much space you've freed on this Mac.

Google Drive-style layout:

- Sidebar with a **+ New** button (New folder, File upload, Folder upload), plus My Drive, Recent, Starred and Trash, with storage use at the bottom
- **Transfers popup** in the bottom-right with a progress ring for each upload/download; click a finished download to show it in Finder
- **Sort** by clicking the Name / Last modified / File size / Date deleted headers (click again to flip)
- **Download folders as a zip**, streamed so big folders start right away. Selecting several items with a folder among them gives one zip
- **Drag out**: drag files or folders from HomeDrive into Finder or onto the desktop. Select several and drag them together; a single file arrives as itself, a folder or several items arrive as one .zip
- **Drag to move**: drop one or many selected items onto a folder, or onto a folder name in the path at the top
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
| POST | `/api/upload?path=` | multipart, field `files`; returns each file's on-disk `sha256` |
| GET | `/api/hash?path=` | SHA-256 and size of a stored file |
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
