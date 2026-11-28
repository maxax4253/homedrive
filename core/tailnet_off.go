//go:build notailscale

package main

import (
	"context"
	"log"
	"net/http"
	"path/filepath"
)

const tailscaleBuilt = false

func startTailnet(ctx context.Context, srv *Server, handler http.Handler) {
	log.Print("Tailscale: this copy of HomeDrive was built without it")
	st := TailnetStatus{State: "error", Error: "built without Tailscale", Updated: now()}
	srv.tsMu.Lock()
	srv.tsStatus = st
	srv.tsMu.Unlock()
	writeStatus(filepath.Join(srv.cfg.DataDir, "tailscale-status.json"), st)
}
