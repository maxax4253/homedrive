module github.com/maxax4253/homedrive/core

// Builds HomeDrive without the built-in Tailscale, using only Go's standard
// library (works with older Go):  go build -modfile=go.notailscale.mod -tags notailscale .

go 1.24
