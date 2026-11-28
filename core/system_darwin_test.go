package main

import (
	"strings"
	"testing"
)

func TestLaunchAgentPlist(t *testing.T) {
	p := launchAgentPlist("/Applications/HomeDrive Server.app/Contents/MacOS/homedrive-server & co")
	if !strings.Contains(p, "<string>/Applications/HomeDrive Server.app/Contents/MacOS/homedrive-server &amp; co</string>") ||
		!strings.Contains(p, "<key>RunAtLoad</key><true/>") {
		t.Fatal(p)
	}
}
