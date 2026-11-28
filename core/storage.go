package main

// File operations, always confined to one person's space. Same rules and same
// on-disk layout as the Python server (trash index, Shared folder, hidden names).

import (
	"container/heap"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	trashName  = ".trash"
	sharedName = "Shared"
	indexName  = ".index.json"
	uploadTmp  = ".upload-tmp"
	usersDir   = "Users"
)

var reserved = map[string]bool{trashName: true, uploadTmp: true}

type PathError struct{ msg string }

func (e *PathError) Error() string { return e.msg }

func pathErr(msg string) error { return &PathError{msg} }

// Space is what one person can see: their home folder plus (for everyone but the
// admin) the Shared folder, which shows up as "Shared" at the top of their drive.
type Space struct {
	Home   string
	Shared string
	mapped bool
}

func NewSpace(home, shared string) *Space {
	h := mustAbs(home)
	s := ""
	if shared != "" {
		s = mustAbs(shared)
	}
	return &Space{Home: h, Shared: s, mapped: s != "" && !inside(s, h)}
}

func mustAbs(p string) string {
	a, err := filepath.Abs(p)
	if err != nil {
		return filepath.Clean(p)
	}
	if r, err := filepath.EvalSymlinks(a); err == nil {
		return r
	}
	return a
}

func inside(p, base string) bool {
	return p == base || strings.HasPrefix(p, base+string(os.PathSeparator))
}

func badChar(name string) bool {
	for _, c := range name {
		if c < 32 || c == 127 {
			return true
		}
	}
	return !utf8.ValidString(name)
}

// realPath resolves symlinks in the existing part of p, so a link can't lead outside.
func realPath(p string) string {
	p = filepath.Clean(p)
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	// The last parts don't exist yet: resolve the longest existing prefix.
	dir, rest := filepath.Split(p)
	if dir == "" || dir == p {
		return p
	}
	return filepath.Join(realPath(strings.TrimSuffix(dir, string(os.PathSeparator))), rest)
}

// Resolve turns a client path like "Photos/a.jpg" into a safe absolute path.
func (s *Space) Resolve(rel string) (string, error) {
	rel = strings.Trim(rel, "/") // only slashes: names may really start or end with a space
	parts := strings.Split(rel, "/")
	for _, part := range parts {
		if reserved[part] {
			return "", pathErr("That folder is managed by HomeDrive")
		}
		if badChar(part) {
			return "", pathErr("File names can't contain control characters")
		}
		if len(part) > 255 {
			return "", pathErr("That name is too long")
		}
	}
	if len(rel) > 3000 {
		return "", pathErr("That name is too long")
	}
	base, sub := s.Home, rel
	if s.mapped {
		first, rest, _ := strings.Cut(rel, "/")
		if first == sharedName {
			base, sub = s.Shared, rest
		}
	}
	target := realPath(filepath.Join(base, filepath.FromSlash(sub)))
	if !inside(target, base) {
		return "", pathErr("Path is outside your drive")
	}
	return target, nil
}

func (s *Space) Rel(p string) string {
	if s.mapped && inside(p, s.Shared) {
		if p == s.Shared {
			return sharedName
		}
		r, _ := filepath.Rel(s.Shared, p)
		return sharedName + "/" + filepath.ToSlash(r)
	}
	if p == s.Home {
		return ""
	}
	r, _ := filepath.Rel(s.Home, p)
	return filepath.ToSlash(r)
}

func (s *Space) IsTop(p string) bool {
	return p == s.Home || (s.mapped && p == s.Shared)
}

func (s *Space) Roots() []string {
	if s.mapped {
		return []string{s.Home, s.Shared}
	}
	return []string{s.Home}
}

func (s *Space) TrashDir() string {
	d := filepath.Join(s.Home, trashName)
	_ = os.MkdirAll(d, 0o755)
	return d
}

// ---------------------------------------------------------------- entries

type Entry map[string]any

func mimeFor(name string) string {
	if t := mime.TypeByExtension(strings.ToLower(filepath.Ext(name))); t != "" {
		if i := strings.Index(t, ";"); i >= 0 {
			t = t[:i]
		}
		return t
	}
	return "application/octet-stream"
}

func fileTime(info fs.FileInfo) float64 {
	return float64(info.ModTime().UnixNano()) / 1e9
}

func entryFor(s *Space, p string) (Entry, error) {
	info, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	e := Entry{
		"name":     filepath.Base(p),
		"path":     s.Rel(p),
		"is_dir":   info.IsDir(),
		"size":     int64(0),
		"modified": fileTime(info),
		"mime":     nil,
	}
	if !info.IsDir() {
		e["size"] = info.Size()
		e["mime"] = mimeFor(p)
	}
	return e, nil
}

func sortEntries(items []Entry) {
	sort.SliceStable(items, func(i, j int) bool {
		di, dj := items[i]["is_dir"].(bool), items[j]["is_dir"].(bool)
		if di != dj {
			return di
		}
		return strings.ToLower(items[i]["name"].(string)) < strings.ToLower(items[j]["name"].(string))
	})
}

func listDir(s *Space, rel string, showHidden bool) ([]Entry, error) {
	d, err := s.Resolve(rel)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(d)
	if err != nil || !info.IsDir() {
		return nil, fs.ErrNotExist
	}
	children, err := os.ReadDir(d)
	if err != nil {
		return nil, err
	}
	items := []Entry{}
	for _, c := range children {
		if !showHidden && strings.HasPrefix(c.Name(), ".") {
			continue
		}
		if e, err := entryFor(s, filepath.Join(d, c.Name())); err == nil {
			items = append(items, e)
		}
	}
	if d == s.Home && s.mapped {
		if info, err := os.Stat(s.Shared); err == nil && info.IsDir() {
			if e, err := entryFor(s, s.Shared); err == nil {
				items = append(items, e)
			}
		}
	}
	sortEntries(items)
	return items, nil
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

// uniquePath: "a.txt" -> "a (1).txt" if a.txt already exists.
func uniquePath(p string) string {
	if !exists(p) {
		return p
	}
	dir, name := filepath.Split(p)
	stem, ext := name, ""
	if !isDir(p) {
		ext = filepath.Ext(name)
		stem = strings.TrimSuffix(name, ext)
	}
	for n := 1; ; n++ {
		c := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, n, ext))
		if !exists(c) {
			return c
		}
	}
}

func safeName(name string) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	if name == "" || name == "." || name == ".." || reserved[name] || badChar(name) {
		return "", pathErr("Bad file name")
	}
	if len(name) > 255 {
		return "", pathErr("That file name is too long")
	}
	return name, nil
}

var errExists = errors.New("exists")

func moveItem(s *Space, src, dst string) (string, error) {
	sp, err := s.Resolve(src)
	if err != nil {
		return "", err
	}
	dp, err := s.Resolve(dst)
	if err != nil {
		return "", err
	}
	if s.IsTop(sp) {
		return "", pathErr("Can't move that folder")
	}
	if !exists(sp) {
		return "", fs.ErrNotExist
	}
	if dp == sp || inside(dp, sp) {
		return "", pathErr("Can't move a folder into itself")
	}
	if exists(dp) {
		return "", errExists
	}
	if err := os.MkdirAll(filepath.Dir(dp), 0o755); err != nil {
		return "", err
	}
	if err := moveAcross(sp, dp); err != nil {
		return "", err
	}
	return dp, nil
}

// moveAcross renames, or copies then deletes when the two are on different disks.
func moveAcross(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	if err := copyTree(src, dst); err != nil {
		_ = os.RemoveAll(dst)
		return err
	}
	return os.RemoveAll(src)
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		case d.Type()&fs.ModeSymlink != 0:
			return nil // never carry symlinks along
		default:
			if err := copyFile(p, target); err != nil {
				return err
			}
			return os.Chtimes(target, info.ModTime(), info.ModTime())
		}
	})
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// ---------------------------------------------------------------- trash

type trashInfo struct {
	Original string  `json:"original"`
	Deleted  float64 `json:"deleted"`
}

func loadIndex(dir string) map[string]trashInfo {
	idx := map[string]trashInfo{}
	if b, err := os.ReadFile(filepath.Join(dir, indexName)); err == nil {
		_ = json.Unmarshal(b, &idx)
	}
	return idx
}

func saveIndex(dir string, idx map[string]trashInfo) error {
	b, _ := json.Marshal(idx)
	return writeAtomic(filepath.Join(dir, indexName), b, 0o644)
}

func writeAtomic(path string, data []byte, perm fs.FileMode) error {
	tmp := path + ".tmp-" + randomHex(4)
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func now() float64 { return float64(time.Now().UnixNano()) / 1e9 }

func trashItem(s *Space, rel string) error {
	p, err := s.Resolve(rel)
	if err != nil {
		return err
	}
	if s.IsTop(p) {
		return pathErr("Can't delete that folder")
	}
	if !exists(p) {
		return fs.ErrNotExist
	}
	dir := s.TrashDir()
	original := s.Rel(p)
	dest := uniquePath(filepath.Join(dir, filepath.Base(p)))
	if err := moveAcross(p, dest); err != nil {
		return err
	}
	idx := loadIndex(dir)
	idx[filepath.Base(dest)] = trashInfo{Original: original, Deleted: now()}
	return saveIndex(dir, idx)
}

func listTrash(s *Space) []Entry {
	dir := s.TrashDir()
	idx := loadIndex(dir)
	items := []Entry{}
	children, _ := os.ReadDir(dir)
	for _, c := range children {
		if strings.HasPrefix(c.Name(), ".index") {
			continue
		}
		p := filepath.Join(dir, c.Name())
		e, err := entryFor(s, p)
		if err != nil {
			continue
		}
		info := idx[c.Name()]
		e["trash_name"] = c.Name()
		e["original"] = info.Original
		if info.Original == "" {
			e["original"] = c.Name()
		}
		e["deleted"] = info.Deleted
		if info.Deleted == 0 {
			e["deleted"] = e["modified"]
		}
		items = append(items, e)
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i]["deleted"].(float64) > items[j]["deleted"].(float64) })
	return items
}

func trashed(s *Space, name string) (string, error) {
	n, err := safeName(name)
	if err != nil || strings.HasPrefix(n, ".index") {
		return "", fs.ErrNotExist
	}
	p := filepath.Join(s.TrashDir(), n)
	if !exists(p) {
		return "", fs.ErrNotExist
	}
	return p, nil
}

func restoreItem(s *Space, name string) (string, error) {
	p, err := trashed(s, name)
	if err != nil {
		return "", err
	}
	dir := s.TrashDir()
	idx := loadIndex(dir)
	original := idx[filepath.Base(p)].Original
	if original == "" {
		original = filepath.Base(p)
	}
	dest, err := s.Resolve(original)
	if err != nil {
		dest = filepath.Join(s.Home, filepath.Base(p))
	}
	_ = os.MkdirAll(filepath.Dir(dest), 0o755)
	dest = uniquePath(dest)
	if err := moveAcross(p, dest); err != nil {
		return "", err
	}
	delete(idx, filepath.Base(p))
	return dest, saveIndex(dir, idx)
}

func deleteForever(s *Space, name string) error {
	p, err := trashed(s, name)
	if err != nil {
		return err
	}
	if err := os.RemoveAll(p); err != nil {
		return err
	}
	dir := s.TrashDir()
	idx := loadIndex(dir)
	delete(idx, filepath.Base(p))
	return saveIndex(dir, idx)
}

func emptyTrash(s *Space) int {
	dir := s.TrashDir()
	children, _ := os.ReadDir(dir)
	count := 0
	for _, c := range children {
		if !strings.HasPrefix(c.Name(), ".index") {
			count++
		}
		_ = os.RemoveAll(filepath.Join(dir, c.Name()))
	}
	return count
}

// purgeOldTrash deletes things that have sat in a Trash folder longer than `days`.
func purgeOldTrash(dir string, days int) int {
	if days <= 0 || !isDir(dir) {
		return 0
	}
	cutoff := now() - float64(days)*86400
	idx := loadIndex(dir)
	removed := 0
	children, _ := os.ReadDir(dir)
	for _, c := range children {
		if strings.HasPrefix(c.Name(), ".index") {
			continue
		}
		deleted := idx[c.Name()].Deleted
		if deleted == 0 {
			if info, err := os.Lstat(filepath.Join(dir, c.Name())); err == nil {
				deleted = changeTime(info)
			}
		}
		if deleted < cutoff {
			if os.RemoveAll(filepath.Join(dir, c.Name())) == nil {
				delete(idx, c.Name())
				removed++
			}
		}
	}
	if removed > 0 {
		_ = saveIndex(dir, idx)
	}
	return removed
}

// ---------------------------------------------------------------- walking

// walk visits every visible file (and folder unless filesOnly), skipping hidden
// things, the trash and symlinks. skipTop names folders at the top of home to skip.
func walk(s *Space, filesOnly bool, skipTop map[string]bool, visit func(path string, info fs.FileInfo) bool) {
	for _, base := range s.Roots() {
		stop := false
		_ = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
			if err != nil || stop {
				if d != nil && d.IsDir() && p != base {
					return filepath.SkipDir
				}
				return nil
			}
			if p == base {
				return nil
			}
			name := d.Name()
			if strings.HasPrefix(name, ".") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			if d.IsDir() && filepath.Dir(p) == s.Home && skipTop[name] {
				return filepath.SkipDir
			}
			if d.IsDir() && filesOnly {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return nil
			}
			if !visit(p, info) {
				stop = true
				return filepath.SkipAll
			}
			return nil
		})
	}
}

type timedPath struct {
	t float64
	p string
}
type minHeap []timedPath

func (h minHeap) Len() int           { return len(h) }
func (h minHeap) Less(i, j int) bool { return h[i].t < h[j].t }
func (h minHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x any)        { *h = append(*h, x.(timedPath)) }
func (h *minHeap) Pop() any          { o := *h; x := o[len(o)-1]; *h = o[:len(o)-1]; return x }

func recentFiles(s *Space, limit int, skipTop map[string]bool) []Entry {
	h := &minHeap{}
	walk(s, true, skipTop, func(p string, info fs.FileInfo) bool {
		t := fileTime(info)
		if h.Len() < limit {
			heap.Push(h, timedPath{t, p})
		} else if t > (*h)[0].t {
			(*h)[0] = timedPath{t, p}
			heap.Fix(h, 0)
		}
		return true
	})
	items := make([]timedPath, h.Len())
	copy(items, *h)
	sort.Slice(items, func(i, j int) bool { return items[i].t > items[j].t })
	out := []Entry{}
	for _, it := range items {
		if e, err := entryFor(s, it.p); err == nil {
			out = append(out, e)
		}
	}
	return out
}

func searchFiles(s *Space, query string, limit int, skipTop map[string]bool) []Entry {
	q := strings.ToLower(strings.TrimSpace(query))
	out := []Entry{}
	if q == "" {
		return out
	}
	walk(s, false, skipTop, func(p string, info fs.FileInfo) bool {
		if strings.Contains(strings.ToLower(filepath.Base(p)), q) {
			if e, err := entryFor(s, p); err == nil {
				out = append(out, e)
			}
		}
		return len(out) < limit
	})
	sortEntries(out)
	return out
}

// treeFiles lists every file under a folder (for offline copies).
func treeFiles(s *Space, base string) []Entry {
	if isFile(base) {
		if e, err := entryFor(s, base); err == nil {
			return []Entry{e}
		}
		return []Entry{}
	}
	out := []Entry{}
	_ = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if p != base && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if e, err := entryFor(s, p); err == nil {
			out = append(out, e)
		}
		return nil
	})
	return out
}

func folderSize(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.Type().IsRegular() {
			if info, err := d.Info(); err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func thumbKey(p string, info fs.FileInfo, size int) string {
	raw := fmt.Sprintf("%s:%d:%d:%d", p, info.ModTime().UnixNano(), info.Size(), size)
	sum := sha1.Sum([]byte(raw)) // a cache file name, not security
	return hex.EncodeToString(sum[:])
}

// visibleFiles lists regular files under a folder, skipping hidden things and symlinks.
func visibleFiles(folder string, visit func(path string) bool) {
	_ = filepath.WalkDir(folder, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if p != folder && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() {
			if !visit(p) {
				return filepath.SkipAll
			}
		}
		return nil
	})
}
