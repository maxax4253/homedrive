package main

// Device pairing.
//
// Every device that uses HomeDrive must be paired once, with a 6-digit code made
// on the server computer (or on an already-paired device). Pairing gives the
// device its own secret key, sent with every request. A stolen password alone is
// useless without a paired device, and each device can be removed on its own.

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	codeLifetime    = 10 * time.Minute
	codeMaxGuesses  = 5  // wrong codes, from anyone, before every open code stops working
	pairPerIP       = 10 // pairing attempts per address...
	pairWindow      = 15 * time.Minute
	deviceHeader    = "X-HomeDrive-Device"
	badDeviceLimit  = 30 // wrong device keys per address per 10 minutes
	lastSeenEvery   = 5 * time.Minute
	maxDeviceName   = 60
	pairingRequired = "This device isn't paired with this HomeDrive yet. Get a pairing code from the server and sign in with it."
)

type Device struct {
	ID         string  `json:"id"`
	User       string  `json:"user"`
	Name       string  `json:"name"`
	SecretHash string  `json:"secret_hash"`
	Created    float64 `json:"created"`
	LastSeen   float64 `json:"last_seen"`
	LastIP     string  `json:"last_ip"`
}

type Devices struct {
	f *jsonFile[map[string]*Device]
}

func OpenDevices(dataDir string) (*Devices, error) {
	f, err := openJSON(filepath.Join(dataDir, "devices.json"), map[string]*Device{})
	if err != nil {
		return nil, err
	}
	return &Devices{f}, nil
}

func hashSecret(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// Add creates a device and returns its key ("id.secret"), shown to the device once.
func (d *Devices) Add(user, name, ip string) (*Device, string, error) {
	id, secret := randomToken(9), randomToken(32)
	dev := &Device{ID: id, User: user, Name: cleanDeviceName(name), SecretHash: hashSecret(secret),
		Created: now(), LastSeen: now(), LastIP: ip}
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	d.f.data[id] = dev
	return copyDevice(dev), id + "." + secret, d.f.save()
}

func copyDevice(dev *Device) *Device {
	c := *dev
	return &c
}

func cleanDeviceName(name string) string {
	name = strings.TrimSpace(name)
	b := strings.Builder{}
	for _, r := range name {
		if r >= 32 && r != 127 {
			b.WriteRune(r)
		}
	}
	name = b.String()
	if name == "" {
		name = "Unnamed device"
	}
	if len([]rune(name)) > maxDeviceName {
		name = string([]rune(name)[:maxDeviceName])
	}
	return name
}

// Check returns the device a key belongs to (nil if the key is wrong or removed).
func (d *Devices) Check(key, ip string) *Device {
	id, secret, ok := strings.Cut(key, ".")
	if !ok || id == "" || secret == "" {
		return nil
	}
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	dev := d.f.data[id]
	if dev == nil || subtle.ConstantTimeCompare([]byte(dev.SecretHash), []byte(hashSecret(secret))) != 1 {
		return nil
	}
	if now()-dev.LastSeen > lastSeenEvery.Seconds() || dev.LastIP != ip {
		dev.LastSeen, dev.LastIP = now(), ip
		_ = d.f.save()
	}
	return copyDevice(dev)
}

func (d *Devices) List(user string) []*Device {
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	out := []*Device{}
	for _, dev := range d.f.data {
		if user == "" || dev.User == user {
			out = append(out, copyDevice(dev))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeen > out[j].LastSeen })
	return out
}

func (d *Devices) Get(id string) *Device {
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	if dev := d.f.data[id]; dev != nil {
		return copyDevice(dev)
	}
	return nil
}

func (d *Devices) Remove(id string) {
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	delete(d.f.data, id)
	_ = d.f.save()
}

func (d *Devices) RemoveAllFor(user string) {
	d.f.mu.Lock()
	defer d.f.mu.Unlock()
	for id, dev := range d.f.data {
		if dev.User == user {
			delete(d.f.data, id)
		}
	}
	_ = d.f.save()
}

// ---------------------------------------------------------------- pairing codes
//
// Each code is its own small file in data/pairing, so the server app, the command
// line and the running server can all make codes without stepping on each other.

type pairCode struct {
	Hash    string  `json:"hash"`
	User    string  `json:"user"`
	Expires float64 `json:"expires"`
}

type Pairing struct {
	dir     string
	mu      sync.Mutex
	guesses int // wrong codes since the last code was made
}

func OpenPairing(dataDir string) *Pairing {
	dir := filepath.Join(dataDir, "pairing")
	_ = os.MkdirAll(dir, 0o700)
	return &Pairing{dir: dir}
}

func sixDigits() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	return fmt.Sprintf("%06d", n.Int64())
}

// NewCode makes a pairing code for one person, valid for 10 minutes.
func NewCode(dataDir, user string) (string, time.Time, error) {
	dir := filepath.Join(dataDir, "pairing")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", time.Time{}, err
	}
	code := sixDigits()
	expires := time.Now().Add(codeLifetime)
	b, _ := json.Marshal(pairCode{Hash: hashSecret(code), User: user, Expires: float64(expires.Unix())})
	if err := writeAtomic(filepath.Join(dir, randomHex(8)+".json"), b, 0o600); err != nil {
		return "", time.Time{}, err
	}
	return code, expires, nil
}

func (p *Pairing) open() map[string]pairCode {
	out := map[string]pairCode{}
	entries, _ := os.ReadDir(p.dir)
	for _, e := range entries {
		f := filepath.Join(p.dir, e.Name())
		var c pairCode
		b, err := os.ReadFile(f)
		if err != nil || json.Unmarshal(b, &c) != nil || c.Expires < now() {
			_ = os.Remove(f) // expired or damaged
			continue
		}
		out[f] = c
	}
	return out
}

// Use checks a code for a person and uses it up. Too many wrong codes (from
// anyone) cancel every open code, so guessing 6 digits is hopeless.
func (p *Pairing) Use(code, user string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	codes := p.open()
	want := hashSecret(strings.TrimSpace(code))
	for f, c := range codes {
		if subtle.ConstantTimeCompare([]byte(c.Hash), []byte(want)) == 1 && c.User == user {
			_ = os.Remove(f)
			return true
		}
	}
	p.guesses++
	if p.guesses >= codeMaxGuesses {
		for f := range codes {
			_ = os.Remove(f)
		}
		p.guesses = 0
	}
	return false
}

// ---------------------------------------------------------------- API

func (srv *Server) pairingRoutes(mux *http.ServeMux) {
	a := func(h handler) http.HandlerFunc { return srv.authed(false, h) }

	// Pair a new device: code + username + password -> device key + login.
	mux.HandleFunc("POST /api/pair", srv.open(func(w http.ResponseWriter, r *http.Request) (any, error) {
		var body struct {
			Code     string `json:"code"`
			Username string `json:"username"`
			Password string `json:"password"`
			Device   string `json:"device_name"`
		}
		if err := decode(r, &body); err != nil {
			return nil, err
		}
		ip := clientIP(r)
		if !srv.login.Allow("pair:"+ip, pairPerIP, pairWindow, true) {
			return nil, fail(429, "Too many tries. Wait 15 minutes and try again.")
		}
		name := strings.ToLower(strings.TrimSpace(body.Username))
		if !srv.login.Allow("user:"+name, loginFailures, loginWindow, false) {
			return nil, fail(429, "Too many wrong passwords. Sign-in is paused for 15 minutes.")
		}
		u := srv.users.CheckLogin(name, body.Password)
		if u == nil {
			srv.login.Record("user:" + name)
			return nil, fail(401, "Wrong username or password")
		}
		if !srv.pairing.Use(body.Code, u.Username) {
			return nil, fail(401, "That pairing code isn't right, or it expired. Get a new one and try again.")
		}
		srv.login.Clear("user:" + name)
		dev, key, err := srv.devices.Add(u.Username, body.Device, ip)
		if err != nil {
			return nil, err
		}
		token := makeToken(u.Username, u.TokenVersion, srv.cfg.Secret, srv.cfg.TokenDays)
		return map[string]any{"device_key": key, "device_id": dev.ID, "token": token,
			"username": u.Username, "is_admin": u.IsAdmin}, nil
	}))

	// Make a code to pair another device (for yourself, or the admin for anyone).
	mux.HandleFunc("POST /api/devices/code", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		var body struct {
			Username string `json:"username"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		who := s.user.Username
		if body.Username != "" && body.Username != who {
			if !s.user.IsAdmin {
				return nil, fail(403, "Only the admin can make codes for other people")
			}
			if srv.users.Get(body.Username) == nil {
				return nil, fail(404, "No such user")
			}
			who = body.Username
		}
		code, expires, err := NewCode(srv.cfg.DataDir, who)
		if err != nil {
			return nil, err
		}
		return map[string]any{"code": code, "username": who, "expires": expires.Unix()}, nil
	}))

	mux.HandleFunc("GET /api/devices", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		who := s.user.Username
		if s.user.IsAdmin && r.URL.Query().Get("all") == "true" {
			who = ""
		}
		out := []map[string]any{}
		for _, d := range srv.devices.List(who) {
			out = append(out, map[string]any{"id": d.ID, "user": d.User, "name": d.Name, "created": d.Created,
				"last_seen": d.LastSeen, "last_ip": d.LastIP, "this_device": s.device != nil && d.ID == s.device.ID})
		}
		return map[string]any{"devices": out}, nil
	}))

	mux.HandleFunc("DELETE /api/devices/{id}", a(func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		d := srv.devices.Get(r.PathValue("id"))
		if d == nil || (d.User != s.user.Username && !s.user.IsAdmin) {
			return nil, fail(404, "Device not found")
		}
		srv.devices.Remove(d.ID)
		return nil, nil
	}))
}

// checkDevice: the request's device key, which must belong to user (when pairing is on).
func (srv *Server) checkDevice(r *http.Request, user string) (*Device, error) {
	if !srv.cfg.RequirePairing {
		return nil, nil
	}
	ip := clientIP(r)
	if !srv.login.Allow("baddev:"+ip, badDeviceLimit, failureWindow, false) {
		return nil, fail(429, "Too many tries from this address. Wait a few minutes.")
	}
	key := r.Header.Get(deviceHeader)
	if key == "" {
		return nil, &apiError{403, pairingRequired}
	}
	dev := srv.devices.Check(key, ip)
	if dev == nil || (user != "" && dev.User != user) {
		srv.login.Record("baddev:" + ip)
		return nil, &apiError{403, pairingRequired}
	}
	return dev, nil
}

var errNotPaired = errors.New(pairingRequired)
