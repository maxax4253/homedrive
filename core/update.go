package main

// Self-update: the app checks GitHub for a newer "server-v*" release, downloads
// the build for this computer, checks it against the release's SHA256SUMS,
// swaps it in and restarts. Nothing is replaced until the download is complete
// and checked, and the old copy is kept until the new one is in place.

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	releasesAPI   = "https://api.github.com/repos/maxax4253/homedrive/releases?per_page=30"
	maxUpdateSize = int64(300 << 20)
	updateClient  = &http.Client{Timeout: 10 * time.Minute}
)

type Release struct {
	Version string
	Page    string
	Assets  map[string]string // file name -> download address
}

type updater struct {
	mu       sync.Mutex
	latest   *Release
	checked  time.Time
	checkErr string
	busy     bool
	status   string // what's happening right now, shown on the page
}

// assetName is the release file for this computer.
func assetName() string {
	arch := map[string]string{"amd64": "x64", "arm64": "arm64"}[runtime.GOARCH]
	switch runtime.GOOS {
	case "darwin":
		return "HomeDrive-Server-mac.zip"
	case "windows":
		return "HomeDrive-Server-windows-" + arch + ".zip"
	}
	return "HomeDrive-Server-" + runtime.GOOS + "-" + arch + ".tar.gz"
}

// newerVersion: is a newer than b? ("1.0.0-dev" counts as older than "1.0.0".)
func newerVersion(a, b string) bool {
	pa, pb := parseVersion(a), parseVersion(b)
	for i := range 3 {
		if pa.n[i] != pb.n[i] {
			return pa.n[i] > pb.n[i]
		}
	}
	return pa.pre == "" && pb.pre != ""
}

type version struct {
	n   [3]int
	pre string
}

func parseVersion(s string) version {
	var v version
	s, v.pre, _ = strings.Cut(strings.TrimPrefix(s, "v"), "-")
	for i, part := range strings.SplitN(s, ".", 3) {
		v.n[i], _ = strconv.Atoi(part)
	}
	return v
}

func latestRelease(ctx context.Context) (*Release, error) {
	api := releasesAPI
	if u := os.Getenv("HOMEDRIVE_UPDATE_URL"); u != "" { // for testing updates end to end
		api = u
	}
	req, _ := http.NewRequestWithContext(ctx, "GET", api, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "HomeDrive/"+Version)
	resp, err := updateClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub answered %s", resp.Status)
	}
	var list []struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Page       string `json:"html_url"`
		Assets     []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 5<<20)).Decode(&list); err != nil {
		return nil, err
	}
	var best *Release
	for _, r := range list {
		if r.Draft || r.Prerelease || !strings.HasPrefix(r.Tag, "server-v") {
			continue
		}
		v := strings.TrimPrefix(r.Tag, "server-v")
		if best != nil && !newerVersion(v, best.Version) {
			continue
		}
		rel := &Release{Version: v, Page: r.Page, Assets: map[string]string{}}
		for _, a := range r.Assets {
			rel.Assets[a.Name] = a.URL
		}
		if rel.Assets[assetName()] != "" && rel.Assets["SHA256SUMS"] != "" {
			best = rel
		}
	}
	return best, nil
}

func (u *updater) check(ctx context.Context) {
	rel, err := latestRelease(ctx)
	u.mu.Lock()
	defer u.mu.Unlock()
	u.checked = time.Now()
	if err != nil {
		u.checkErr = "Couldn't check for updates: " + err.Error()
		return
	}
	u.checkErr, u.latest = "", rel
}

// available returns the newer release, if there is one.
func (u *updater) available() *Release {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.latest != nil && newerVersion(u.latest.Version, Version) {
		return u.latest
	}
	return nil
}

func (u *updater) info() map[string]any {
	u.mu.Lock()
	defer u.mu.Unlock()
	out := map[string]any{"busy": u.busy, "status": u.status, "error": u.checkErr}
	if !u.checked.IsZero() {
		out["checked"] = u.checked.Unix()
	}
	if u.latest != nil && newerVersion(u.latest.Version, Version) {
		out["available"] = u.latest.Version
		out["page"] = u.latest.Page
	}
	return out
}

func (u *updater) setStatus(s string) {
	u.mu.Lock()
	u.status = s
	u.mu.Unlock()
}

// download fetches a release file (size-limited), returning its bytes' path and fingerprint.
func download(ctx context.Context, url, dest string) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	req.Header.Set("User-Agent", "HomeDrive/"+Version)
	resp, err := updateClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("download failed: %s", resp.Status)
	}
	f, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, maxUpdateSize+1))
	if err != nil {
		return "", err
	}
	if n > maxUpdateSize {
		return "", errors.New("the download is too big")
	}
	return hex.EncodeToString(h.Sum(nil)), f.Close()
}

// fetchUpdate downloads and checks the new build, and unpacks it into dir.
func fetchUpdate(ctx context.Context, rel *Release, dir string) error {
	name := assetName()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	sumsFile := filepath.Join(dir, "SHA256SUMS")
	if _, err := download(ctx, rel.Assets["SHA256SUMS"], sumsFile); err != nil {
		return err
	}
	sums, _ := os.ReadFile(sumsFile)
	want := ""
	for _, line := range strings.Split(string(sums), "\n") {
		if f := strings.Fields(line); len(f) == 2 && strings.TrimPrefix(f[1], "*") == name {
			want = strings.ToLower(f[0])
		}
	}
	if len(want) != 64 {
		return errors.New("the release has no fingerprint for " + name)
	}
	archive := filepath.Join(dir, name)
	got, err := download(ctx, rel.Assets[name], archive)
	if err != nil {
		return err
	}
	if got != want {
		return errors.New("the download doesn't match its fingerprint, so it wasn't installed")
	}
	out := filepath.Join(dir, "new")
	_ = os.RemoveAll(out)
	if strings.HasSuffix(name, ".zip") {
		return unzip(archive, out)
	}
	return untargz(archive, out)
}

// safeJoin keeps archive entries inside dest.
func safeJoin(dest, name string) (string, error) {
	p := filepath.Join(dest, filepath.FromSlash(name))
	if !within(p, dest) || p == dest {
		return "", fmt.Errorf("bad file name in the update: %q", name)
	}
	return p, nil
}

func unzip(archive, dest string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer r.Close()
	for _, f := range r.File {
		p, err := safeJoin(dest, f.Name)
		if err != nil {
			return err
		}
		mode := f.Mode()
		switch {
		case mode.IsDir():
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
			continue
		case !mode.IsRegular():
			return fmt.Errorf("unexpected file in the update: %q", f.Name)
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		err = writeFileFrom(p, rc, mode.Perm()|0o600)
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func untargz(archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		p, err := safeJoin(dest, h.Name)
		if err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return err
			}
			if err := writeFileFrom(p, tr, os.FileMode(h.Mode).Perm()|0o600); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unexpected file in the update: %q", h.Name)
		}
	}
}

func writeFileFrom(p string, r io.Reader, mode os.FileMode) error {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, io.LimitReader(r, maxUpdateSize)); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// installUpdate puts the unpacked build in place of the running one and
// returns the command that starts the new one with the same options (args).
func installUpdate(newDir, exe string, args []string) (*exec.Cmd, error) {
	if runtime.GOOS == "darwin" {
		if bundle := appBundle(exe); bundle != "" {
			if err := swapBundle(newDir, bundle, filepath.Base(exe)); err != nil {
				return nil, err
			}
			return exec.Command("open", append([]string{"-n", bundle, "--args"}, args...)...), nil
		}
	}
	// A single program file (Windows .exe, Linux, or a Mac binary outside an app).
	var fresh string
	_ = filepath.WalkDir(newDir, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && (d.Name() == "homedrive-server" || strings.HasSuffix(d.Name(), ".exe")) {
			fresh = p
		}
		return nil
	})
	if fresh == "" {
		return nil, errors.New("the update doesn't contain the program")
	}
	staged := exe + ".new"
	in, err := os.Open(fresh)
	if err != nil {
		return nil, err
	}
	err = writeFileFrom(staged, in, 0o755)
	in.Close()
	if err != nil {
		return nil, fmt.Errorf("can't write next to the program: %w", err)
	}
	if runtime.GOOS == "windows" {
		// A running .exe can't be replaced, but it can be renamed out of the way.
		old := exe + ".old"
		_ = os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			return nil, err
		}
		if err := os.Rename(staged, exe); err != nil {
			_ = os.Rename(old, exe)
			return nil, err
		}
	} else if err := os.Rename(staged, exe); err != nil {
		return nil, err
	}
	return exec.Command(exe, args...), nil
}

// swapBundle replaces a Mac app bundle with the one in newDir (same folder, so
// the moves are instant; the old one is put back if anything goes wrong).
func swapBundle(newDir, bundle, exeName string) error {
	fresh := filepath.Join(newDir, filepath.Base(bundle))
	if _, err := os.Stat(filepath.Join(fresh, "Contents", "MacOS", exeName)); err != nil {
		return errors.New("the update doesn't contain the app")
	}
	staged := filepath.Join(filepath.Dir(bundle), "."+filepath.Base(bundle)+".new")
	old := filepath.Join(filepath.Dir(bundle), "."+filepath.Base(bundle)+".old")
	_ = os.RemoveAll(staged)
	_ = os.RemoveAll(old)
	if err := copyBundle(fresh, staged); err != nil {
		return fmt.Errorf("can't write next to the app (move it to your Applications folder): %w", err)
	}
	if err := os.Rename(bundle, old); err != nil {
		return err
	}
	if err := os.Rename(staged, bundle); err != nil {
		_ = os.Rename(old, bundle)
		return err
	}
	return os.RemoveAll(old)
}

// appBundle: /Applications/HomeDrive Server.app for a program inside it.
func appBundle(exe string) string {
	macos := filepath.Dir(exe)
	contents := filepath.Dir(macos)
	bundle := filepath.Dir(contents)
	if filepath.Base(macos) == "MacOS" && filepath.Base(contents) == "Contents" && strings.HasSuffix(bundle, ".app") {
		return bundle
	}
	return ""
}

func copyBundle(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("unexpected file %s", rel)
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		return writeFileFrom(target, in, info.Mode().Perm())
	})
}

// cleanOldUpdate removes what a previous update left behind (Windows keeps the
// old .exe until the next start).
func cleanOldUpdate(dataDir string) {
	if exe, err := os.Executable(); err == nil {
		_ = os.Remove(exe + ".old")
	}
	_ = os.RemoveAll(filepath.Join(dataDir, "update"))
}

// ---------------------------------------------------------------- in the app

func (a *App) watchForUpdates() {
	go func() {
		select {
		case <-a.ctx.Done():
			return
		case <-time.After(time.Minute):
		}
		for {
			a.updates.check(a.ctx)
			if rel := a.updates.available(); rel != nil {
				log.Printf("update available: %s", rel.Version)
			}
			select {
			case <-a.ctx.Done():
				return
			case <-time.After(12 * time.Hour):
			}
		}
	}()
}

// startUpdate downloads, checks and installs the update, then restarts.
func (a *App) startUpdate() error {
	rel := a.updates.available()
	if rel == nil {
		return errors.New("There's no update to install.")
	}
	a.updates.mu.Lock()
	if a.updates.busy {
		a.updates.mu.Unlock()
		return errors.New("Already updating.")
	}
	a.updates.busy = true
	a.updates.mu.Unlock()

	go func() {
		fail := func(err error) {
			log.Printf("update failed: %v", err)
			a.updates.mu.Lock()
			a.updates.busy, a.updates.status = false, "Update failed: "+err.Error()
			a.updates.mu.Unlock()
		}
		exe, err := os.Executable()
		if err == nil {
			exe, err = filepath.EvalSymlinks(exe)
		}
		if err != nil {
			fail(err)
			return
		}
		a.updates.setStatus("Downloading version " + rel.Version + "…")
		dir := filepath.Join(a.dataDir, "update")
		if err := fetchUpdate(a.ctx, rel, dir); err != nil {
			fail(err)
			return
		}
		a.updates.setStatus("Installing…")
		args := os.Args[1:]
		if len(args) == 0 {
			args = []string{"app"}
		}
		cmd, err := installUpdate(filepath.Join(dir, "new"), exe, args)
		if err != nil {
			fail(err)
			return
		}
		log.Printf("updated to %s, restarting", rel.Version)
		a.updates.setStatus("Restarting…")
		a.restart(cmd)
	}()
	return nil
}
