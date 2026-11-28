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

## Built-in Tailscale

Start it with `-tailscale` (or `HOMEDRIVE_TAILSCALE=1`) and HomeDrive joins your
tailnet by itself as `homedrive` — nothing else to install. The first time, it
prints a link to sign in to Tailscale (also shown by `homedrive-server status`).
With Funnel (on by default, `-funnel=false` to turn off) it's reachable from
anywhere at `https://homedrive.<your-tailnet>.ts.net`, and share links use that
address. Device pairing can't be turned off while Tailscale is on.

Funnel needs HTTPS certificates and Funnel allowed for the device in the
Tailscale admin console; if they aren't, HomeDrive still works on your own
devices and `status` says what to turn on.

Building without Tailscale (only Go's standard library, any Go from 1.24):

    GOTOOLCHAIN=local go build -modfile=go.notailscale.mod -tags notailscale .

The Tailscale library's fingerprints are in `go.sum`; refresh them with the
"Refresh Go libraries" workflow.
