package main

// Accounts, share links, stars and version history.
//
// Kept as small JSON files (no database to install or corrupt). Every change is
// written to a temporary file and swapped in, so a power cut never leaves half a file.

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

var usernameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,31}$`)

const recommendedPassword = 8 // shorter is allowed; the apps warn

type User struct {
	Username     string  `json:"username"`
	PwHash       string  `json:"pw_hash"`
	IsAdmin      bool    `json:"is_admin"`
	QuotaBytes   *int64  `json:"quota_bytes"`
	TokenVersion int     `json:"token_version"`
	Created      float64 `json:"created"`
}

type jsonFile[T any] struct {
	path string
	mu   sync.Mutex
	data T
}

func openJSON[T any](path string, empty T) (*jsonFile[T], error) {
	f := &jsonFile[T]{path: path, data: empty}
	b, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(b, &f.data); err != nil {
			return nil, fmt.Errorf("%s is damaged: %w", path, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return f, nil
}

func (f *jsonFile[T]) save() error {
	b, err := json.MarshalIndent(f.data, "", " ")
	if err != nil {
		return err
	}
	return writeAtomic(f.path, b, 0o600)
}

// ---------------------------------------------------------------- users

type Users struct {
	f *jsonFile[map[string]*User]
}

func OpenUsers(dataDir string) (*Users, error) {
	f, err := openJSON(filepath.Join(dataDir, "users.json"), map[string]*User{})
	if err != nil {
		return nil, err
	}
	return &Users{f}, nil
}

func copyUser(u *User) *User {
	if u == nil {
		return nil
	}
	c := *u
	return &c
}

func (us *Users) Get(name string) *User {
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	return copyUser(us.f.data[name])
}

func (us *Users) List() []*User {
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	out := []*User{}
	for _, u := range us.f.data {
		out = append(out, copyUser(u))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsAdmin != out[j].IsAdmin {
			return out[i].IsAdmin
		}
		return out[i].Username < out[j].Username
	})
	return out
}

var dummyHash = hashPassword("timing-equalizer")

func (us *Users) CheckLogin(name, password string) *User {
	u := us.Get(name)
	if u == nil {
		verifyPassword(password, dummyHash) // same time as a real check: usernames can't be probed
		return nil
	}
	if !verifyPassword(password, u.PwHash) {
		return nil
	}
	return u
}

var errTaken = errors.New("taken")

func checkNewPassword(pw string) error {
	if pw == "" {
		return errors.New("Password can't be empty.")
	}
	return nil
}

func (us *Users) Add(name, password string, isAdmin bool, quota *int64) (*User, error) {
	if !usernameRE.MatchString(name) {
		return nil, errors.New("Usernames are lowercase letters, numbers, dots, dashes or underscores (max 32).")
	}
	if err := checkNewPassword(password); err != nil {
		return nil, err
	}
	hash := hashPassword(password)
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	if _, ok := us.f.data[name]; ok {
		return nil, errTaken
	}
	u := &User{Username: name, PwHash: hash, IsAdmin: isAdmin, QuotaBytes: quota, TokenVersion: 1, Created: now()}
	us.f.data[name] = u
	return copyUser(u), us.f.save()
}

// SetPassword also signs that person out everywhere (old logins stop working).
func (us *Users) SetPassword(name, password string) error {
	if err := checkNewPassword(password); err != nil {
		return err
	}
	hash := hashPassword(password)
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	u := us.f.data[name]
	if u == nil {
		return os.ErrNotExist
	}
	u.PwHash = hash
	u.TokenVersion++
	return us.f.save()
}

func (us *Users) SetQuota(name string, quota *int64) error {
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	u := us.f.data[name]
	if u == nil {
		return os.ErrNotExist
	}
	u.QuotaBytes = quota
	return us.f.save()
}

func (us *Users) Delete(name string) error {
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	delete(us.f.data, name)
	return us.f.save()
}

// EnsureAdmin keeps the admin account in step with the server's settings.
func (us *Users) EnsureAdmin(name, password string) error {
	us.f.mu.Lock()
	u := us.f.data[name]
	us.f.mu.Unlock()
	if u == nil {
		_, err := us.Add(name, password, true, nil)
		if errors.Is(err, errTaken) {
			return nil
		}
		return err
	}
	if password == "" || (verifyPassword(password, u.PwHash) && u.IsAdmin) {
		return nil
	}
	hash := hashPassword(password)
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	u.PwHash, u.IsAdmin = hash, true
	u.TokenVersion++
	return us.f.save()
}

// Import adds an account copied from the old server as-is (password hash included).
func (us *Users) Import(u *User) error {
	us.f.mu.Lock()
	defer us.f.mu.Unlock()
	if _, ok := us.f.data[u.Username]; ok {
		return nil
	}
	us.f.data[u.Username] = copyUser(u)
	return us.f.save()
}

// ---------------------------------------------------------------- share links

const (
	linkFailures    = 10  // wrong passwords for one link (from anyone)...
	linkLockSeconds = 900 // ...within 15 minutes pause it for 15 minutes
	keepDownloadLog = 200 // newest downloads remembered per link
)

type Download struct {
	Time float64 `json:"time"`
	IP   string  `json:"ip"`
}

type Share struct {
	Token        string     `json:"token"`
	Owner        string     `json:"owner"`
	OwnerIsAdmin bool       `json:"owner_is_admin"`
	Path         string     `json:"path"`
	IsDir        bool       `json:"is_dir"`
	Created      float64    `json:"created"`
	Expires      *float64   `json:"expires"`
	PwHash       *string    `json:"pw_hash"`
	Downloads    int        `json:"downloads"`
	Revoked      bool       `json:"revoked"`
	Log          []Download `json:"log,omitempty"`
	Failures     []float64  `json:"failures,omitempty"`
}

func (s *Share) HasPassword() bool { return s.PwHash != nil }

func (s *Share) Active() bool {
	return !s.Revoked && (s.Expires == nil || *s.Expires > now())
}

type Links struct {
	f *jsonFile[map[string]*Share]
}

func OpenLinks(dataDir string) (*Links, error) {
	dir := filepath.Join(dataDir, "links")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	f, err := openJSON(filepath.Join(dir, "links.json"), map[string]*Share{})
	if err != nil {
		return nil, err
	}
	return &Links{f}, nil
}

func copyShare(s *Share) *Share {
	if s == nil {
		return nil
	}
	c := *s
	c.Log = append([]Download(nil), s.Log...)
	c.Failures = append([]float64(nil), s.Failures...)
	return &c
}

func (l *Links) Add(owner string, ownerIsAdmin bool, path string, isDir bool, expires *float64, password string) (*Share, error) {
	var pw *string
	if password != "" {
		h := hashPassword(password)
		pw = &h
	}
	s := &Share{Token: randomToken(24), Owner: owner, OwnerIsAdmin: ownerIsAdmin, Path: path, IsDir: isDir,
		Created: now(), Expires: expires, PwHash: pw}
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	l.f.data[s.Token] = s
	return copyShare(s), l.f.save()
}

func (l *Links) Get(token string) *Share {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	return copyShare(l.f.data[token])
}

func (l *Links) ListFor(owner string) []*Share {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	out := []*Share{}
	for _, s := range l.f.data {
		if s.Owner == owner && !s.Revoked {
			out = append(out, copyShare(s))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	return out
}

func (l *Links) Revoke(token, owner string) bool {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	s := l.f.data[token]
	if s == nil || s.Owner != owner || s.Revoked {
		return false
	}
	s.Revoked = true
	_ = l.f.save()
	return true
}

func (l *Links) RevokeAllFor(owner string) {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	for _, s := range l.f.data {
		if s.Owner == owner {
			s.Revoked = true
		}
	}
	_ = l.f.save()
}

// Moved keeps links working when the shared file (or a folder above it) is renamed or moved.
func (l *Links) Moved(owner, old, new string) {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	changed := false
	for _, s := range l.f.data {
		if s.Owner == owner && !s.Revoked && (s.Path == old || strings.HasPrefix(s.Path, old+"/")) {
			s.Path = new + s.Path[len(old):]
			changed = true
		}
	}
	if changed {
		_ = l.f.save()
	}
}

func (l *Links) CountDownload(token, ip string) {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	s := l.f.data[token]
	if s == nil {
		return
	}
	s.Downloads++
	s.Log = append(s.Log, Download{now(), ip})
	if len(s.Log) > keepDownloadLog {
		s.Log = s.Log[len(s.Log)-keepDownloadLog:]
	}
	_ = l.f.save()
}

func (l *Links) RecentDownloads(s *Share, n int) []Download {
	out := []Download{}
	for i := len(s.Log) - 1; i >= 0 && len(out) < n; i-- {
		out = append(out, s.Log[i])
	}
	return out
}

// LockedUntil: when a link paused after too many wrong passwords opens again (0 = not paused).
func (l *Links) LockedUntil(token string) float64 {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	s := l.f.data[token]
	if s == nil {
		return 0
	}
	recent := []float64{}
	for _, t := range s.Failures {
		if t > now()-linkLockSeconds {
			recent = append(recent, t)
		}
	}
	if len(recent) < linkFailures {
		return 0
	}
	sort.Float64s(recent)
	return recent[len(recent)-1] + linkLockSeconds
}

func (l *Links) RecordFailure(token string) {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	s := l.f.data[token]
	if s == nil {
		return
	}
	keep := []float64{}
	for _, t := range s.Failures {
		if t > now()-2*linkLockSeconds {
			keep = append(keep, t)
		}
	}
	s.Failures = append(keep, now())
	_ = l.f.save()
}

// Import adds a link copied from the old server.
func (l *Links) Import(s *Share) {
	l.f.mu.Lock()
	defer l.f.mu.Unlock()
	if _, ok := l.f.data[s.Token]; !ok {
		l.f.data[s.Token] = copyShare(s)
		_ = l.f.save()
	}
}

// ---------------------------------------------------------------- stars

type Stars struct {
	path  string
	mu    sync.Mutex
	paths map[string]bool
}

func OpenStars(dataDir, filename string) *Stars {
	s := &Stars{path: filepath.Join(dataDir, filename), paths: map[string]bool{}}
	var list []string
	if b, err := os.ReadFile(s.path); err == nil && json.Unmarshal(b, &list) == nil {
		for _, p := range list {
			s.paths[p] = true
		}
	}
	return s
}

func (s *Stars) save() {
	list := make([]string, 0, len(s.paths))
	for p := range s.paths {
		list = append(list, p)
	}
	sort.Strings(list)
	b, _ := json.Marshal(list)
	_ = writeAtomic(s.path, b, 0o644)
}

func (s *Stars) Is(p string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.paths[p]
}

func (s *Stars) Set(p string, on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if on {
		s.paths[p] = true
	} else {
		delete(s.paths, p)
	}
	s.save()
}

func (s *Stars) Moved(old, new string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for p := range s.paths {
		if p == old || strings.HasPrefix(p, old+"/") {
			delete(s.paths, p)
			s.paths[new+p[len(old):]] = true
			changed = true
		}
	}
	if changed {
		s.save()
	}
}

func (s *Stars) All() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for p := range s.paths {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// ---------------------------------------------------------------- version history

type versionMeta struct {
	Modified float64 `json:"modified"`
	Size     int64   `json:"size"`
	Saved    float64 `json:"saved"`
}

// Versions keeps the previous copy each time a file is overwritten. Copies are
// stored by the file's place in the drive, so they survive moving the drive.
type Versions struct {
	root string
	keep int
	mu   sync.Mutex
}

func OpenVersions(dataDir string, keep int) *Versions {
	root := filepath.Join(dataDir, "versions")
	_ = os.MkdirAll(root, 0o700)
	return &Versions{root: root, keep: keep}
}

func (v *Versions) dir(key string) string {
	sum := sha1.Sum([]byte(key)) // a folder name, not security
	return filepath.Join(v.root, hex.EncodeToString(sum[:]))
}

func (v *Versions) meta(d string) map[string]versionMeta {
	m := map[string]versionMeta{}
	if b, err := os.ReadFile(filepath.Join(d, "meta.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return m
}

// Save copies the current file into history before it gets replaced.
func (v *Versions) Save(key, physical string) error {
	info, err := os.Stat(physical)
	if err != nil || !info.Mode().IsRegular() {
		return nil
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	d := v.dir(key)
	if err := os.MkdirAll(d, 0o700); err != nil {
		return err
	}
	id := fmt.Sprintf("%.6f", now())
	if err := copyFile(physical, filepath.Join(d, id)); err != nil {
		return err
	}
	m := v.meta(d)
	m[id] = versionMeta{Modified: fileTime(info), Size: info.Size(), Saved: now()}
	ids := make([]string, 0, len(m))
	for k := range m {
		ids = append(ids, k)
	}
	sort.Slice(ids, func(i, j int) bool { return m[ids[i]].Saved < m[ids[j]].Saved })
	for len(ids) > v.keep {
		_ = os.Remove(filepath.Join(d, ids[0]))
		delete(m, ids[0])
		ids = ids[1:]
	}
	b, _ := json.Marshal(m)
	return writeAtomic(filepath.Join(d, "meta.json"), b, 0o600)
}

func (v *Versions) List(key string) []Entry {
	d := v.dir(key)
	out := []Entry{}
	for id, m := range v.meta(d) {
		if exists(filepath.Join(d, id)) {
			out = append(out, Entry{"id": "edit:" + id, "source": "edit", "modified": m.Modified, "size": m.Size, "saved": m.Saved})
		}
	}
	return out
}

func (v *Versions) Path(key, id string) string {
	if strings.ContainsAny(id, `/\`) || strings.HasPrefix(id, ".") || id == "meta.json" {
		return ""
	}
	p := filepath.Join(v.dir(key), id)
	if !isFile(p) {
		return ""
	}
	return p
}

// PurgeOlderThan drops saved copies older than `days` (and folders left empty).
func (v *Versions) PurgeOlderThan(days int) int {
	if days <= 0 {
		return 0
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	cutoff := now() - float64(days)*86400
	removed := 0
	dirs, _ := os.ReadDir(v.root)
	for _, e := range dirs {
		if !e.IsDir() {
			continue
		}
		d := filepath.Join(v.root, e.Name())
		m := v.meta(d)
		changed := false
		for id, meta := range m {
			if meta.Saved < cutoff {
				_ = os.Remove(filepath.Join(d, id))
				delete(m, id)
				removed++
				changed = true
			}
		}
		if len(m) == 0 {
			_ = os.RemoveAll(d)
		} else if changed {
			b, _ := json.Marshal(m)
			_ = writeAtomic(filepath.Join(d, "meta.json"), b, 0o600)
		}
	}
	return removed
}
