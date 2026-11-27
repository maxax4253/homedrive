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
homedrive status     # running? address, free space, backups, links
homedrive update     # get the latest version
homedrive logs       # follow the server log
homedrive password   # change the admin password

homedrive backup /mnt/backup   # nightly backups to that folder (ideally another drive)
homedrive backup now           # back up right now
homedrive links on             # public share links through Tailscale Funnel
```

**Mac app:**

```bash
curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-mac.sh | bash
```

It downloads the latest build from GitHub Releases (Apple silicon and Intel) into `/Applications`. Sign in with the address from `homedrive url`.

To build the Mac app yourself instead, you need the Xcode command line tools: `xcode-select --install`, then `mac/build-app.sh`. To work on the code, open `mac/Package.swift` in Xcode.

### Releasing a new Mac build

Bump `CFBundleShortVersionString` in `mac/Info.plist` and push to `main`. GitHub Actions builds the app (Apple silicon + Intel), tags it `v<version>` and attaches `HomeDrive.zip` to a new release. Every other push that touches `mac/` just checks that the app still builds.

## What it does (v0.5)

**Free up space on your Mac:**

- **Move to HomeDrive:** right-click files or folders in Finder, then **Services → Move to HomeDrive** (or **+ New → Move from Mac…**, ⌥⌘U). Each file is uploaded, then its SHA-256 fingerprint is compared with the copy the server wrote to disk. Only if every file matches are the originals moved to your Mac's Trash. Anything that can't be verified stays where it was.
- **Copy to HomeDrive:** the same Finder service, but it keeps the originals.
- The sidebar shows how much space you've freed on this Mac.

**Accounts:** the admin (from setup) sees the whole drive. Add family or roommates on the **Admin** page: each person gets a private `Users/<name>` folder plus a **Shared** folder everyone can use, with an optional storage limit. Resetting someone's password signs them out everywhere.

**Share links:** right-click, then **Get link…**, with an expiry (1/7/30 days or never) and an optional password. The link opens a simple download page; folders download as a zip. The public pages run as a separate, read-only server that can only serve share links, so your drive, login and API stay Tailscale-only. Turn it on with the **Share links** switch on the Admin page (or `homedrive links on`). It uses Tailscale Funnel, so there are no router changes. The first time, the app shows an **Approve in Tailscale** button for the one-time permission. The switch works through a small helper on the server (`homedrive install-agent`, set up by the installer and by `homedrive update`), because the HomeDrive container itself can't change Tailscale or Docker. Manage links on the **Shared links** page.

**Backups and version history:** `homedrive backup <folder>` takes a snapshot every night at 3am. Unchanged files are hard links, so each snapshot is a full copy that only costs the space of what changed. It keeps every day for a week, weekly for a month, and monthly for 6 months. Right-click a file, then **Version history…** to download or restore an older copy from backups or from earlier edits. Restoring is undoable.

**Offline and editing:**

- **Make available offline** keeps a file or folder in a normal **`~/HomeDrive Offline`** folder and syncs it both ways, like Google Drive or Dropbox. Edit with any app, even with no connection, and your changes upload a few seconds after you save (or when you're back online). Changes from HomeDrive download every couple of minutes. New files you add upload; files you delete go to HomeDrive's Trash. If a file changed in both places, both copies are kept as "(conflict …)", so nothing is overwritten. If lots of files vanish at once, or you delete the whole folder, nothing is deleted on HomeDrive.
- **Open in app (saves back)** opens a file in its normal app (Pages, Word, Preview…). Every time you save, the new version uploads and the previous one goes into version history. If someone changed it on the server meanwhile, yours is saved as a separate "(conflict …)" copy instead of overwriting.

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
| POST | `/api/upload?path=&replace=&if_modified=` | multipart, field `files`; returns each file's on-disk `sha256`. `replace` overwrites (keeping a version); `if_modified` returns 409 if the file changed |
| GET | `/api/hash?path=` | SHA-256 and size of a stored file |
| GET | `/api/tree?path=` | every file under a folder (offline sync) |
| GET | `/api/versions?path=` | older copies from edits and backups |
| GET | `/api/versions/download?path=&version=` | download one |
| POST | `/api/versions/restore` | `{path, version}` (current copy is kept) |
| GET/POST | `/api/backups`, `/api/backups/run` | admin |
| GET/POST/DELETE | `/api/shares`, `/api/shares/{token}` | your share links |
| GET/POST/DELETE | `/api/users…` | admin: add, reset password, storage limit, delete |
| POST | `/api/me/password` | change your own password |
| GET | `/s/{token}` | **public server only**: share-link page |
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
