# HomeDrive server (all-in-one)

The next HomeDrive server: one small program, no Docker, nothing else to install.
It serves the same API as the current server (`../server`), so the Mac app works
with either, and it reads the same kind of accounts, logins and share links.

Built only from Go's standard library: no outside code to trust or keep patched.

    go build -o homedrive-server .
    HOMEDRIVE_PASSWORD=choose-one ./homedrive-server -files ~/drive -data ~/.homedrive

Checked by the same tests as the current server (see `.github/workflows/tests.yml`):
its own unit tests, the server test suite, `homedrive selftest` and the stress test.

Still to come: device pairing, built-in remote access (Tailscale), the tray app with
a setup wizard and self-updating, backups, and moving an existing install over.
