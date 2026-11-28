//go:build notailscale

package main

import (
	"context"
	"log"
	"net/http"
)

const tailscaleBuilt = false

func startTailnet(ctx context.Context, srv *Server, handler http.Handler) {
	log.Print("Tailscale: this copy of HomeDrive was built without it")
	srv.tsMu.Lock()
	srv.tsStatus = TailnetStatus{State: "error", Error: "built without Tailscale"}
	srv.tsMu.Unlock()
}
