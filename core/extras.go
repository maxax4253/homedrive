package main

// Rate limiting, streaming zips and photo thumbnails.

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"image"
	"image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------- limiter

// Limiter counts recent events per key (an address, an account) in a sliding window.
type Limiter struct {
	mu          sync.Mutex
	hits        map[string][]time.Time
	forgetAfter time.Duration
}

func NewLimiter(forgetAfter time.Duration) *Limiter {
	return &Limiter{hits: map[string][]time.Time{}, forgetAfter: forgetAfter}
}

func (l *Limiter) prune(key string, window time.Duration) []time.Time {
	cutoff := time.Now().Add(-window)
	q := l.hits[key]
	i := 0
	for i < len(q) && q[i].Before(cutoff) {
		i++
	}
	q = q[i:]
	l.hits[key] = q
	if len(l.hits) > 20000 { // forget quiet visitors so memory can't grow forever
		old := time.Now().Add(-l.forgetAfter)
		for k, v := range l.hits {
			if len(v) == 0 || v[len(v)-1].Before(old) {
				delete(l.hits, k)
			}
		}
	}
	return q
}

// Allow says whether key is under limit events per window; record=true counts this one.
func (l *Limiter) Allow(key string, limit int, window time.Duration, record bool) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	q := l.prune(key, window)
	if len(q) >= limit {
		return false
	}
	if record {
		l.hits[key] = append(q, time.Now())
	}
	return true
}

func (l *Limiter) Record(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.hits[key] = append(l.hits[key], time.Now())
}

func (l *Limiter) Clear(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.hits, key)
}

// ---------------------------------------------------------------- zip

type zipItem struct {
	path string // absolute
	name string // name inside the zip
}

// writeZip streams a zip of files and folders (stored, not compressed: fast, and
// photos and videos are already compressed). Hidden things and symlinks are skipped.
func writeZip(w io.Writer, items []zipItem) error {
	zw := zip.NewWriter(w)
	for _, it := range items {
		if isDir(it.path) {
			empty := true
			var err error
			visibleFiles(it.path, func(p string) bool {
				empty = false
				rel, _ := filepath.Rel(it.path, p)
				err = addZipFile(zw, p, it.name+"/"+filepath.ToSlash(rel))
				return err == nil
			})
			if err != nil {
				return err
			}
			if empty {
				if _, err := zw.Create(strings.TrimSuffix(it.name, "/") + "/"); err != nil {
					return err
				}
			}
		} else if isFile(it.path) {
			if err := addZipFile(zw, it.path, it.name); err != nil {
				return err
			}
		}
	}
	return zw.Close()
}

func addZipFile(zw *zip.Writer, path, name string) error {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil
	}
	hdr, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	hdr.Name = name
	hdr.Method = zip.Store
	w, err := zw.CreateHeader(hdr)
	if err != nil {
		return err
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(w, f)
	return err
}

// ---------------------------------------------------------------- thumbnails

var thumbTypes = map[string]bool{".jpg": true, ".jpeg": true, ".png": true, ".gif": true}

const maxThumbSource = 200 << 20

func makeThumbnail(src, dst string, size int) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	head := make([]byte, 64<<10)
	n, _ := io.ReadFull(f, head)
	head = head[:n]
	cfg, _, err := image.DecodeConfig(bytes.NewReader(head))
	if err == nil && cfg.Width*cfg.Height > 100_000_000 {
		return errTooBig // refuse "decompression bombs"
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	img, _, err := image.Decode(f)
	if err != nil {
		return err
	}
	// Shrink first, then turn: much faster than turning a full-size photo.
	t := applyOrientation(resize(img, size), jpegOrientation(head))
	tmp := dst + ".tmp-" + randomHex(4)
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := jpeg.Encode(out, t, &jpeg.Options{Quality: 82}); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	out.Close()
	return os.Rename(tmp, dst)
}

var errTooBig = &PathError{"image too big"}

// resize scales down to fit in size x size (box filter: good enough for thumbnails).
func resize(src image.Image, size int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= size && h <= size {
		dst := image.NewRGBA(image.Rect(0, 0, w, h))
		draw.Draw(dst, dst.Bounds(), src, b.Min, draw.Src)
		return dst
	}
	scale := float64(size) / float64(max(w, h))
	nw, nh := max(1, int(float64(w)*scale)), max(1, int(float64(h)*scale))
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := b.Min.Y+y*h/nh, b.Min.Y+(y+1)*h/nh
		for x := 0; x < nw; x++ {
			x0, x1 := b.Min.X+x*w/nw, b.Min.X+(x+1)*w/nw
			var r, g, bl, a, n uint64
			stepY, stepX := max(1, (y1-y0)/4), max(1, (x1-x0)/4) // sample, don't average every pixel
			for yy := y0; yy < y1; yy += stepY {
				for xx := x0; xx < x1; xx += stepX {
					cr, cg, cb, ca := src.At(xx, yy).RGBA()
					r, g, bl, a, n = r+uint64(cr), g+uint64(cg), bl+uint64(cb), a+uint64(ca), n+1
				}
			}
			if n == 0 {
				continue
			}
			i := dst.PixOffset(x, y)
			dst.Pix[i], dst.Pix[i+1], dst.Pix[i+2], dst.Pix[i+3] =
				uint8(r/n>>8), uint8(g/n>>8), uint8(bl/n>>8), uint8(a/n>>8)
		}
	}
	return dst
}

// jpegOrientation reads the EXIF orientation tag (1-8) from the start of a JPEG.
func jpegOrientation(b []byte) int {
	if len(b) < 4 || b[0] != 0xFF || b[1] != 0xD8 {
		return 1
	}
	i := 2
	for i+4 <= len(b) {
		if b[i] != 0xFF {
			return 1
		}
		marker := b[i+1]
		size := int(binary.BigEndian.Uint16(b[i+2:]))
		if marker == 0xE1 && i+4+size <= len(b) && size > 8 && string(b[i+4:i+10]) == "Exif\x00\x00" {
			return exifOrientation(b[i+10 : i+2+size])
		}
		if marker == 0xDA {
			return 1
		}
		i += 2 + size
	}
	return 1
}

func exifOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var bo binary.ByteOrder = binary.BigEndian
	if string(t[:2]) == "II" {
		bo = binary.LittleEndian
	}
	off := int(bo.Uint32(t[4:]))
	if off+2 > len(t) {
		return 1
	}
	n := int(bo.Uint16(t[off:]))
	for k := 0; k < n; k++ {
		e := off + 2 + k*12
		if e+12 > len(t) {
			return 1
		}
		if bo.Uint16(t[e:]) == 0x0112 {
			v := int(bo.Uint16(t[e+8:]))
			if v >= 1 && v <= 8 {
				return v
			}
		}
	}
	return 1
}

func applyOrientation(src image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return src
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	dw, dh := w, h
	if o >= 5 {
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var nx, ny int
			switch o {
			case 2:
				nx, ny = w-1-x, y
			case 3:
				nx, ny = w-1-x, h-1-y
			case 4:
				nx, ny = x, h-1-y
			case 5:
				nx, ny = y, x
			case 6:
				nx, ny = h-1-y, x
			case 7:
				nx, ny = h-1-y, w-1-x
			case 8:
				nx, ny = y, w-1-x
			}
			dst.Set(nx, ny, src.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return dst
}
