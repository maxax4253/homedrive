//go:build !notailscale

package main

// Built-in Tailscale: HomeDrive joins your tailnet as its own little machine
// ("homedrive"), gets an https address with a real certificate, and, with
// Funnel, is reachable from anywhere. Nobody has to install Tailscale.
//
// Everything it learns (login link, address, whether Funnel works) is written to
// data/tailscale-status.json so the setup app and `homedrive-server status` can
// show it.

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

const tailscaleBuilt = true

func startTailnet(ctx context.Context, srv *Server, handler http.Handler) {
	t := &tailnet{srv: srv, statusFile: filepath.Join(srv.cfg.DataDir, "tailscale-status.json")}
	t.set(func(s *TailnetStatus) { s.State = "starting" })
	go t.run(ctx, handler)
}

type tailnet struct {
	srv        *Server
	statusFile string
	status     TailnetStatus
}

func (t *tailnet) set(change func(*TailnetStatus)) {
	t.srv.tsMu.Lock()
	change(&t.status)
	t.status.Updated = now()
	t.srv.tsStatus = t.status
	t.srv.tsMu.Unlock()
	writeStatus(t.statusFile, t.status)
}

func (t *tailnet) fail(err error) {
	log.Printf("Tailscale: %v", err)
	t.set(func(s *TailnetStatus) { s.State, s.Error = "error", err.Error() })
}

func (t *tailnet) run(ctx context.Context, handler http.Handler) {
	cfg := t.srv.cfg
	ts := &tsnet.Server{
		Dir:      filepath.Join(cfg.DataDir, "tailscale"),
		Hostname: cfg.TailscaleName,
		Logf:     func(string, ...any) {}, // very chatty; problems show up in the status instead
		UserLogf: func(string, ...any) {},
	}
	go func() { <-ctx.Done(); _ = ts.Close() }()
	if err := ts.Start(); err != nil {
		t.fail(err)
		return
	}
	lc, err := ts.LocalClient()
	if err != nil {
		t.fail(err)
		return
	}

	// Wait until it's signed in to a tailnet, sharing the login link meanwhile.
	var domain string
	for {
		st, err := lc.Status(ctx)
		if ctx.Err() != nil {
			return
		}
		if err == nil {
			switch st.BackendState {
			case "Running":
				if st.Self != nil {
					domain = strings.TrimSuffix(st.Self.DNSName, ".")
				}
			case "NeedsLogin":
				if st.AuthURL != "" && st.AuthURL != t.status.LoginURL {
					log.Printf("Tailscale: to connect HomeDrive, open %s", st.AuthURL)
				}
				t.set(func(s *TailnetStatus) { s.State, s.LoginURL = "needs_login", st.AuthURL })
			case "NeedsMachineAuth":
				t.set(func(s *TailnetStatus) { s.State = "needs_approval" })
			}
		}
		if domain != "" {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}

	address := "https://" + domain
	ln, funnelErr := net.Listener(nil), error(nil)
	if cfg.Funnel {
		ln, funnelErr = ts.ListenFunnel("tcp", ":443")
	}
	if ln == nil {
		ln, err = ts.ListenTLS("tcp", ":443")
		if err != nil {
			t.fail(err)
			return
		}
	}
	funnel := cfg.Funnel && funnelErr == nil
	if funnel {
		t.srv.setPublicURL(address) // share links now work from anywhere
	}
	t.set(func(s *TailnetStatus) {
		s.State, s.LoginURL, s.Error, s.Address, s.Funnel = "running", "", "", address, funnel
		s.FunnelError = ""
		if funnelErr != nil {
			s.FunnelError = funnelHelp(funnelErr)
		}
	})
	where := "only on your tailnet"
	if funnel {
		where = "from anywhere"
	}
	log.Printf("Tailscale: HomeDrive is at %s (%s)", address, where)

	hs := &http.Server{Handler: handler, ReadHeaderTimeout: 20 * time.Second, IdleTimeout: 2 * time.Minute,
		ErrorLog:    log.New(io.Discard, "", 0), // failed TLS handshakes from scanners aren't news
		BaseContext: func(net.Listener) context.Context { return ctx },
		ConnContext: tailnetConnContext}
	go func() { <-ctx.Done(); _ = hs.Close() }()
	if err := hs.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) && ctx.Err() == nil {
		t.fail(err)
	}
}

// tailnetConnContext remembers who is really on the other end. For Funnel
// visitors that's their internet address (the connection itself comes from
// Tailscale's relay), so rate limits and download logs are per visitor.
func tailnetConnContext(ctx context.Context, c net.Conn) context.Context {
	if tc, ok := c.(*tls.Conn); ok {
		c = tc.NetConn()
	}
	if fc, ok := c.(*ipn.FunnelConn); ok {
		return context.WithValue(ctx, realIPKey{}, fc.Src.Addr().String())
	}
	if host, _, err := net.SplitHostPort(c.RemoteAddr().String()); err == nil {
		return context.WithValue(ctx, realIPKey{}, host)
	}
	return context.WithValue(ctx, realIPKey{}, "tailnet")
}

func funnelHelp(err error) string {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "HTTPS"), strings.Contains(strings.ToLower(msg), "https"):
		return "Turn on HTTPS for your tailnet (Tailscale admin console → DNS → HTTPS Certificates), then restart HomeDrive."
	case strings.Contains(strings.ToLower(msg), "funnel"):
		return "Your tailnet doesn't allow Funnel yet. In the Tailscale admin console, allow Funnel for this device, then restart HomeDrive."
	}
	return msg
}
