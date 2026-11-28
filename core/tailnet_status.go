package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

// TailnetStatus is what the built-in Tailscale is up to.
type TailnetStatus struct {
	// off, starting, needs_login, needs_approval, running, error
	State       string  `json:"state"`
	LoginURL    string  `json:"login_url,omitempty"`    // open this to connect HomeDrive to Tailscale
	Address     string  `json:"address,omitempty"`      // https://homedrive.<tailnet>.ts.net
	Funnel      bool    `json:"funnel"`                 // reachable from anywhere
	FunnelError string  `json:"funnel_error,omitempty"` // why not, in plain words
	Error       string  `json:"error,omitempty"`
	Updated     float64 `json:"updated"`
}

// realIPKey holds the visitor's real address for connections that arrive through
// the built-in Tailscale (where X-Forwarded-For must not be trusted).
type realIPKey struct{}

func writeStatus(file string, s TailnetStatus) {
	b, _ := json.MarshalIndent(s, "", "  ")
	_ = writeAtomic(file, b, 0o600)
}

// statusCommand prints the Tailscale status of a HomeDrive server on this computer.
//
//	homedrive-server status -data ~/.homedrive
func statusCommand(args []string) {
	f := flag.NewFlagSet("status", flag.ExitOnError)
	data := f.String("data", env("HOMEDRIVE_DATA", "./data"), "the server's data folder")
	_ = f.Parse(args)
	b, err := os.ReadFile(filepath.Join(*data, "tailscale-status.json"))
	if err != nil {
		fmt.Println("Tailscale isn't turned on for this HomeDrive.")
		return
	}
	var s TailnetStatus
	if json.Unmarshal(b, &s) != nil {
		fmt.Println("Couldn't read the status file.")
		os.Exit(1)
	}
	switch s.State {
	case "needs_login":
		fmt.Printf("Connect HomeDrive to Tailscale by opening:\n  %s\n", s.LoginURL)
	case "needs_approval":
		fmt.Println("Waiting for approval in the Tailscale admin console.")
	case "running":
		fmt.Printf("HomeDrive is at %s\n", s.Address)
		if s.Funnel {
			fmt.Println("Reachable from anywhere (Funnel is on).")
		} else {
			fmt.Println("Reachable only from your own devices on Tailscale.")
			if s.FunnelError != "" {
				fmt.Println(s.FunnelError)
			}
		}
	case "error":
		fmt.Printf("Tailscale problem: %s\n", s.Error)
	default:
		fmt.Println("Tailscale is starting…")
	}
}

// GET /api/admin/tailscale: what the built-in Tailscale is doing (admin only).
func (srv *Server) tailnetRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/admin/tailscale", srv.authed(true, func(w http.ResponseWriter, r *http.Request, s *session) (any, error) {
		st := srv.tailnetStatus()
		if !srv.cfg.Tailscale {
			st = TailnetStatus{State: "off"}
		}
		return map[string]any{"built_in": tailscaleBuilt, "status": st}, nil
	}))
}
