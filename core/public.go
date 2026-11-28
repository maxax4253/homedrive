package main

// Public share-link pages: /s/<token>. No login, no browsing: just a page to
// download the one file or folder a link points to.

import (
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	unlockSeconds = 600
	maxIPFailures = 20 // wrong link passwords per visitor address, across all links...
	failureWindow = 10 * time.Minute
	maxHitsPerMin = 120
)

var securityHeaders = map[string]string{
	"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'",
	"X-Robots-Tag":            "noindex, nofollow",
	"Referrer-Policy":         "no-referrer",
	"X-Content-Type-Options":  "nosniff",
	"X-Frame-Options":         "DENY",
}

func sizeText(n int64) string {
	f := float64(n)
	for _, unit := range []string{"bytes", "KB", "MB", "GB", "TB"} {
		if f < 1024 || unit == "TB" {
			if unit == "bytes" {
				return fmt.Sprintf("%.0f %s", f, unit)
			}
			return fmt.Sprintf("%.1f %s", f, unit)
		}
		f /= 1024
	}
	return ""
}

func page(w http.ResponseWriter, status int, title, body string) {
	for k, v := range securityHeaders {
		w.Header().Set(k, v)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	fmt.Fprintf(w, `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · HomeDrive</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #f8fafd; color: #1f1f1f; }
  .card { background: #fff; border-radius: 20px; padding: 36px 40px; width: min(420px, 86vw);
          box-shadow: 0 1px 3px rgba(0,0,0,.12), 0 8px 24px rgba(0,0,0,.06); text-align: center; }
  .brand { color: #0b57d0; font-weight: 600; letter-spacing: .2px; margin-bottom: 22px; }
  .icon { font-size: 54px; line-height: 1; margin-bottom: 10px; }
  h1 { font-size: 19px; font-weight: 500; margin: 0 0 4px; word-break: break-word; }
  .meta { color: #5f6368; font-size: 13px; margin-bottom: 26px; }
  .btn { display: inline-block; background: #0b57d0; color: #fff; border: 0; border-radius: 999px;
         padding: 12px 28px; font: inherit; font-weight: 500; text-decoration: none; cursor: pointer; }
  input { width: 100%%; box-sizing: border-box; padding: 12px 16px; border-radius: 12px; font: inherit;
          border: 1px solid #c4c7c5; margin-bottom: 14px; background: transparent; color: inherit; }
  .err { color: #b3261e; font-size: 13px; margin: -6px 0 12px; }
  .foot { color: #80868b; font-size: 12px; margin-top: 26px; }
  @media (prefers-color-scheme: dark) {
    body { background: #1b1c1d; color: #e3e3e3; }
    .card { background: #131314; box-shadow: none; border: 1px solid #3c4043; }
    .brand { color: #a8c7fa; } .btn { background: #a8c7fa; color: #062e6f; }
    .meta, .foot { color: #9aa0a6; }
  }
</style></head>
<body><main class="card"><div class="brand">HomeDrive</div>%s</main></body></html>`, html.EscapeString(title), body)
}

func gone(w http.ResponseWriter) {
	page(w, 404, "Link unavailable", `<div class="icon">🔗</div><h1>This link isn't available</h1>
<div class="meta">It may have expired or been turned off by the person who shared it.</div>`)
}

type publicApp struct {
	srv     *Server
	secret  string
	limiter *Limiter
}

// publicIP: the visitor's address. Tailscale Funnel adds it to the END of
// X-Forwarded-For; anything before was sent by the visitor and can be faked.
func publicIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		parts := strings.Split(fwd, ",")
		if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
			return last
		}
	}
	return clientIP(r)
}

func (a *publicApp) lookup(token string) (*Share, string, bool) {
	if len(token) > 64 || token == "" {
		return nil, "", false
	}
	for _, c := range token {
		if !(c == '-' || c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return nil, "", false
		}
	}
	sh := a.srv.links.Get(token)
	if sh == nil || !sh.Active() {
		return nil, "", false
	}
	space := a.srv.spaceFor(sh.Owner, sh.OwnerIsAdmin, false)
	p, err := space.Resolve(sh.Path)
	if err != nil || !exists(p) || isDir(p) != sh.IsDir {
		return nil, "", false
	}
	return sh, p, true
}

func (a *publicApp) describe(sh *Share, p string) string {
	var what string
	if isDir(p) {
		n := 0
		visibleFiles(p, func(string) bool { n++; return n <= 10000 }) // a huge folder can't tie us up
		count := fmt.Sprintf("%d file", n)
		if n != 1 {
			count += "s"
		}
		if n > 10000 {
			count = "10,000+ files"
		}
		what = "Folder · " + count + " · downloads as .zip"
	} else if info, err := os.Stat(p); err == nil {
		what = sizeText(info.Size())
	}
	if sh.Expires != nil {
		days := int((*sh.Expires - now()) / 86400)
		if days > 0 {
			what += fmt.Sprintf(" · expires in %d day", days)
			if days != 1 {
				what += "s"
			}
		} else {
			what += " · expires today"
		}
	}
	return what
}

func (a *publicApp) downloadPage(w http.ResponseWriter, sh *Share, p, unlock string) {
	icon := "📄"
	if isDir(p) {
		icon = "📁"
	}
	href := "/s/" + sh.Token + "/download"
	if unlock != "" {
		href += "?k=" + url.QueryEscape(unlock)
	}
	name := filepath.Base(p)
	page(w, 200, name, fmt.Sprintf(`<div class="icon">%s</div><h1>%s</h1>
<div class="meta">%s</div>
<a class="btn" href="%s">Download</a>
<div class="foot">Shared from someone's HomeDrive</div>`, icon, html.EscapeString(name),
		html.EscapeString(a.describe(sh, p)), html.EscapeString(href)))
}

func (a *publicApp) passwordPage(w http.ResponseWriter, sh *Share, p, errMsg string) {
	e := ""
	if errMsg != "" {
		e = `<div class="err">` + html.EscapeString(errMsg) + `</div>`
	}
	page(w, 200, "Password needed", fmt.Sprintf(`<div class="icon">🔒</div><h1>%s</h1>
<div class="meta">This link is protected with a password.</div>
<form method="post" action="/s/%s">
<input type="password" name="password" placeholder="Password" autofocus required>%s
<button class="btn" type="submit">Unlock</button></form>`, html.EscapeString(filepath.Base(p)), sh.Token, e))
}

func (a *publicApp) Routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /s/{token}", a.throttle(func(w http.ResponseWriter, r *http.Request) {
		sh, p, ok := a.lookup(r.PathValue("token"))
		if !ok {
			gone(w)
			return
		}
		if sh.HasPassword() {
			a.passwordPage(w, sh, p, "")
		} else {
			a.downloadPage(w, sh, p, "")
		}
	}))
	mux.HandleFunc("POST /s/{token}", a.throttle(func(w http.ResponseWriter, r *http.Request) {
		sh, p, ok := a.lookup(r.PathValue("token"))
		if !ok {
			gone(w)
			return
		}
		if !sh.HasPassword() {
			a.downloadPage(w, sh, p, "")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		password := r.PostFormValue("password")
		key := "fail:" + publicIP(r)
		if a.srv.links.LockedUntil(sh.Token) > 0 || !a.limiter.Allow(key, maxIPFailures, failureWindow, false) {
			a.passwordPage(w, sh, p, "Too many wrong tries. Wait 15 minutes and try again.")
			return
		}
		if !verifyPassword(password, *sh.PwHash) {
			a.limiter.Record(key)
			a.srv.links.RecordFailure(sh.Token) // 10 wrong tries from anyone pauses the link
			a.passwordPage(w, sh, p, "That password isn't right.")
			return
		}
		a.limiter.Clear(key)
		a.downloadPage(w, sh, p, signValue(sh.Token, a.secret, unlockSeconds))
	}))
	mux.HandleFunc("GET /s/{token}/download", a.throttle(func(w http.ResponseWriter, r *http.Request) {
		sh, p, ok := a.lookup(r.PathValue("token"))
		if !ok {
			gone(w)
			return
		}
		if sh.HasPassword() && !checkSignedValue(sh.Token, r.URL.Query().Get("k"), a.secret) {
			a.passwordPage(w, sh, p, "Enter the password again to download.")
			return
		}
		a.srv.links.CountDownload(sh.Token, publicIP(r))
		if isDir(p) {
			for k, v := range securityHeaders {
				w.Header().Set(k, v)
			}
			w.Header().Set("Content-Type", "application/zip")
			w.Header().Set("Content-Disposition", attachment(filepath.Base(p)+".zip"))
			_ = writeZip(w, []zipItem{{p, filepath.Base(p)}})
			return
		}
		serveFile(w, r, p, filepath.Base(p), securityHeaders)
	}))
}

func (a *publicApp) throttle(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !a.limiter.Allow("hit:"+publicIP(r), maxHitsPerMin, time.Minute, true) {
			page(w, 429, "Slow down", "<h1>Too many requests</h1><div class='meta'>Try again in a minute.</div>")
			return
		}
		h(w, r)
	}
}
