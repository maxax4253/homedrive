package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type appClient struct {
	t    *testing.T
	base string
	http *http.Client
}

func (c *appClient) req(method, path string, body any, mod func(*http.Request)) (int, map[string]any) {
	var buf io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		buf = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, buf)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", c.base) // what the browser sends from our own page
	}
	if mod != nil {
		mod(req)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func testApp(t *testing.T) (*App, *appClient) {
	dir := t.TempDir()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	a, err := NewApp(ctx, filepath.Join(dir, "data"), ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	a.noTailscale = true
	ts := httptest.NewUnstartedServer(a.Handler())
	ts.Listener = ln
	ts.Start()
	t.Cleanup(ts.Close)
	jar, _ := cookiejar.New(nil)
	return a, &appClient{t: t, base: "http://" + a.listen, http: &http.Client{Jar: jar}}
}

func (c *appClient) open(a *App) {
	resp, err := c.http.Get(a.OpenURL())
	if err != nil || resp.StatusCode != 200 {
		c.t.Fatalf("opening the secret link: %v %v", err, resp)
	}
	resp.Body.Close()
}

func TestAppPageNeedsTheSecretLink(t *testing.T) {
	a, c := testApp(t)
	for _, p := range []string{"/app/", "/app/api/state"} {
		if st, _ := c.req("GET", p, nil, nil); st != 403 {
			t.Fatalf("%s without the link: %d", p, st)
		}
	}
	resp, _ := c.http.Get(c.base + "/app/open?t=wrong")
	if resp.StatusCode != 403 {
		t.Fatalf("wrong secret: %d", resp.StatusCode)
	}
	resp.Body.Close()
	c.open(a)
	if st, out := c.req("GET", "/app/api/state", nil, nil); st != 200 || out["setup_done"] != false {
		t.Fatalf("state: %d %v", st, out)
	}
	// The secret changes every start: an old cookie stops working.
	b, _ := NewApp(context.Background(), a.dataDir, a.listen)
	if b.token == a.token {
		t.Fatal("same secret twice")
	}
}

func TestAppRefusesOtherSites(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	// DNS rebinding: the browser sends the attacker's host name.
	if st, _ := c.req("GET", "/app/api/state", nil, func(r *http.Request) { r.Host = "evil.example:8093" }); st != 421 {
		t.Fatalf("foreign Host: %d", st)
	}
	// Another web page submitting to us (cookie is SameSite=Strict, but check Origin too).
	body := map[string]string{"files_root": t.TempDir(), "username": "max", "password": "longpassword"}
	if st, _ := c.req("POST", "/app/api/setup", body, func(r *http.Request) { r.Header.Set("Origin", "https://evil.example") }); st != 403 {
		t.Fatalf("foreign Origin: %d", st)
	}
	if st, _ := c.req("POST", "/app/api/setup", body, func(r *http.Request) { r.Header.Del("Origin") }); st != 403 {
		t.Fatalf("no Origin: %d", st)
	}
	if a.SetupDone() {
		t.Fatal("a refused request still set things up")
	}
}

func TestAppSetupFlow(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	// The drive isn't there before setup.
	if st, _ := c.req("GET", "/api/health", nil, nil); st != 503 {
		t.Fatalf("health before setup: %d", st)
	}
	files := filepath.Join(t.TempDir(), "My Files")
	bad := []map[string]string{
		{"files_root": "relative/folder", "username": "max", "password": "pw"},
		{"files_root": filepath.Join(a.dataDir, "inside"), "username": "max", "password": "pw"},
		{"files_root": files, "username": "Bad Name!", "password": "pw"},
		{"files_root": files, "username": "max", "password": ""},
	}
	for _, b := range bad {
		if st, out := c.req("POST", "/app/api/setup", b, nil); st != 400 {
			t.Fatalf("bad setup %v accepted: %d %v", b, st, out)
		}
	}
	st, out := c.req("POST", "/app/api/setup", map[string]string{"files_root": files, "username": "Max", "password": "short"}, nil)
	if st != 200 || out["setup_done"] != true || out["running"] != true {
		t.Fatalf("setup: %d %v", st, out)
	}
	if fi, err := os.Stat(files); err != nil || !fi.IsDir() {
		t.Fatal("files folder not made")
	}
	if st, _ := c.req("POST", "/app/api/setup", map[string]string{"files_root": files, "username": "max", "password": "x"}, nil); st != 409 {
		t.Fatal("setup ran twice")
	}

	// A pairing code from the page pairs a device through the same local address.
	_, code := c.req("POST", "/app/api/pair-code", map[string]string{}, nil)
	if len(code["code"].(string)) != 6 || code["username"] != "max" {
		t.Fatalf("pair code: %v", code)
	}
	st, out = c.req("POST", "/api/pair", map[string]string{"code": code["code"].(string), "username": "max", "password": "short", "device_name": "Test"}, nil)
	if st != 200 || out["device_key"] == nil {
		t.Fatalf("pairing: %d %v", st, out)
	}
	dev, tok := out["device_key"].(string), out["token"].(string)
	st, _ = c.req("GET", "/api/list", nil, func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+tok)
		r.Header.Set(deviceHeader, dev)
	})
	if st != 200 {
		t.Fatalf("list as the paired device: %d", st)
	}

	// After a restart the settings are remembered and the drive starts again.
	b, err := NewApp(context.Background(), a.dataDir, a.listen)
	if err != nil || !b.SetupDone() || b.settings.Load().FilesRoot != files || b.settings.Load().Username != "max" {
		t.Fatalf("settings after restart: %v %+v", err, b.settings.Load())
	}
	raw, _ := os.ReadFile(filepath.Join(a.dataDir, appSettings))
	if strings.Contains(string(raw), "short") {
		t.Fatal("password written to the settings file")
	}
}

func TestStatePageNeverGetsTheLoginLink(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	c.req("POST", "/app/api/setup", map[string]string{"files_root": t.TempDir() + "/f", "username": "max", "password": "longpassword"}, nil)
	a.drive.Load().tsMu.Lock()
	a.drive.Load().tsStatus = TailnetStatus{State: "needs_login", LoginURL: "https://login.tailscale.com/a/secret"}
	a.drive.Load().tsMu.Unlock()
	a.settings.Load().Tailscale = true
	a.noTailscale = false
	_, out := c.req("GET", "/app/api/state", nil, nil)
	b, _ := json.Marshal(out)
	if strings.Contains(string(b), "login.tailscale.com") || out["needs_tailscale_login"] != true {
		t.Fatalf("state: %s", b)
	}
}

func TestCleanFolder(t *testing.T) {
	home, _ := os.UserHomeDir()
	if p, err := cleanFolder("~/HomeDrive"); err != nil || p != filepath.Join(home, "HomeDrive") {
		t.Fatalf("~ expansion: %q %v", p, err)
	}
	for _, bad := range []string{"", "relative", "/", home, "~"} {
		if _, err := cleanFolder(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
	f := filepath.Join(t.TempDir(), "file.txt")
	_ = os.WriteFile(f, []byte("x"), 0o600)
	if _, err := cleanFolder(f); err == nil {
		t.Fatal("a file accepted as a folder")
	}
	if !within("/a/b/c", "/a/b") || within("/a/bc", "/a/b") || !within("/a/b", "/a/b") {
		t.Fatal("within")
	}
}

func TestDefaultUsernameIsValid(t *testing.T) {
	if !usernameRE.MatchString(defaultUsername()) {
		t.Fatalf("%q", defaultUsername())
	}
}

// The bug found on a real Mac: ~/HomeDrive was the person's code folder
// (~/homedrive; Mac folder names ignore case). Setup must ask before using it.
func TestSetupAsksBeforeUsingAFolderWithFiles(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	busy := filepath.Join(t.TempDir(), "homedrive")
	_ = os.MkdirAll(filepath.Join(busy, "mac"), 0o755)
	_ = os.WriteFile(filepath.Join(busy, "README.md"), []byte("x"), 0o644)
	_ = os.WriteFile(filepath.Join(busy, ".DS_Store"), []byte("x"), 0o644)

	_, out := c.req("POST", "/app/api/check-folder", map[string]string{"files_root": busy}, nil)
	if out["needs_confirm"] != true || out["count"].(float64) != 2 {
		t.Fatalf("check-folder: %v", out)
	}
	body := map[string]any{"files_root": busy, "username": "max", "password": "longpassword"}
	st, out := c.req("POST", "/app/api/setup", body, nil)
	if st != 200 || out["needs_confirm"] != true || a.SetupDone() {
		t.Fatalf("setup went ahead without asking: %d %v", st, out)
	}
	body["use_existing"] = true
	if st, out := c.req("POST", "/app/api/setup", body, nil); st != 200 || out["setup_done"] != true {
		t.Fatalf("setup after yes: %d %v", st, out)
	}
	// An empty or new folder needs no question.
	_, out = c.req("POST", "/app/api/check-folder", map[string]string{"files_root": t.TempDir()}, nil)
	if out["needs_confirm"] != nil {
		t.Fatalf("empty folder: %v", out)
	}
}

func TestSuggestedFolderIsNeverOneWithFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if got := defaultFilesRoot(); got != filepath.Join(home, "HomeDrive") {
		t.Fatalf("fresh home: %s", got)
	}
	_ = os.MkdirAll(filepath.Join(home, "HomeDrive", "code"), 0o755)
	if got := defaultFilesRoot(); got != filepath.Join(home, "HomeDrive Files") {
		t.Fatalf("with a busy HomeDrive: %s", got)
	}
}

func TestChangeFolder(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	old := filepath.Join(t.TempDir(), "old")
	c.req("POST", "/app/api/setup", map[string]string{"files_root": old, "username": "max", "password": "longpassword"}, nil)
	_ = os.WriteFile(filepath.Join(old, "keep.txt"), []byte("x"), 0o644)

	busy := t.TempDir()
	_ = os.WriteFile(filepath.Join(busy, "a.txt"), []byte("x"), 0o644)
	if _, out := c.req("POST", "/app/api/folder", map[string]any{"files_root": busy}, nil); out["needs_confirm"] != true {
		t.Fatalf("no question for a folder with files: %v", out)
	}
	if a.settings.Load().FilesRoot != old {
		t.Fatal("changed without a yes")
	}
	fresh := filepath.Join(t.TempDir(), "new")
	st, out := c.req("POST", "/app/api/folder", map[string]any{"files_root": fresh}, nil)
	if st != 200 || out["files_root"] != fresh || a.settings.Load().FilesRoot != fresh {
		t.Fatalf("change: %d %v", st, out)
	}
	if _, err := os.Stat(filepath.Join(old, "keep.txt")); err != nil {
		t.Fatal("the old folder's files were touched")
	}
	b, _ := NewApp(context.Background(), a.dataDir, a.listen)
	if b.settings.Load().FilesRoot != fresh {
		t.Fatal("new folder not saved")
	}
}

// The HomeDrive Mac app on the server computer signs itself in, no code.
func TestThisDeviceSignsInWithoutACode(t *testing.T) {
	a, c := testApp(t)
	c.open(a)
	if st, _ := c.req("POST", "/app/api/this-device", map[string]string{"name": "Max's Mac"}, nil); st != 409 {
		t.Fatal("worked before setup")
	}
	c.req("POST", "/app/api/setup", map[string]string{"files_root": t.TempDir() + "/f", "username": "max", "password": "longpassword"}, nil)
	st, out := c.req("POST", "/app/api/this-device", map[string]string{"name": "Max's Mac"}, nil)
	if st != 200 || out["username"] != "max" || out["address"] != c.base {
		t.Fatalf("this-device: %d %v", st, out)
	}
	dev, tok := out["device_key"].(string), out["token"].(string)
	if st, _ := c.req("GET", "/api/list", nil, func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+tok)
		r.Header.Set(deviceHeader, dev)
	}); st != 200 {
		t.Fatalf("list with the new device: %d", st)
	}
	// Without the secret link it's refused.
	other := &appClient{t: t, base: c.base, http: &http.Client{}}
	if st, _ := other.req("POST", "/app/api/this-device", map[string]string{}, nil); st != 403 {
		t.Fatalf("no secret: %d", st)
	}
	// Shutdown is only for the copy inside the Mac app.
	if st, _ := c.req("POST", "/app/api/shutdown", map[string]string{}, nil); st != 409 {
		t.Fatalf("shutdown outside the app: %d", st)
	}
}
