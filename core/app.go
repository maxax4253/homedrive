package main

// App mode: what runs when someone double-clicks HomeDrive.
//
// There are no settings to type in a terminal. Everything is done on a private
// page in the browser (http://127.0.0.1:8093/app/), opened from the menu-bar
// icon. The first time, that page is a setup wizard: pick a folder, make your
// account, sign in to Tailscale, pair your first device. After that it's a
// small dashboard.
//
// The page is only for whoever is sitting at this computer:
//   - it only listens on 127.0.0.1 (other machines can't connect), and is never
//     served through Tailscale;
//   - it needs a secret that changes every start and is only handed out by the
//     menu-bar icon (or `homedrive-server open`), so other programs and web
//     pages on this computer can't use it;
//   - the Host and Origin headers must be this page's own, which stops web
//     pages from poking at it through the browser (DNS rebinding, CSRF).

import (
	"context"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

//go:embed web/app.html
var appFiles embed.FS

const (
	appListen     = "127.0.0.1:8093"
	appCookie     = "homedrive_app"
	appURLFile    = "app-url" // where `homedrive-server open` finds the current secret link
	appSettings   = "app.json"
	appSetupLimit = 20 // setup attempts per start (it's local, but no reason to allow endless tries)
)

// AppSettings are the choices made in the setup wizard.
type AppSettings struct {
	FilesRoot     string `json:"files_root"`
	Username      string `json:"username"`
	Tailscale     bool   `json:"tailscale"`
	TailscaleName string `json:"tailscale_name"`
	Funnel        bool   `json:"funnel"`
}

type App struct {
	dataDir  string
	listen   string
	token    string
	ctx      context.Context
	settings atomic.Pointer[AppSettings]
	drive    atomic.Pointer[Server]
	handler  atomic.Value // http.Handler of the running drive

	mu         sync.Mutex // one setup at a time
	setupTries int
	updates    updater
	restart    func(*exec.Cmd) // quit, start the new version, exit

	noTailscale      bool // tests: never contact Tailscale
	autostartOnSetup bool // the real app: start with the computer from the beginning
}

// defaultDataDir: ~/Library/Application Support/HomeDrive Server on a Mac,
// %AppData%\HomeDrive Server on Windows, ~/.config/HomeDrive Server on Linux.
func defaultDataDir() string {
	if d := os.Getenv("HOMEDRIVE_DATA"); d != "" {
		return d
	}
	base, err := os.UserConfigDir()
	if err != nil {
		base = "."
	}
	return filepath.Join(base, "HomeDrive Server")
}

func defaultFilesRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "HomeDrive")
}

var nonUsername = regexp.MustCompile(`[^a-z0-9_.-]+`)

func defaultUsername() string {
	if u, err := user.Current(); err == nil {
		name := u.Username
		if i := strings.LastIndexAny(name, `\/`); i >= 0 { // Windows: DOMAIN\name
			name = name[i+1:]
		}
		name = strings.Trim(nonUsername.ReplaceAllString(strings.ToLower(name), ""), "._-")
		if len(name) > 32 {
			name = name[:32]
		}
		if usernameRE.MatchString(name) {
			return name
		}
	}
	return "admin"
}

func NewApp(ctx context.Context, dataDir, listen string) (*App, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	a := &App{dataDir: mustAbs(dataDir), listen: listen, token: randomToken(24), ctx: ctx}
	// After an update the new copy keeps the old one's secret, so the open page keeps working.
	if t := os.Getenv("HOMEDRIVE_APP_TOKEN"); len(t) >= 24 {
		a.token = t
		_ = os.Unsetenv("HOMEDRIVE_APP_TOKEN")
	}
	if b, err := os.ReadFile(filepath.Join(a.dataDir, appSettings)); err == nil {
		var s AppSettings
		if err := json.Unmarshal(b, &s); err != nil {
			return nil, fmt.Errorf("the settings file %s is damaged: %w", appSettings, err)
		}
		a.settings.Store(&s)
	}
	return a, nil
}

// OpenURL is the secret link to the app page (shown by the menu-bar icon).
func (a *App) OpenURL() string {
	return "http://" + a.listen + "/app/open?t=" + a.token
}

func (a *App) SetupDone() bool { return a.settings.Load() != nil }

// startDrive starts the file server with the saved settings.
func (a *App) startDrive() error {
	s := a.settings.Load()
	secret, err := loadSecret(a.dataDir)
	if err != nil {
		return err
	}
	cfg := &Config{FilesRoot: s.FilesRoot, DataDir: a.dataDir, Username: s.Username, Secret: secret,
		TokenDays: 30, VersionsKeep: 10, MinFreeBytes: 2 * gb, CleanupDays: 30, Listen: a.listen,
		RequirePairing: true, Tailscale: s.Tailscale && !a.noTailscale, TailscaleName: s.TailscaleName, Funnel: s.Funnel}
	if err := os.MkdirAll(cfg.FilesRoot, 0o755); err != nil {
		return fmt.Errorf("can't use the folder %s: %w", cfg.FilesRoot, err)
	}
	srv, err := NewServer(cfg)
	if err != nil {
		return err
	}
	a.handler.Store(srv.Handler())
	a.drive.Store(srv)
	srv.Start(a.ctx)
	log.Printf("HomeDrive %s is sharing %s", Version, cfg.FilesRoot)
	return nil
}

// ---------------------------------------------------------------- the local page

func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	page, _ := appFiles.ReadFile("web/app.html")

	mux.HandleFunc("GET /app/open", func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("t")), []byte(a.token)) != 1 {
			a.notAllowed(w)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: appCookie, Value: a.token, Path: "/app/", HttpOnly: true,
			SameSite: http.SameSiteStrictMode})
		http.Redirect(w, r, "/app/", http.StatusSeeOther)
	})
	mux.HandleFunc("GET /app/{$}", a.only(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "+
			"img-src data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		_, _ = w.Write(page)
	}))
	mux.HandleFunc("GET /app/api/state", a.only(a.api(func(r *http.Request) (any, error) { return a.state(), nil })))
	mux.HandleFunc("POST /app/api/setup", a.only(a.api(a.setup)))
	mux.HandleFunc("POST /app/api/pair-code", a.only(a.api(func(r *http.Request) (any, error) {
		s := a.settings.Load()
		if s == nil || a.drive.Load() == nil {
			return nil, fail(409, "Finish setting up first.")
		}
		var body struct {
			Username string `json:"username"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		who := s.Username
		if body.Username != "" {
			who = strings.ToLower(strings.TrimSpace(body.Username))
			if a.drive.Load().users.Get(who) == nil {
				return nil, fail(404, "There's no account called "+who)
			}
		}
		code, expires, err := NewCode(a.dataDir, who)
		if err != nil {
			return nil, err
		}
		return map[string]any{"code": code, "username": who, "expires": expires.Unix()}, nil
	})))
	mux.HandleFunc("POST /app/api/autostart", a.only(a.api(func(r *http.Request) (any, error) {
		var body struct {
			On bool `json:"on"`
		}
		if err := decode(r, &body); err != nil {
			return nil, err
		}
		if err := setAutostart(body.On); err != nil {
			return nil, fail(500, "Couldn't change that: "+err.Error())
		}
		return map[string]any{"autostart": autostartOn()}, nil
	})))
	mux.HandleFunc("POST /app/api/open-folder", a.only(a.api(func(r *http.Request) (any, error) {
		if s := a.settings.Load(); s != nil {
			return nil, openInSystem(s.FilesRoot)
		}
		return nil, nil
	})))
	mux.HandleFunc("POST /app/api/open-login", a.only(a.api(func(r *http.Request) (any, error) {
		// Opened by us rather than by the page, so the page never needs to
		// navigate to outside addresses.
		if d := a.drive.Load(); d != nil {
			if u := d.tailnetStatus().LoginURL; strings.HasPrefix(u, "https://login.tailscale.com/") {
				return nil, openInSystem(u)
			}
		}
		return nil, fail(409, "There's no Tailscale sign-in waiting.")
	})))
	mux.HandleFunc("POST /app/api/update-check", a.only(a.api(func(r *http.Request) (any, error) {
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		a.updates.check(ctx)
		return a.updates.info(), nil
	})))
	mux.HandleFunc("POST /app/api/update", a.only(a.api(func(r *http.Request) (any, error) {
		if a.restart == nil {
			return nil, fail(409, "Updating isn't possible in this copy of HomeDrive.")
		}
		if err := a.startUpdate(); err != nil {
			return nil, fail(409, err.Error())
		}
		return a.updates.info(), nil
	})))
	mux.HandleFunc("/app/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })

	// Everything else is the drive itself (the same API the apps use, still
	// needing a paired device).
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if h, ok := a.handler.Load().(http.Handler); ok {
			h.ServeHTTP(w, r)
			return
		}
		writeJSON(w, 503, map[string]string{"detail": "HomeDrive is still being set up on its computer."})
	})
	return a.localOnly(mux)
}

// localOnly refuses requests whose Host isn't this page's own address. A web
// page can make the browser send requests to 127.0.0.1 under its own domain name
// (DNS rebinding); those carry that domain as Host and stop here.
func (a *App) localOnly(next http.Handler) http.Handler {
	_, port, _ := net.SplitHostPort(a.listen)
	allowed := map[string]bool{"127.0.0.1:" + port: true, "localhost:" + port: true, "[::1]:" + port: true}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowed[strings.ToLower(r.Host)] {
			http.Error(w, "Not here", http.StatusMisdirectedRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// only lets in the browser that was given the secret link. Changes must also
// come from this page itself (Origin), so other pages can't submit to it.
func (a *App) only(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(appCookie)
		if err != nil || subtle.ConstantTimeCompare([]byte(c.Value), []byte(a.token)) != 1 {
			a.notAllowed(w)
			return
		}
		if r.Method != http.MethodGet && r.Header.Get("Origin") != "http://"+r.Host {
			writeJSON(w, 403, map[string]string{"detail": "Not allowed from here."})
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		h(w, r)
	}
}

func (a *App) notAllowed(w http.ResponseWriter) {
	page(w, 403, "HomeDrive", "<h1>Open HomeDrive from its icon</h1><div class='meta'>"+
		"Click the HomeDrive icon in the menu bar (Mac) or the tray (Windows, Linux) and choose "+
		"“Open HomeDrive”. This page only works from the computer HomeDrive runs on.</div>")
}

func (a *App) api(h func(*http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		out, err := h(r)
		if err != nil {
			var e *apiError
			if errors.As(err, &e) {
				writeJSON(w, e.status, map[string]string{"detail": e.msg})
				return
			}
			writeJSON(w, 500, map[string]string{"detail": err.Error()})
			return
		}
		if out == nil {
			out = map[string]bool{"ok": true}
		}
		writeJSON(w, 200, out)
	}
}

func (a *App) state() map[string]any {
	out := map[string]any{"version": Version, "setup_done": a.SetupDone(), "autostart": autostartOn(), "update": a.updates.info(),
		"tailscale_built_in": tailscaleBuilt, "data_dir": a.dataDir, "local_address": "http://" + a.listen}
	s := a.settings.Load()
	if s == nil {
		out["defaults"] = map[string]string{"files_root": defaultFilesRoot(), "username": defaultUsername()}
		return out
	}
	out["files_root"], out["username"], out["tailscale"] = s.FilesRoot, s.Username, s.Tailscale
	if d := a.drive.Load(); d != nil {
		out["running"] = true
		ts := d.tailnetStatus()
		if !s.Tailscale || a.noTailscale {
			ts = TailnetStatus{State: "off"}
		}
		ts.LoginURL = "" // opened by us (open-login), never handed to the page
		out["tailscale_status"] = ts
		out["needs_tailscale_login"] = d.tailnetStatus().State == "needs_login"
		out["users"] = len(d.users.List())
		out["devices"] = len(d.devices.List(""))
		if total, used, free := diskSpace(s.FilesRoot); total > 0 {
			out["disk"] = map[string]int64{"total": total, "used": used, "free": free}
		}
	}
	return out
}

func (a *App) setup(r *http.Request) (any, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.SetupDone() {
		return nil, fail(409, "HomeDrive is already set up.")
	}
	if a.setupTries++; a.setupTries > appSetupLimit {
		return nil, fail(429, "Too many tries. Quit HomeDrive and open it again.")
	}
	var body struct {
		FilesRoot string `json:"files_root"`
		Username  string `json:"username"`
		Password  string `json:"password"`
		Tailscale *bool  `json:"tailscale"`
	}
	if err := decode(r, &body); err != nil {
		return nil, err
	}
	root, err := cleanFolder(body.FilesRoot)
	if err != nil {
		return nil, fail(400, err.Error())
	}
	if within(root, a.dataDir) || within(a.dataDir, root) {
		return nil, fail(400, "Pick a different folder: that one is where HomeDrive keeps its own settings.")
	}
	name := strings.ToLower(strings.TrimSpace(body.Username))
	if !usernameRE.MatchString(name) {
		return nil, fail(400, "Usernames are lowercase letters, numbers, dots, dashes or underscores (max 32).")
	}
	if body.Password == "" {
		return nil, fail(400, "Pick a password.")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fail(400, "Can't use that folder: "+err.Error())
	}
	users, err := OpenUsers(a.dataDir)
	if err != nil {
		return nil, err
	}
	if len(users.List()) == 0 {
		if _, err := users.Add(name, body.Password, true, nil); err != nil {
			return nil, fail(400, err.Error())
		}
	} else if u := users.CheckLogin(name, body.Password); u == nil || !u.IsAdmin {
		// Leftover accounts from an earlier setup: only their admin can continue.
		return nil, fail(400, "This computer already has HomeDrive accounts. Use that admin's name and password.")
	}
	s := &AppSettings{FilesRoot: root, Username: name, Tailscale: body.Tailscale == nil || *body.Tailscale,
		TailscaleName: "homedrive", Funnel: true}
	b, _ := json.MarshalIndent(s, "", "  ")
	if err := writeAtomic(filepath.Join(a.dataDir, appSettings), b, 0o600); err != nil {
		return nil, err
	}
	a.settings.Store(s)
	if err := a.startDrive(); err != nil {
		return nil, err
	}
	if a.autostartOnSetup {
		if err := setAutostart(true); err != nil {
			log.Printf("couldn't turn on start-at-login: %v", err)
		}
	}
	return a.state(), nil
}

// cleanFolder turns what was typed into a full folder path ("~/HomeDrive" works).
func cleanFolder(p string) (string, error) {
	p = strings.TrimSpace(p)
	if p == "" {
		return "", errors.New("Pick a folder for your files.")
	}
	if p == "~" || strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		p = filepath.Join(home, p[1:])
	}
	if !filepath.IsAbs(p) {
		return "", errors.New("Type the folder's full location, like " + defaultFilesRoot())
	}
	p = filepath.Clean(p)
	if p == filepath.VolumeName(p)+string(filepath.Separator) {
		return "", errors.New("Pick a folder, not a whole drive.")
	}
	if home, err := os.UserHomeDir(); err == nil && p == filepath.Clean(home) {
		return "", errors.New("Pick a folder inside your home folder, not the home folder itself.")
	}
	if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
		return "", errors.New("That's a file, not a folder.")
	}
	return p, nil
}

func within(p, dir string) bool {
	rel, err := filepath.Rel(dir, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// ---------------------------------------------------------------- running it

// runApp: `homedrive-server` double-clicked, or `homedrive-server app`.
func runApp(args []string) {
	f := flag.NewFlagSet("app", flag.ExitOnError)
	data := f.String("data", defaultDataDir(), "where HomeDrive keeps its settings")
	listen := f.String("listen", env("HOMEDRIVE_LISTEN", appListen), "address of the local page (keep it on 127.0.0.1)")
	noTray := f.Bool("no-tray", os.Getenv("HOMEDRIVE_NO_TRAY") == "1", "no menu-bar icon (print the page's link instead)")
	_ = f.Parse(args)

	logToFile(*data)
	cleanOldUpdate(*data)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	afterUpdate := os.Getenv("HOMEDRIVE_APP_TOKEN") != ""
	a, err := NewApp(ctx, *data, *listen)
	if err != nil {
		fatalBox(err)
	}
	a.autostartOnSetup = true
	var ln net.Listener
	for i := 0; ; i++ { // right after an update the old copy may still be letting go
		if ln, err = net.Listen("tcp", *listen); err == nil || !afterUpdate || i == 40 {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if err != nil {
		// Probably already running: show the running one instead of a second copy.
		if b, rerr := os.ReadFile(filepath.Join(*data, appURLFile)); rerr == nil {
			_ = openInSystem(strings.TrimSpace(string(b)))
			return
		}
		fatalBox(fmt.Errorf("can't start: %w", err))
	}
	hs := &http.Server{Handler: a.Handler(), ReadHeaderTimeout: 20 * time.Second, IdleTimeout: 2 * time.Minute,
		BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _ = hs.Serve(ln) }()
	_ = writeAtomic(filepath.Join(a.dataDir, appURLFile), []byte(a.OpenURL()+"\n"), 0o600)

	if a.SetupDone() {
		if err := a.startDrive(); err != nil {
			log.Printf("couldn't start: %v", err)
		}
	}
	log.Printf("HomeDrive %s: open %s", Version, a.OpenURL())
	if !a.SetupDone() {
		_ = openInSystem(a.OpenURL()) // first run: straight to the setup wizard
	}

	quit := func() {
		stop()
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
	}
	// While restarting after an update, the shutdown below must not end the
	// program before the new copy has been started.
	var restarting sync.Mutex
	a.restart = func(cmd *exec.Cmd) {
		restarting.Lock() // held until os.Exit
		quit()
		time.Sleep(time.Second) // let Tailscale and open files close
		cmd.Env = append(os.Environ(), "HOMEDRIVE_APP_TOKEN="+a.token)
		if err := cmd.Start(); err != nil {
			log.Printf("couldn't start the new version: %v", err)
			showError("HomeDrive updated", "Open HomeDrive again to finish updating.")
		}
		os.Exit(0)
	}
	a.watchForUpdates()
	if *noTray || !trayAvailable() {
		fmt.Printf("HomeDrive is running. Open this link on this computer to set it up or see how it's doing:\n  %s\n", a.OpenURL())
		<-ctx.Done()
		quit()
		restarting.Lock()
		return
	}
	runTray(ctx, a, quit) // returns when "Quit" is chosen
	restarting.Lock()
}

// openCommand: `homedrive-server open` opens the running app's page.
func openCommand(args []string) {
	f := flag.NewFlagSet("open", flag.ExitOnError)
	data := f.String("data", defaultDataDir(), "where HomeDrive keeps its settings")
	_ = f.Parse(args)
	b, err := os.ReadFile(filepath.Join(*data, appURLFile))
	if err != nil {
		log.Fatal("HomeDrive isn't running on this computer.")
	}
	u := strings.TrimSpace(string(b))
	fmt.Println(u)
	_ = openInSystem(u)
}

// logToFile: an app started by double-click has no terminal, so keep a log.
func logToFile(dataDir string) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return
	}
	p := filepath.Join(dataDir, "homedrive.log")
	if fi, err := os.Stat(p); err == nil && fi.Size() > 5<<20 {
		_ = os.Rename(p, p+".old")
	}
	if fh, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(multiWriter{fh, os.Stderr})
	}
}

type multiWriter []interface{ Write([]byte) (int, error) }

func (m multiWriter) Write(p []byte) (int, error) {
	for _, w := range m {
		_, _ = w.Write(p)
	}
	return len(p), nil
}

func fatalBox(err error) {
	log.Print(err)
	showError("HomeDrive couldn't start", err.Error())
	os.Exit(1)
}
