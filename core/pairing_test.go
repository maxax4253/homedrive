package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type client struct {
	t      *testing.T
	base   string
	token  string
	device string
}

func (c *client) do(method, path string, body any) (int, map[string]any) {
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, c.base+path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if c.device != "" {
		req.Header.Set(deviceHeader, c.device)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func testServer(t *testing.T) (*Server, string) {
	dir := t.TempDir()
	cfg := &Config{FilesRoot: dir + "/files", DataDir: dir + "/data", Username: "max", Password: "admin-pass",
		Secret: "s3cret", TokenDays: 30, VersionsKeep: 10, RequirePairing: true}
	for _, d := range []string{cfg.FilesRoot, cfg.DataDir} {
		if err := mkdirAll(d); err != nil {
			t.Fatal(err)
		}
	}
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts.URL
}

func pair(t *testing.T, base, dataDir, user, pw string) *client {
	code, _, err := NewCode(dataDir, user)
	if err != nil {
		t.Fatal(err)
	}
	c := &client{t: t, base: base}
	st, out := c.do("POST", "/api/pair", map[string]string{"code": code, "username": user, "password": pw, "device_name": "Test Mac"})
	if st != 200 {
		t.Fatalf("pairing failed: %d %v", st, out)
	}
	c.token, c.device = out["token"].(string), out["device_key"].(string)
	return c
}

func TestPasswordAloneIsUseless(t *testing.T) {
	_, base := testServer(t)
	c := &client{t: t, base: base}
	if st, out := c.do("POST", "/api/login", map[string]string{"username": "max", "password": "admin-pass"}); st != 403 {
		t.Fatalf("login without a paired device: %d %v", st, out)
	}
}

func TestPairingFlow(t *testing.T) {
	srv, base := testServer(t)
	data := srv.cfg.DataDir
	admin := pair(t, base, data, "max", "admin-pass")

	if st, _ := admin.do("GET", "/api/list", nil); st != 200 {
		t.Fatalf("paired device can't list: %d", st)
	}
	// The login token alone, without the device key, gets nothing.
	if st, _ := (&client{t: t, base: base, token: admin.token}).do("GET", "/api/list", nil); st != 403 {
		t.Fatalf("token without device: %d", st)
	}
	// A paired device can sign in again (e.g. after the login expires).
	re := &client{t: t, base: base, device: admin.device}
	if st, out := re.do("POST", "/api/login", map[string]string{"username": "max", "password": "admin-pass"}); st != 200 {
		t.Fatalf("re-login on a paired device: %d %v", st, out)
	}
	// A code is used up after one pairing.
	code, _, _ := NewCode(data, "max")
	c := &client{t: t, base: base}
	body := map[string]string{"code": code, "username": "max", "password": "admin-pass"}
	if st, _ := c.do("POST", "/api/pair", body); st != 200 {
		t.Fatal("first use")
	}
	if st, _ := c.do("POST", "/api/pair", body); st != 401 {
		t.Fatal("code worked twice")
	}
	// The right code but the wrong password fails.
	code, _, _ = NewCode(data, "max")
	if st, _ := c.do("POST", "/api/pair", map[string]string{"code": code, "username": "max", "password": "nope"}); st != 401 {
		t.Fatal("wrong password paired")
	}
}

func TestWrongCodesCancelOpenCodes(t *testing.T) {
	srv, base := testServer(t)
	code, _, _ := NewCode(srv.cfg.DataDir, "max")
	c := &client{t: t, base: base}
	for i := 0; i < codeMaxGuesses; i++ {
		wrong := "000000"
		if wrong == code {
			wrong = "111111"
		}
		c.do("POST", "/api/pair", map[string]string{"code": wrong, "username": "max", "password": "admin-pass"})
	}
	if st, _ := c.do("POST", "/api/pair", map[string]string{"code": code, "username": "max", "password": "admin-pass"}); st == 200 {
		t.Fatal("code still worked after 5 wrong guesses")
	}
}

func TestCodesAreForOnePerson(t *testing.T) {
	srv, base := testServer(t)
	admin := pair(t, base, srv.cfg.DataDir, "max", "admin-pass")
	if st, _ := admin.do("POST", "/api/users", map[string]any{"username": "mom", "password": "mom-pass"}); st != 200 {
		t.Fatal("add user")
	}
	// A code made for max can't pair mom's device.
	code, _, _ := NewCode(srv.cfg.DataDir, "max")
	c := &client{t: t, base: base}
	if st, _ := c.do("POST", "/api/pair", map[string]string{"code": code, "username": "mom", "password": "mom-pass"}); st != 401 {
		t.Fatal("code for max paired mom")
	}
	// The admin can make a code for mom; mom can't make one for max.
	st, out := admin.do("POST", "/api/devices/code", map[string]string{"username": "mom"})
	if st != 200 {
		t.Fatalf("admin code for mom: %d", st)
	}
	mom := &client{t: t, base: base}
	st, out = mom.do("POST", "/api/pair", map[string]string{"code": out["code"].(string), "username": "mom", "password": "mom-pass"})
	if st != 200 {
		t.Fatalf("mom pairing: %d %v", st, out)
	}
	mom.token, mom.device = out["token"].(string), out["device_key"].(string)
	if st, _ := mom.do("POST", "/api/devices/code", map[string]string{"username": "max"}); st != 403 {
		t.Fatal("mom made a code for max")
	}
	// Mom's device key doesn't work with max's login.
	if st, _ := (&client{t: t, base: base, token: admin.token, device: mom.device}).do("GET", "/api/list", nil); st != 403 {
		t.Fatal("mixed device and login")
	}
	// Removing a device signs it out at once; deleting the account removes its devices.
	_, list := mom.do("GET", "/api/devices", nil)
	id := list["devices"].([]any)[0].(map[string]any)["id"].(string)
	if st, _ := admin.do("DELETE", "/api/devices/"+id, nil); st != 204 {
		t.Fatal("remove device")
	}
	if st, _ := mom.do("GET", "/api/list", nil); st != 403 {
		t.Fatal("removed device still works")
	}
	admin.do("DELETE", "/api/users/mom", nil)
	if n := len(srv.devices.List("mom")); n != 0 {
		t.Fatalf("%d devices left for a deleted account", n)
	}
}

func TestHealthAndSharePagesNeedNoDevice(t *testing.T) {
	_, base := testServer(t)
	c := &client{t: t, base: base}
	if st, out := c.do("GET", "/api/health", nil); st != 200 || out["pairing"] != true {
		t.Fatalf("health: %d %v", st, out)
	}
	if st, _ := c.do("GET", "/s/not-a-link", nil); st != 404 {
		t.Fatal("share page")
	}
}
