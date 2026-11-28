package main

import (
	"context"
	"net/http/httptest"
	"testing"
)

// Visitors through the built-in Tailscale can't fake their address with headers.
func TestRealIPBeatsForwardedHeader(t *testing.T) {
	r := httptest.NewRequest("GET", "/s/x", nil)
	r.Header.Set("X-Forwarded-For", "1.2.3.4")
	if got := publicIP(r); got != "1.2.3.4" {
		t.Fatalf("plain listener should use the proxy header, got %s", got)
	}
	r = r.WithContext(context.WithValue(r.Context(), realIPKey{}, "203.0.113.9"))
	if got := publicIP(r); got != "203.0.113.9" {
		t.Fatalf("tailnet visitor: got %s", got)
	}
	if got := clientIP(r); got != "203.0.113.9" {
		t.Fatalf("clientIP: got %s", got)
	}
}

func TestTailscaleStatusIsAdminOnly(t *testing.T) {
	srv, base := testServer(t)
	admin := pair(t, base, srv.cfg.DataDir, "max", "admin-pass")
	st, out := admin.do("GET", "/api/admin/tailscale", nil)
	if st != 200 || out["status"].(map[string]any)["state"] != "off" {
		t.Fatalf("%d %v", st, out)
	}
	admin.do("POST", "/api/users", map[string]any{"username": "mom", "password": "mom-pass"})
	_, code := admin.do("POST", "/api/devices/code", map[string]string{"username": "mom"})
	mom := &client{t: t, base: base}
	_, p := mom.do("POST", "/api/pair", map[string]string{"code": code["code"].(string), "username": "mom", "password": "mom-pass"})
	mom.token, mom.device = p["token"].(string), p["device_key"].(string)
	if st, _ := mom.do("GET", "/api/admin/tailscale", nil); st != 403 {
		t.Fatalf("non-admin got %d", st)
	}
}

func TestPublicURLCanChangeWhileRunning(t *testing.T) {
	srv, _ := testServer(t)
	if srv.publicURL() != "" {
		t.Fatal("expected no public address")
	}
	srv.setPublicURL("https://homedrive.example.ts.net")
	if got, _ := srv.shareURL("abc").(string); got != "https://homedrive.example.ts.net/s/abc" {
		t.Fatal(srv.shareURL("abc"))
	}
}
