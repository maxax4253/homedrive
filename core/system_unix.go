//go:build !darwin && !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func openInSystem(target string) error { return exec.Command("xdg-open", target).Start() }

func showError(title, msg string) {
	if p, err := exec.LookPath("zenity"); err == nil {
		_ = exec.Command(p, "--error", "--title", title, "--text", msg).Run()
	}
}

func autostartFile() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "autostart", "homedrive-server.desktop")
}

func autostartOn() bool {
	_, err := os.Stat(autostartFile())
	return err == nil
}

func setAutostart(on bool) error {
	p := autostartFile()
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
	return os.WriteFile(p, []byte(desktopEntry(exe)), 0o644)
}

// desktopEntry quotes the program path the way the desktop entry spec wants.
func desktopEntry(exe string) string {
	q := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "`", "\\`", "$", `\$`).Replace(exe)
	return "[Desktop Entry]\nType=Application\nName=HomeDrive\nComment=Your own Google Drive\n" +
		"Exec=\"" + q + "\" app\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
}
