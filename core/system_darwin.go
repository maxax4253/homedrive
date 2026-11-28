package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func openInSystem(target string) error { return exec.Command("open", target).Start() }

func showError(title, msg string) {
	script := fmt.Sprintf("display alert %q message %q as critical", title, msg)
	_ = exec.Command("osascript", "-e", script).Run()
}

const launchAgentLabel = "com.homedrive.server"

func launchAgentPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", launchAgentLabel+".plist")
}

func autostartOn() bool {
	_, err := os.Stat(launchAgentPath())
	return err == nil
}

func setAutostart(on bool) error {
	p := launchAgentPath()
	if !on {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(launchAgentPlist(exe)), 0o644)
}

func launchAgentPlist(exe string) string {
	esc := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>` + launchAgentLabel + `</string>
	<key>ProgramArguments</key><array><string>` + esc(exe) + `</string><string>app</string></array>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
`
}
