package main

// The HomeDrive API. Same endpoints and replies as the Python server, so the Mac
// app, `homedrive selftest` and the stress test work against either one.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	gb                 = 1 << 30
	loginFailures      = 10
	loginFailuresPerIP = 30
	loginWindow        = 15 * time.Minute
)

type Server struct {
	cfg      *Config
	users    *Users
	links    *Links
	versions *Versions
	login    *Limiter
	devices  *Devices
	pairing  *Pairing

	mu        sync.Mutex
	stars     map[string]*Stars
	usageMap  map[string]usageEntry
	measuring map[string]bool
	recent    map[string]recentEntry
}

type usageEntry struct {
	at   time.Time
	used int64
}

type recentEntry struct {
	at      time.Time
	entries []Entry
}

type session struct {
	user   *User
	space  *Space
	stars  *Stars
	device *Device // nil when pairing is off
}

// ---------------------------------------------------------------- plumbing

type apiError struct {
	status int
	msg    string
}

func (e *apiError) Error() string { return e.msg }

func fail(status int, msg string) error { return &apiError{status, msg} }

type handler func(w http.ResponseWriter, r *http.Request, s *session) (any, error)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (srv *Server) respond(w http.ResponseWriter, v any, err error) {
	if err != nil {
		var ae *apiError
		var pe *PathError
		switch {
		case errors.As(err, &ae):
			writeJSON(w, ae.status, map[string]string{"detail": ae.msg})
		case errors.As(err, &pe):
			writeJSON(w, 400, map[string]string{"detail": pe.msg})
		default:
			writeJSON(w, 500, map[string]string{"detail": "Something went wrong on the server: " + err.Error()})
		}
		return
	}
	switch v := v.(type) {
	case nil:
		w.WriteHeader(http.StatusNoContent)
	case handled:
		// The handler wrote the response itself (file downloads, zips).
	default:
		writeJSON(w, 200, v)
	}
}

type handled struct{}

func (srv *Server) open(h func(w http.ResponseWriter, r *http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		v, err := h(w, r)
		srv.respond(w, v, err)
	}
}

func (srv *Server) authed(adminOnly bool, h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s, err := srv.session(r)
		if err == nil && adminOnly && !s.user.IsAdmin {
			err = fail(403, "Only the admin can do that")
		}
		if err != nil {
			srv.respond(w, nil, err)
			return
		}
		v, err := h(w, r, s)
		srv.respond(w, v, err)
	}
}

func (srv *Server) session(r *http.Request) (*session, error) {
	header := r.Header.Get("Authorization")
	token := ""
	if len(header) > 7 && strings.EqualFold(header[:7], "bearer ") {
		token = header[7:]
	}
	name, version, ok := checkToken(token, srv.cfg.Secret)
	if !ok {
		return nil, fail(401, "Not logged in")
	}
	u := srv.users.Get(name)
	if u == nil || u.TokenVersion != version {
		return nil, fail(401, "Not logged in")
	}
	dev, err := srv.checkDevice(r, u.Username)
	if err != nil {
		return nil, err
	}
	return &session{user: u, space: srv.spaceFor(u.Username, u.IsAdmin, true), stars: srv.starsFor(u), device: dev}, nil
}

// spaceFor: the admin sees the whole drive; everyone else gets Users/<name> plus Shared.
func (srv *Server) spaceFor(name string, isAdmin, create bool) *Space {
	shared := filepath.Join(srv.cfg.FilesRoot, sharedName)
	home := srv.cfg.FilesRoot
	if !isAdmin {
		home = filepath.Join(srv.cfg.FilesRoot, usersDir, name)
	}
	if create {
		_ = os.MkdirAll(shared, 0o755)
		_ = os.MkdirAll(home, 0o755)
	}
	return NewSpace(home, shared)
}

func (srv *Server) starsFor(u *User) *Stars {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if st := srv.stars[u.Username]; st != nil {
		return st
	}
	name := "stars.json"
	if !u.IsAdmin {
		name = "stars-" + u.Username + ".json"
	}
	st := OpenStars(srv.cfg.DataDir, name)
	srv.stars[u.Username] = st
	return st
}

func (srv *Server) mark(s *session, entries []Entry) []Entry {
	for _, e := range entries {
		e["starred"] = s.stars.Is(e["path"].(string))
	}
	return entries
}

// versionKey: a file's place in the whole drive, so history survives moving the drive.
func (srv *Server) versionKey(p string) string {
	rel, err := filepath.Rel(srv.cfg.FilesRoot, p)
	if err != nil {
		return p
	}
	return filepath.ToSlash(rel)
}

func decode(r *http.Request, v any) error {
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil {
		return fail(422, "That request wasn't understood")
	}
	return nil
}

func notFound(err error, msg string) error {
	if errors.Is(err, fs.ErrNotExist) {
		return fail(404, msg)
	}
	return err
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func queryInt(r *http.Request, name string, def, lo, hi int) (int, error) {
	v := r.URL.Query().Get(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < lo || n > hi {
		return 0, fail(422, fmt.Sprintf("%s must be between %d and %d", name, lo, hi))
	}
	return n, nil
}

// ---------------------------------------------------------------- usage

// usage: bytes in a home folder. Measuring a big drive takes seconds, so a cached
// number is returned right away and refreshed in the background once over 30s old.
func (srv *Server) usage(name, home string, fresh bool) int64 {
	measure := func() int64 {
		used := folderSize(home)
		srv.mu.Lock()
		srv.usageMap[name] = usageEntry{time.Now(), used}
		delete(srv.measuring, name)
		srv.mu.Unlock()
		return used
	}
	srv.mu.Lock()
	cached, ok := srv.usageMap[name]
	stale := ok && time.Since(cached.at) >= 30*time.Second
	start := stale && !fresh && !srv.measuring[name]
	if start {
		srv.measuring[name] = true
	}
	srv.mu.Unlock()
	if ok && !fresh {
		if start {
			go measure()
		}
		return cached.used
	}
	return measure()
}

func (srv *Server) forgetUsage(name string) {
	srv.mu.Lock()
	delete(srv.usageMap, name)
	for k := range srv.recent {
		if strings.HasPrefix(k, name+"\x00") {
			delete(srv.recent, k)
		}
	}
	srv.mu.Unlock()
}

// ---------------------------------------------------------------- routes

func (srv *Server) Routes(mux *http.ServeMux) {
	a := func(h handler) http.HandlerFunc { return srv.authed(false, h) }
	admin := func(h handler) http.HandlerFunc { return srv.authed(true, h) }

	mux.HandleFunc("GET /api/health", srv.open(func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]any{"ok": true, "name": "HomeDrive", "version": Version, "pairing": srv.cfg.RequirePairing}, nil
	}))
	srv.pairingRoutes(mux)
	mux.HandleFunc("POST /api/login", srv.open(srv.loginHandler))
	mux.HandleFunc("GET /api/me", a(srv.me))
	mux.HandleFunc("POST /api/me/password", a(srv.changeMyPassword))

	mux.HandleFunc("GET /api/list", a(srv.list))
	mux.HandleFunc("GET /api/tree", a(srv.tree))
	mux.HandleFunc("GET /api/recent", a(srv.recentHandler))
	mux.HandleFunc("GET /api/search", a(srv.search))
	mux.HandleFunc("GET /api/starred", a(srv.starred))
	mux.HandleFunc("POST /api/star", a(srv.star))

	mux.HandleFunc("GET /api/download", a(srv.download))
	mux.HandleFunc("GET /api/zip", a(srv.zipHandler))
	mux.HandleFunc("GET /api/thumbnail", a(srv.thumbnail))
	mux.HandleFunc("GET /api/hash", a(srv.hash))

	mux.HandleFunc("POST /api/upload", a(srv.upload))
	mux.HandleFunc("POST /api/mkdir", a(srv.mkdir))
	mux.HandleFunc("POST /api/move", a(srv.move))
	mux.HandleFunc("POST /api/delete", a(srv.delete))

	mux.HandleFunc("GET /api/trash", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return map[string]any{"entries": listTrash(s.space)}, nil
	}))
	mux.HandleFunc("POST /api/trash/restore", a(srv.trashRestore))
	mux.HandleFunc("POST /api/trash/delete", a(srv.trashDelete))
	mux.HandleFunc("POST /api/trash/empty", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return map[string]any{"deleted": emptyTrash(s.space)}, nil
	}))

	mux.HandleFunc("GET /api/versions", a(srv.listVersions))
	mux.HandleFunc("GET /api/versions/download", a(srv.downloadVersion))
	mux.HandleFunc("POST /api/versions/restore", a(srv.restoreVersion))

	mux.HandleFunc("GET /api/backups", admin(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return map[string]any{"enabled": false, "running": false, "hour": 3, "last_run": nil, "last_success": nil,
			"last_error": nil, "last_duration": nil, "snapshots": []string{}, "free": nil, "total": nil}, nil
	}))
	mux.HandleFunc("POST /api/backups/run", admin(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return nil, fail(400, "Backups aren't available in this version yet.")
	}))

	mux.HandleFunc("POST /api/shares", a(srv.createShare))
	mux.HandleFunc("GET /api/shares", a(srv.myShares))
	mux.HandleFunc("DELETE /api/shares/{token}", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		if !srv.links.Revoke(r.PathValue("token"), s.user.Username) {
			return nil, fail(404, "Link not found")
		}
		return nil, nil
	}))

	mux.HandleFunc("GET /api/admin/links", admin(srv.linksStatus))
	mux.HandleFunc("POST /api/admin/links", admin(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return nil, fail(409, "Share links follow remote access in this version: turn on access from anywhere in the HomeDrive server app.")
	}))
	mux.HandleFunc("POST /api/admin/update", admin(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		return nil, fail(409, "This server updates itself.")
	}))

	mux.HandleFunc("GET /api/users", admin(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		out := []map[string]any{}
		for _, u := range srv.users.List() {
			out = append(out, srv.userJSON(u))
		}
		return map[string]any{"users": out}, nil
	}))
	mux.HandleFunc("POST /api/users", admin(srv.addUser))
	mux.HandleFunc("POST /api/users/{username}/password", admin(srv.resetPassword))
	mux.HandleFunc("POST /api/users/{username}/quota", admin(srv.setQuota))
	mux.HandleFunc("DELETE /api/users/{username}", admin(srv.deleteUser))
}

// ---------------------------------------------------------------- basics

func (srv *Server) loginHandler(w http.ResponseWriter, r *http.Request) (any, error) {
	var body struct{ Username, Password string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	name := strings.ToLower(strings.TrimSpace(body.Username))
	// A device that isn't paired can't even try a password.
	dev, err := srv.checkDevice(r, "")
	if err != nil {
		return nil, err
	}
	keys := map[string]int{"user:" + name: loginFailures, "ip:" + clientIP(r): loginFailuresPerIP}
	for k, n := range keys {
		if !srv.login.Allow(k, n, loginWindow, false) {
			return nil, fail(429, "Too many wrong passwords. Sign-in is paused for 15 minutes.")
		}
	}
	u := srv.users.CheckLogin(name, body.Password)
	if u == nil || (dev != nil && dev.User != u.Username) {
		for k := range keys {
			srv.login.Record(k)
		}
		return nil, fail(401, "Wrong username or password")
	}
	for k := range keys {
		srv.login.Clear(k)
	}
	token := makeToken(u.Username, u.TokenVersion, srv.cfg.Secret, srv.cfg.TokenDays)
	return map[string]any{"token": token, "username": u.Username, "is_admin": u.IsAdmin}, nil
}

func (srv *Server) me(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	driveUsed := srv.usage(s.user.Username, s.space.Home, false)
	info := map[string]any{
		"username": s.user.Username, "is_admin": s.user.IsAdmin, "quota": s.user.QuotaBytes,
		"links_enabled": srv.cfg.PublicURL != "", "backups_enabled": false,
		"cleanup_days": srv.cfg.CleanupDays, "drive_used": driveUsed,
	}
	if q := s.user.QuotaBytes; q != nil && *q > 0 {
		info["total"], info["used"], info["free"], info["scope"] = *q, driveUsed, max(0, *q-driveUsed), "quota"
	} else {
		total, used, free := diskSpace(srv.cfg.FilesRoot)
		info["total"], info["used"], info["free"], info["scope"] = total, used, free, "disk"
	}
	return info, nil
}

func (srv *Server) changeMyPassword(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	if s.user.IsAdmin {
		return nil, fail(400, "Change the admin password in the HomeDrive server app.")
	}
	if srv.users.CheckLogin(s.user.Username, body.Old) == nil {
		return nil, fail(401, "Your current password is wrong")
	}
	if err := srv.users.SetPassword(s.user.Username, body.New); err != nil {
		return nil, fail(400, err.Error())
	}
	u := srv.users.Get(s.user.Username)
	return map[string]any{"token": makeToken(u.Username, u.TokenVersion, srv.cfg.Secret, srv.cfg.TokenDays)}, nil
}

// ---------------------------------------------------------------- browsing

func (srv *Server) list(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	path := r.URL.Query().Get("path")
	hidden := r.URL.Query().Get("hidden") == "true"
	items, err := listDir(s.space, path, hidden)
	if err != nil {
		return nil, notFound(err, "Folder not found")
	}
	return map[string]any{"path": strings.Trim(path, "/"), "entries": srv.mark(s, items)}, nil
}

func (srv *Server) tree(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	p, err := s.space.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		return nil, err
	}
	if !exists(p) {
		return nil, fail(404, "Not found")
	}
	return map[string]any{"entries": treeFiles(s.space, p)}, nil
}

func (srv *Server) skipTop(s *session) map[string]bool {
	if s.user.IsAdmin {
		return map[string]bool{usersDir: true}
	}
	return nil
}

func (srv *Server) recentHandler(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	limit, err := queryInt(r, "limit", 50, 1, 500)
	if err != nil {
		return nil, err
	}
	// Finding the newest files means looking at every file: reuse it for 20 seconds.
	key := fmt.Sprintf("%s\x00%d", s.user.Username, limit)
	srv.mu.Lock()
	hit, ok := srv.recent[key]
	srv.mu.Unlock()
	var found []Entry
	if ok && time.Since(hit.at) < 20*time.Second {
		found = hit.entries
	} else {
		found = recentFiles(s.space, limit, srv.skipTop(s))
		srv.mu.Lock()
		srv.recent[key] = recentEntry{time.Now(), found}
		srv.mu.Unlock()
	}
	fresh := []Entry{}
	for _, e := range found {
		if p, err := s.space.Resolve(e["path"].(string)); err == nil && exists(p) {
			c := Entry{}
			for k, v := range e {
				c[k] = v
			}
			fresh = append(fresh, c)
		}
	}
	return map[string]any{"entries": srv.mark(s, fresh)}, nil
}

func (srv *Server) search(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	limit, err := queryInt(r, "limit", 200, 1, 1000)
	if err != nil {
		return nil, err
	}
	return map[string]any{"entries": srv.mark(s, searchFiles(s.space, r.URL.Query().Get("q"), limit, srv.skipTop(s)))}, nil
}

func (srv *Server) starred(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	out := []Entry{}
	for _, rel := range s.stars.All() {
		p, err := s.space.Resolve(rel)
		if err != nil || !exists(p) || s.space.IsTop(p) {
			continue
		}
		if e, err := entryFor(s.space, p); err == nil {
			out = append(out, e)
		}
	}
	sortEntries(out)
	return map[string]any{"entries": srv.mark(s, out)}, nil
}

func (srv *Server) star(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	body := struct {
		Path    string `json:"path"`
		Starred *bool  `json:"starred"`
	}{}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	on := body.Starred == nil || *body.Starred
	p, err := s.space.Resolve(body.Path)
	if err != nil {
		return nil, err
	}
	if !exists(p) || s.space.IsTop(p) {
		return nil, fail(404, "Not found")
	}
	s.stars.Set(s.space.Rel(p), on)
	return map[string]any{"path": s.space.Rel(p), "starred": on}, nil
}

// ---------------------------------------------------------------- downloads

func attachment(name string) string {
	return mime.FormatMediaType("attachment", map[string]string{"filename": name})
}

func serveFile(w http.ResponseWriter, r *http.Request, p, name string, extra map[string]string) {
	f, err := os.Open(p)
	if err != nil {
		writeJSON(w, 404, map[string]string{"detail": "File not found"})
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		writeJSON(w, 404, map[string]string{"detail": "File not found"})
		return
	}
	for k, v := range extra {
		w.Header().Set(k, v)
	}
	w.Header().Set("Content-Type", mimeFor(name))
	w.Header().Set("Content-Disposition", attachment(name))
	http.ServeContent(w, r, "", info.ModTime(), f)
}

func (srv *Server) download(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	p, err := s.space.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		return nil, err
	}
	if !isFile(p) {
		return nil, fail(404, "File not found")
	}
	serveFile(w, r, p, filepath.Base(p), nil)
	return handled{}, nil
}

func (srv *Server) zipHandler(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	paths := r.URL.Query()["path"]
	if len(paths) == 0 {
		return nil, fail(422, "Nothing to zip")
	}
	items := []zipItem{}
	for _, rel := range paths {
		p, err := s.space.Resolve(rel)
		if err != nil {
			return nil, err
		}
		if p == s.space.Home {
			return nil, fail(400, "Can't zip the whole drive")
		}
		if !exists(p) {
			return nil, fail(404, "Not found: "+rel)
		}
		items = append(items, zipItem{p, filepath.Base(p)})
	}
	name := "HomeDrive download.zip"
	if len(items) == 1 {
		base := filepath.Base(items[0].path)
		if isFile(items[0].path) {
			base = strings.TrimSuffix(base, filepath.Ext(base))
		}
		name = base + ".zip"
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", attachment(name))
	_ = writeZip(w, items)
	return handled{}, nil
}

func (srv *Server) thumbnail(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	p, err := s.space.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		return nil, err
	}
	size, err := queryInt(r, "size", 256, 32, 1024)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(p)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fail(404, "File not found")
	}
	if !thumbTypes[strings.ToLower(filepath.Ext(p))] || info.Size() > maxThumbSource {
		return nil, fail(415, "No thumbnail for this file type")
	}
	dir := filepath.Join(srv.cfg.DataDir, "thumbs")
	_ = os.MkdirAll(dir, 0o700)
	cached := filepath.Join(dir, thumbKey(p, info, size)+".jpg")
	if !isFile(cached) {
		if err := makeThumbnail(p, cached, size); err != nil {
			return nil, fail(415, "Couldn't make a thumbnail")
		}
	}
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Header().Set("Content-Type", "image/jpeg")
	http.ServeFile(w, r, cached)
	return handled{}, nil
}

func (srv *Server) hash(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	path := r.URL.Query().Get("path")
	p, err := s.space.Resolve(path)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(p)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fail(404, "File not found")
	}
	sum, err := sha256File(p)
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": path, "size": info.Size(), "sha256": sum}, nil
}

// ---------------------------------------------------------------- uploads & changes

// newerMtime makes sure a replaced file's modified time moved forward. Some file
// systems only update times every few milliseconds, so two quick saves could
// otherwise look identical to "has this changed since you opened it?".
func newerMtime(p string, old float64) {
	info, err := os.Stat(p)
	if err != nil {
		return
	}
	if fileTime(info) < old+0.05 {
		t := time.Unix(0, int64((old+0.05)*1e9))
		_ = os.Chtimes(p, t, t)
	}
}

func (srv *Server) upload(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	q := r.URL.Query()
	folder, err := s.space.Resolve(q.Get("path"))
	if err != nil {
		return nil, err
	}
	if !isDir(folder) {
		return nil, fail(404, "Folder not found")
	}
	replace := q.Get("replace") == "true"
	var ifModified *float64
	if v := q.Get("if_modified"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return nil, fail(422, "if_modified must be a number")
		}
		ifModified = &f
	}

	// Never let uploads fill the disk: the computer's own system lives there too.
	_, _, free := diskSpace(folder)
	room := free - srv.cfg.MinFreeBytes
	tooBig := fail(507, "The server's disk is almost full, so the upload was stopped.")
	if quota := s.user.QuotaBytes; quota != nil && *quota > 0 {
		used := srv.usage(s.user.Username, s.space.Home, true)
		if left := *quota - used; left < room {
			room = left
			tooBig = fail(413, fmt.Sprintf("Storage limit reached (%.1f GB).", float64(*quota)/gb))
		}
	}
	if r.ContentLength > room {
		return nil, tooBig
	}

	mr, err := r.MultipartReader()
	if err != nil {
		return nil, fail(422, "Expected a file upload")
	}
	saved := []Entry{}
	count := 0
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fail(400, "The upload was cut off")
		}
		if formName(part) != "files" || rawFileName(part) == "" {
			part.Close()
			continue
		}
		count++
		if replace && count > 1 {
			return nil, fail(400, "Replace one file at a time")
		}
		name, err := safeName(rawFileName(part))
		if err != nil {
			return nil, err
		}
		var dest string
		var oldMtime float64
		if replace {
			dest = filepath.Join(folder, name)
			info, err := os.Stat(dest)
			if err != nil || !info.Mode().IsRegular() {
				return nil, fail(404, "The file to replace isn't there anymore")
			}
			oldMtime = fileTime(info)
			if ifModified != nil && abs(oldMtime-*ifModified) > 0.01 {
				return nil, fail(409, "This file changed on the server since you opened it")
			}
		} else {
			dest = uniquePath(filepath.Join(folder, name))
		}
		e, err := srv.writeUpload(part, folder, dest, replace, oldMtime, &room, tooBig, s)
		part.Close()
		if err != nil {
			return nil, err
		}
		saved = append(saved, e)
	}
	if count == 0 {
		return nil, fail(422, "No files in the upload")
	}
	srv.forgetUsage(s.user.Username)
	return map[string]any{"saved": srv.mark(s, saved)}, nil
}

// formName is the field name, read forgivingly (see rawFileName).
func formName(p *multipart.Part) string {
	if n := p.FormName(); n != "" {
		return n
	}
	header := p.Header.Get("Content-Disposition")
	if i := strings.Index(header, `name="`); i >= 0 {
		rest := header[i+len(`name="`):]
		if j := strings.Index(rest, `"`); j >= 0 {
			return rest[:j]
		}
	}
	return ""
}

// rawFileName gets the file name exactly as sent (Go's FileName() drops folders,
// which we do ourselves in safeName so the rules match the old server).
func rawFileName(p *multipart.Part) string {
	header := p.Header.Get("Content-Disposition")
	if _, params, err := mime.ParseMediaType(header); err == nil {
		return params["filename"]
	}
	// Some clients send names with unescaped quotes (filename="a "b".txt"). Be
	// forgiving like the old server: take everything up to the last quote.
	i := strings.Index(header, `filename="`)
	if i < 0 {
		return ""
	}
	rest := header[i+len(`filename="`):]
	j := strings.LastIndex(rest, `"`)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

func (srv *Server) writeUpload(src io.Reader, folder, dest string, replace bool, oldMtime float64,
	room *int64, tooBig error, s *session) (Entry, error) {
	tmp, err := os.CreateTemp(folder, ".upload-")
	if err != nil {
		return nil, err
	}
	tmpPath := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			tmp.Close()
			os.Remove(tmpPath)
		}
	}()
	buf := make([]byte, 1<<20)
	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			*room -= int64(n) // also enforced here: the size header can be missing or wrong
			if *room < 0 {
				return nil, tooBig
			}
			if _, err := tmp.Write(buf[:n]); err != nil {
				return nil, err
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return nil, fail(400, "The upload was cut off")
		}
	}
	if err := tmp.Sync(); err != nil {
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	_ = os.Chmod(tmpPath, 0o644)
	if replace {
		if err := srv.versions.Save(srv.versionKey(dest), dest); err != nil {
			return nil, err
		}
	}
	if err := os.Rename(tmpPath, dest); err != nil {
		return nil, err
	}
	ok = true
	if replace {
		newerMtime(dest, oldMtime)
	}
	e, err := entryFor(s.space, dest)
	if err != nil {
		return nil, err
	}
	// Fingerprint of what's actually on disk, so the app can confirm a perfect copy
	// before deleting anything from your computer.
	sum, err := sha256File(dest)
	if err != nil {
		return nil, err
	}
	e["sha256"] = sum
	return e, nil
}

func abs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}

func (srv *Server) mkdir(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Path string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	p, err := s.space.Resolve(body.Path)
	if err != nil {
		return nil, err
	}
	if exists(p) {
		return nil, fail(409, "Something with that name already exists")
	}
	if err := os.MkdirAll(p, 0o755); err != nil {
		return nil, err
	}
	return entryFor(s.space, p)
}

func (srv *Server) move(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Src, Dst string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	moved, err := moveItem(s.space, body.Src, body.Dst)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, fail(404, "Not found")
	case errors.Is(err, errExists):
		return nil, fail(409, "Something with that name already exists")
	case err != nil:
		return nil, err
	}
	newRel := s.space.Rel(moved)
	s.stars.Moved(strings.Trim(body.Src, "/"), newRel)
	srv.links.Moved(s.user.Username, strings.Trim(body.Src, "/"), newRel)
	srv.forgetUsage(s.user.Username)
	e, err := entryFor(s.space, moved)
	if err != nil {
		return nil, err
	}
	return srv.mark(s, []Entry{e})[0], nil
}

func (srv *Server) delete(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Path string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	if err := trashItem(s.space, body.Path); err != nil {
		return nil, notFound(err, "Not found")
	}
	srv.forgetUsage(s.user.Username)
	return nil, nil
}

func (srv *Server) trashRestore(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Name string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	p, err := restoreItem(s.space, body.Name)
	if err != nil {
		return nil, notFound(err, "Not in the trash")
	}
	srv.forgetUsage(s.user.Username)
	e, err := entryFor(s.space, p)
	if err != nil {
		return nil, err
	}
	return srv.mark(s, []Entry{e})[0], nil
}

func (srv *Server) trashDelete(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Name string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	if err := deleteForever(s.space, body.Name); err != nil {
		return nil, notFound(err, "Not in the trash")
	}
	return nil, nil
}

// ---------------------------------------------------------------- versions

func (srv *Server) listVersions(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	p, err := s.space.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(p)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fail(404, "File not found")
	}
	found := srv.versions.List(srv.versionKey(p))
	sort.Slice(found, func(i, j int) bool { return found[i]["modified"].(float64) > found[j]["modified"].(float64) })
	return map[string]any{"current": map[string]any{"modified": fileTime(info), "size": info.Size()}, "versions": found}, nil
}

func (srv *Server) versionFile(p, version string) (string, error) {
	source, id, _ := strings.Cut(version, ":")
	if source == "edit" {
		if f := srv.versions.Path(srv.versionKey(p), id); f != "" {
			return f, nil
		}
	}
	return "", fail(404, "That version isn't available")
}

func (srv *Server) downloadVersion(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	p, err := s.space.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		return nil, err
	}
	f, err := srv.versionFile(p, r.URL.Query().Get("version"))
	if err != nil {
		return nil, err
	}
	serveFile(w, r, f, filepath.Base(p), nil)
	return handled{}, nil
}

func (srv *Server) restoreVersion(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct{ Path, Version string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	p, err := s.space.Resolve(body.Path)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(p)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fail(404, "File not found")
	}
	old, err := srv.versionFile(p, body.Version)
	if err != nil {
		return nil, err
	}
	tmp := filepath.Join(filepath.Dir(p), ".upload-"+randomHex(6))
	if err := copyFile(old, tmp); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	before := fileTime(info)
	if err := srv.versions.Save(srv.versionKey(p), p); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	// The restored file gets a new time, so it shows in Recent and offline copies update.
	newerMtime(p, max(before, now()-0.05))
	e, err := entryFor(s.space, p)
	if err != nil {
		return nil, err
	}
	return srv.mark(s, []Entry{e})[0], nil
}

// ---------------------------------------------------------------- share links

func (srv *Server) shareURL(token string) any {
	if srv.cfg.PublicURL == "" {
		return nil
	}
	return srv.cfg.PublicURL + "/s/" + token
}

func (srv *Server) shareJSON(sh *Share, s *session) map[string]any {
	ok := false
	if p, err := s.space.Resolve(sh.Path); err == nil {
		ok = exists(p)
	}
	var locked any
	if t := srv.links.LockedUntil(sh.Token); t > 0 {
		locked = t
	}
	return map[string]any{
		"token": sh.Token, "path": sh.Path, "name": filepath.Base(sh.Path), "is_dir": sh.IsDir,
		"created": sh.Created, "expires": sh.Expires, "has_password": sh.HasPassword(),
		"downloads": sh.Downloads, "active": sh.Active() && ok, "url": srv.shareURL(sh.Token),
		"recent_downloads": srv.links.RecentDownloads(sh, 10), "locked_until": locked,
	}
}

func (srv *Server) createShare(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct {
		Path        string   `json:"path"`
		ExpiresDays *float64 `json:"expires_days"`
		Password    *string  `json:"password"`
	}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	p, err := s.space.Resolve(body.Path)
	if err != nil {
		return nil, err
	}
	if !exists(p) || s.space.IsTop(p) {
		return nil, fail(404, "Not found")
	}
	var expires *float64
	if body.ExpiresDays != nil && *body.ExpiresDays > 0 {
		e := now() + *body.ExpiresDays*86400
		expires = &e
	}
	pw := ""
	if body.Password != nil {
		pw = *body.Password
	}
	sh, err := srv.links.Add(s.user.Username, s.user.IsAdmin, s.space.Rel(p), isDir(p), expires, pw)
	if err != nil {
		return nil, err
	}
	return srv.shareJSON(sh, s), nil
}

func (srv *Server) myShares(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	out := []map[string]any{}
	for _, sh := range srv.links.ListFor(s.user.Username) {
		out = append(out, srv.shareJSON(sh, s))
	}
	return map[string]any{"links_enabled": srv.cfg.PublicURL != "", "shares": out}, nil
}

func (srv *Server) linksStatus(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var public any
	if srv.cfg.PublicURL != "" {
		public = srv.cfg.PublicURL
	}
	return map[string]any{
		"enabled": srv.cfg.PublicURL != "", "public_url": public, "agent_installed": true,
		"pending": false, "state": "idle", "message": nil, "approve_url": nil, "updated": nil,
	}, nil
}

// ---------------------------------------------------------------- accounts

func (srv *Server) userJSON(u *User) map[string]any {
	var used any
	if !u.IsAdmin {
		used = srv.usage(u.Username, srv.spaceFor(u.Username, false, true).Home, false)
	}
	return map[string]any{"username": u.Username, "is_admin": u.IsAdmin, "quota": u.QuotaBytes, "used": used}
}

func quotaBytes(gbValue *float64) *int64 {
	if gbValue == nil || *gbValue <= 0 {
		return nil
	}
	b := int64(*gbValue * gb)
	return &b
}

func (srv *Server) addUser(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	var body struct {
		Username string   `json:"username"`
		Password string   `json:"password"`
		QuotaGB  *float64 `json:"quota_gb"`
	}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	u, err := srv.users.Add(strings.ToLower(strings.TrimSpace(body.Username)), body.Password, false, quotaBytes(body.QuotaGB))
	if errors.Is(err, errTaken) {
		return nil, fail(409, "That username is taken")
	}
	if err != nil {
		return nil, fail(400, err.Error())
	}
	return srv.userJSON(u), nil
}

func (srv *Server) resetPassword(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	name := r.PathValue("username")
	var body struct{ Password string }
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	u := srv.users.Get(name)
	if u == nil {
		return nil, fail(404, "No such user")
	}
	if u.IsAdmin {
		return nil, fail(400, "Change the admin password in the HomeDrive server app.")
	}
	if err := srv.users.SetPassword(name, body.Password); err != nil {
		return nil, fail(400, err.Error())
	}
	return nil, nil
}

func (srv *Server) setQuota(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	name := r.PathValue("username")
	var body struct {
		QuotaGB *float64 `json:"quota_gb"`
	}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	if srv.users.Get(name) == nil {
		return nil, fail(404, "No such user")
	}
	if err := srv.users.SetQuota(name, quotaBytes(body.QuotaGB)); err != nil {
		return nil, err
	}
	return srv.userJSON(srv.users.Get(name)), nil
}

func (srv *Server) deleteUser(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
	name := r.PathValue("username")
	u := srv.users.Get(name)
	if u == nil {
		return nil, fail(404, "No such user")
	}
	if u.IsAdmin {
		return nil, fail(400, "The admin account can't be deleted")
	}
	if err := srv.users.Delete(name); err != nil {
		return nil, err
	}
	srv.links.RevokeAllFor(name)
	srv.devices.RemoveAllFor(name)
	srv.mu.Lock()
	delete(srv.stars, name)
	srv.mu.Unlock()
	return nil, nil // their files stay in Users/<name> for the admin
}

// ---------------------------------------------------------------- cleanup

// cleanUpOld empties trash older than CleanupDays in every account, and old versions.
func (srv *Server) cleanUpOld() (int, int) {
	days := srv.cfg.CleanupDays
	dirs := []string{filepath.Join(srv.cfg.FilesRoot, trashName)}
	if entries, err := os.ReadDir(filepath.Join(srv.cfg.FilesRoot, usersDir)); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				dirs = append(dirs, filepath.Join(srv.cfg.FilesRoot, usersDir, e.Name(), trashName))
			}
		}
	}
	trash := 0
	for _, d := range dirs {
		trash += purgeOldTrash(d, days)
	}
	return trash, srv.versions.PurgeOlderThan(days)
}

var _ = url.QueryEscape
