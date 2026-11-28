package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestNewerVersion(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"1.0.1", "1.0.0", true}, {"1.0.0", "1.0.1", false}, {"1.10.0", "1.9.9", true},
		{"1.0.0", "1.0.0-dev", true}, {"1.0.0-dev", "1.0.0", false}, {"1.0.0", "1.0.0", false},
		{"2.0.0", "1.99.99", true}, {"v1.2.3", "1.2.2", true},
	}
	for _, c := range cases {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

func tarGz(t *testing.T, files map[string]string) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, body := range files {
		_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte(body))
	}
	_ = tw.Close()
	_ = gz.Close()
	return buf.Bytes()
}

func zipOf(t *testing.T, files map[string]string) []byte {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		h := &zip.FileHeader{Name: name, Method: zip.Deflate}
		h.SetMode(0o755)
		w, _ := zw.CreateHeader(h)
		_, _ = w.Write([]byte(body))
	}
	_ = zw.Close()
	return buf.Bytes()
}

// fakeGitHub serves a release list and its files; tamper changes the download.
func fakeGitHub(t *testing.T, archive []byte, tamper bool) *httptest.Server {
	sum := sha256.Sum256(archive)
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/releases":
			asset := func(name string) map[string]string {
				return map[string]string{"name": name, "browser_download_url": srv.URL + "/dl/" + name}
			}
			mine := asset(assetName())
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"tag_name": "v0.9.9", "assets": []any{mine, asset("SHA256SUMS")}},                            // the Mac client app
				{"tag_name": "server-v9.0.0", "draft": true, "assets": []any{mine, asset("SHA256SUMS")}},      // not published
				{"tag_name": "server-v8.0.0", "prerelease": true, "assets": []any{mine, asset("SHA256SUMS")}}, // test build
				{"tag_name": "server-v7.0.0", "assets": []any{asset("other.zip"), asset("SHA256SUMS")}},       // nothing for us
				{"tag_name": "server-v1.2.0", "html_url": "https://example/1.2.0", "assets": []any{mine, asset("SHA256SUMS")}},
				{"tag_name": "server-v1.1.0", "assets": []any{mine, asset("SHA256SUMS")}},
			})
		case "/dl/SHA256SUMS":
			_, _ = w.Write([]byte(hex.EncodeToString(sum[:]) + "  " + assetName() + "\n0000  other.zip\n"))
		case "/dl/" + assetName():
			body := archive
			if tamper {
				body = append([]byte("evil"), archive...)
			}
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	old := releasesAPI
	releasesAPI = srv.URL + "/releases"
	t.Cleanup(func() { releasesAPI = old })
	return srv
}

func releaseArchive(t *testing.T, files map[string]string) []byte {
	if strings.HasSuffix(assetName(), ".zip") {
		return zipOf(t, files)
	}
	return tarGz(t, files)
}

func TestFindsTheRightRelease(t *testing.T) {
	fakeGitHub(t, []byte("x"), false)
	rel, err := latestRelease(context.Background())
	if err != nil || rel == nil || rel.Version != "1.2.0" || rel.Page != "https://example/1.2.0" {
		t.Fatalf("%+v %v", rel, err)
	}
}

func TestUpdateDownloadIsChecked(t *testing.T) {
	archive := releaseArchive(t, map[string]string{"homedrive-server": "NEW PROGRAM"})
	fakeGitHub(t, archive, true)
	rel, _ := latestRelease(context.Background())
	dir := t.TempDir()
	err := fetchUpdate(context.Background(), rel, dir)
	if err == nil || !strings.Contains(err.Error(), "fingerprint") {
		t.Fatalf("tampered download accepted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "new")); err == nil {
		t.Fatal("tampered download was unpacked")
	}
}

func TestUpdateInstallsAndKeepsRunningCopyUntilReady(t *testing.T) {
	archive := releaseArchive(t, map[string]string{"homedrive-server": "NEW PROGRAM"})
	fakeGitHub(t, archive, false)
	rel, _ := latestRelease(context.Background())
	dir := t.TempDir()
	if err := fetchUpdate(context.Background(), rel, dir); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS == "darwin" {
		t.Skip("Mac installs swap the app bundle; covered by TestSwapBundle")
	}
	exe := filepath.Join(t.TempDir(), "homedrive-server")
	_ = os.WriteFile(exe, []byte("OLD PROGRAM"), 0o755)
	cmd, err := installUpdate(filepath.Join(dir, "new"), exe, []string{"app", "-data", "/x"})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(exe); string(b) != "NEW PROGRAM" {
		t.Fatalf("not replaced: %q", b)
	}
	if fi, _ := os.Stat(exe); fi.Mode().Perm()&0o100 == 0 {
		t.Fatal("new program isn't runnable")
	}
	if cmd.Path != exe || strings.Join(cmd.Args[1:], " ") != "app -data /x" {
		t.Fatalf("restart command: %v", cmd.Args)
	}
}

func TestBadArchivesAreRefused(t *testing.T) {
	dir := t.TempDir()
	for name, data := range map[string][]byte{
		"evil.zip":    zipOf(t, map[string]string{"../../escape": "x"}),
		"evil.tar.gz": tarGz(t, map[string]string{"../escape": "x"}),
	} {
		p := filepath.Join(dir, name)
		_ = os.WriteFile(p, data, 0o600)
		var err error
		if strings.HasSuffix(name, ".zip") {
			err = unzip(p, filepath.Join(dir, "out"))
		} else {
			err = untargz(p, filepath.Join(dir, "out"))
		}
		if err == nil {
			t.Fatalf("%s: path escaping the folder was accepted", name)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "escape")); err == nil {
		t.Fatal("a file escaped")
	}
}

func TestSwapBundle(t *testing.T) {
	apps := t.TempDir()
	bundle := filepath.Join(apps, "HomeDrive Server.app")
	_ = os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755)
	_ = os.WriteFile(filepath.Join(bundle, "Contents", "MacOS", "homedrive-server"), []byte("old"), 0o755)
	newDir := t.TempDir()
	// An update without the app inside changes nothing.
	if err := swapBundle(newDir, bundle, "homedrive-server"); err == nil {
		t.Fatal("empty update accepted")
	}
	fresh := filepath.Join(newDir, "HomeDrive Server.app", "Contents", "MacOS")
	_ = os.MkdirAll(fresh, 0o755)
	_ = os.WriteFile(filepath.Join(fresh, "homedrive-server"), []byte("new"), 0o755)
	if err := swapBundle(newDir, bundle, "homedrive-server"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(bundle, "Contents", "MacOS", "homedrive-server")); string(b) != "new" {
		t.Fatalf("got %q", b)
	}
	if entries, _ := os.ReadDir(apps); len(entries) != 1 {
		t.Fatalf("left behind: %v", entries)
	}
	if appBundle(filepath.Join(bundle, "Contents", "MacOS", "homedrive-server")) != bundle || appBundle("/usr/local/bin/homedrive-server") != "" {
		t.Fatal("appBundle")
	}
}

func TestUpdateNeedsSomethingNewer(t *testing.T) {
	var u updater
	u.latest = &Release{Version: "0.0.1"}
	if u.available() != nil {
		t.Fatal("older release offered as an update")
	}
	u.latest = &Release{Version: "99.0.0"}
	if u.available() == nil || u.info()["available"] != "99.0.0" {
		t.Fatal("newer release not offered")
	}
}
