// HomeDrive server: your own Google Drive, on your own computer.
//
// This is the core server. It serves the HomeDrive API (used by the apps) and the
// public share-link pages. Settings come from flags or HOMEDRIVE_* environment
// variables (the same names the old Python server used).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var Version = "1.0.0-dev"

type Config struct {
	FilesRoot    string
	DataDir      string
	Username     string
	Password     string
	Secret       string
	TokenDays    int
	PublicURL    string
	MinFreeBytes int64
	CleanupDays  int
	VersionsKeep int
	Listen       string
	PublicListen string // optional separate address for share pages only
	// Every device must be paired with a code before it can sign in.
	RequirePairing bool
	// Built-in Tailscale: join the tailnet as TailscaleName, and with Funnel be
	// reachable from anywhere (share links then use that address).
	Tailscale     bool
	TailscaleName string
	Funnel        bool
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return def
}

func loadConfig(args []string) (*Config, error) {
	fsFlags := flag.NewFlagSet("homedrive-server", flag.ContinueOnError)
	c := &Config{}
	fsFlags.StringVar(&c.FilesRoot, "files", env("HOMEDRIVE_FILES", "./drive"), "folder that holds everyone's files")
	fsFlags.StringVar(&c.DataDir, "data", env("HOMEDRIVE_DATA", "./data"), "folder for accounts, links and settings")
	fsFlags.StringVar(&c.Username, "admin", env("HOMEDRIVE_USERNAME", "admin"), "admin username")
	fsFlags.StringVar(&c.Listen, "listen", env("HOMEDRIVE_LISTEN", "127.0.0.1:8090"), "address to serve on")
	fsFlags.StringVar(&c.PublicListen, "public-listen", env("HOMEDRIVE_PUBLIC_LISTEN", ""), "extra address serving share pages only")
	fsFlags.BoolVar(&c.Tailscale, "tailscale", os.Getenv("HOMEDRIVE_TAILSCALE") == "1", "join Tailscale (built in, nothing to install)")
	fsFlags.StringVar(&c.TailscaleName, "tailscale-name", env("HOMEDRIVE_TAILSCALE_NAME", "homedrive"), "this server's name on Tailscale")
	fsFlags.BoolVar(&c.Funnel, "funnel", os.Getenv("HOMEDRIVE_FUNNEL") != "0", "with -tailscale: reachable from anywhere through Tailscale Funnel")
	fsFlags.StringVar(&c.PublicURL, "public-url", env("HOMEDRIVE_PUBLIC_URL", ""), "public address for share links")
	minFree := fsFlags.Float64("min-free-gb", 2, "stop uploads when the disk has less free space than this")
	if v, err := strconv.ParseFloat(os.Getenv("HOMEDRIVE_MIN_FREE_GB"), 64); err == nil {
		*minFree = v
	}
	noPairing := fsFlags.Bool("no-pairing", os.Getenv("HOMEDRIVE_NO_PAIRING") == "1",
		"let any device sign in with just a password (only for a server nobody else can reach)")
	fsFlags.IntVar(&c.CleanupDays, "cleanup-days", envInt("HOMEDRIVE_CLEANUP_DAYS", 30), "empty trash and old versions after this many days (0 = never)")
	if err := fsFlags.Parse(args); err != nil {
		return nil, err
	}
	c.RequirePairing = !*noPairing
	c.Password = os.Getenv("HOMEDRIVE_PASSWORD") // never a flag: flags show up in process lists
	c.TokenDays = envInt("HOMEDRIVE_TOKEN_DAYS", 30)
	c.VersionsKeep = 10
	c.MinFreeBytes = int64(*minFree * gb)
	c.PublicURL = strings.TrimRight(strings.TrimSpace(c.PublicURL), "/")

	var err error
	for _, dir := range []*string{&c.FilesRoot, &c.DataDir} {
		if *dir, err = filepath.Abs(*dir); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(*dir, 0o755); err != nil {
			return nil, err
		}
		*dir = mustAbs(*dir)
	}
	_ = os.Chmod(c.DataDir, 0o700)

	c.Secret = os.Getenv("HOMEDRIVE_SECRET")
	if c.Secret == "" {
		if c.Secret, err = loadSecret(c.DataDir); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// loadSecret: the signing secret survives restarts so logins stay valid.
func loadSecret(dataDir string) (string, error) {
	keyFile := filepath.Join(dataDir, "secret.key")
	if b, err := os.ReadFile(keyFile); err == nil {
		return strings.TrimSpace(string(b)), nil
	}
	s := randomHex(32)
	return s, os.WriteFile(keyFile, []byte(s), 0o600)
}

func NewServer(c *Config) (*Server, error) {
	users, err := OpenUsers(c.DataDir)
	if err != nil {
		return nil, err
	}
	admin := strings.ToLower(strings.TrimSpace(c.Username))
	if c.Password != "" {
		if err := users.EnsureAdmin(admin, c.Password); err != nil {
			return nil, err
		}
	} else if len(users.List()) == 0 {
		return nil, errors.New("set HOMEDRIVE_PASSWORD for the first start (it becomes the admin password)")
	}
	links, err := OpenLinks(c.DataDir)
	if err != nil {
		return nil, err
	}
	devices, err := OpenDevices(c.DataDir)
	if err != nil {
		return nil, err
	}
	// Leftovers from an upload that was cut off by a crash.
	_ = os.RemoveAll(filepath.Join(c.FilesRoot, uploadTmp))
	srv := &Server{
		cfg: c, users: users, links: links, versions: OpenVersions(c.DataDir, c.VersionsKeep),
		login: NewLimiter(loginWindow), devices: devices, pairing: OpenPairing(c.DataDir), stars: map[string]*Stars{}, usageMap: map[string]usageEntry{},
		measuring: map[string]bool{}, recent: map[string]recentEntry{},
	}
	srv.setPublicURL(c.PublicURL)
	if c.Tailscale {
		srv.tsStatus = TailnetStatus{State: "starting"}
	}
	return srv, nil
}

// Handler serves the API and the share pages.
func (srv *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	srv.Routes(mux)
	srv.publicApp().Routes(mux)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/"):
			writeJSON(w, 404, map[string]string{"detail": "Not Found"})
		case r.URL.Path == "/":
			page(w, 200, "HomeDrive", "<h1>Nothing to see here</h1><div class='meta'>Open the full link you were sent.</div>")
		default:
			w.WriteHeader(404)
		}
	})
	return mux
}

// PublicHandler serves only the share pages (everything else is 404).
func (srv *Server) PublicHandler() http.Handler {
	mux := http.NewServeMux()
	srv.publicApp().Routes(mux)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			page(w, 200, "HomeDrive", "<h1>Nothing to see here</h1><div class='meta'>Open the full link you were sent.</div>")
			return
		}
		w.WriteHeader(404)
	})
	return mux
}

func (srv *Server) publicApp() *publicApp {
	return &publicApp{srv: srv, secret: linksKey(srv.cfg.DataDir), limiter: NewLimiter(failureWindow)}
}

var linksKeyCache = map[string]string{}

// linksKey signs "password entered" codes on share pages. Same file as the old server.
func linksKey(dataDir string) string {
	if k, ok := linksKeyCache[dataDir]; ok {
		return k
	}
	f := filepath.Join(dataDir, "links", "links.key")
	k := ""
	if b, err := os.ReadFile(f); err == nil {
		k = strings.TrimSpace(string(b))
	} else {
		k = randomHex(32)
		_ = os.WriteFile(f, []byte(k), 0o600)
	}
	linksKeyCache[dataDir] = k
	return k
}

func serve(ctx context.Context, addr string, h http.Handler) (*http.Server, net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, err
	}
	s := &http.Server{Handler: h, ReadHeaderTimeout: 20 * time.Second, IdleTimeout: 2 * time.Minute,
		BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _ = s.Serve(ln) }()
	return s, ln, nil
}

// Start runs the background parts: Tailscale (if on) and the cleanup timer.
func (srv *Server) Start(ctx context.Context) {
	if srv.cfg.Tailscale {
		startTailnet(ctx, srv, srv.Handler())
	}
	go func() { // empty old trash and versions now and every 6 hours
		for {
			if t, v := srv.cleanUpOld(); t+v > 0 {
				log.Printf("cleanup: removed %d old trash items and %d old versions", t, v)
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(6 * time.Hour):
			}
		}
	}()
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(Version)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "status" {
		statusCommand(os.Args[2:])
		return
	}
	// Double-clicked (no settings given): run as the app with its setup page.
	if (len(os.Args) == 1 && os.Getenv("HOMEDRIVE_FILES") == "") || (len(os.Args) > 1 && os.Args[1] == "app") {
		runApp(os.Args[min(len(os.Args), 2):])
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "open" {
		openCommand(os.Args[2:])
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "pair-code" {
		pairCodeCommand(os.Args[2:])
		return
	}
	cfg, err := loadConfig(os.Args[1:])
	if err != nil {
		log.Fatal(err)
	}
	srv, err := NewServer(cfg)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	main, ln, err := serve(ctx, cfg.Listen, srv.Handler())
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("HomeDrive %s serving %s at http://%s", Version, cfg.FilesRoot, ln.Addr())
	servers := []*http.Server{main}
	if cfg.Tailscale && !cfg.RequirePairing {
		log.Fatal("Tailscale makes HomeDrive reachable from other machines, so pairing can't be turned off with it")
	}
	srv.Start(ctx)
	if cfg.PublicListen != "" {
		pub, pln, err := serve(ctx, cfg.PublicListen, srv.PublicHandler())
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("Share pages at http://%s", pln.Addr())
		servers = append(servers, pub)
	}

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, s := range servers {
		_ = s.Shutdown(shutdown)
	}
}

// pairCodeCommand prints a pairing code. It runs on the server computer itself,
// which is what makes it trustworthy: only someone at that computer can do it.
//
//	homedrive-server pair-code -data ~/.homedrive -user max
func pairCodeCommand(args []string) {
	f := flag.NewFlagSet("pair-code", flag.ExitOnError)
	data := f.String("data", env("HOMEDRIVE_DATA", "./data"), "the server's data folder")
	user := f.String("user", env("HOMEDRIVE_USERNAME", "admin"), "whose device this is")
	_ = f.Parse(args)
	users, err := OpenUsers(*data)
	if err != nil {
		log.Fatal(err)
	}
	name := strings.ToLower(strings.TrimSpace(*user))
	if users.Get(name) == nil {
		log.Fatalf("there's no account called %q", name)
	}
	code, expires, err := NewCode(*data, name)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s\n", code)
	fmt.Fprintf(os.Stderr, "Pairing code for %s, valid until %s\n", name, expires.Format("3:04 PM"))
}
