//go:build !darwin && !windows

package main

import (
	"os"
	"strings"
	"testing"
)

func TestAutostartLinux(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if autostartOn() {
		t.Fatal("on before turning it on")
	}
	if err := setAutostart(true); err != nil || !autostartOn() {
		t.Fatalf("turn on: %v", err)
	}
	b, _ := os.ReadFile(autostartFile())
	if !strings.Contains(string(b), "Exec=\"") || !strings.Contains(string(b), "\" app\n") {
		t.Fatalf("desktop entry:\n%s", b)
	}
	if err := setAutostart(false); err != nil || autostartOn() {
		t.Fatalf("turn off: %v", err)
	}
	if err := setAutostart(false); err != nil {
		t.Fatal("turning off twice should be fine")
	}
	if got := desktopEntry(`/opt/my "odd" $dir/hd`); !strings.Contains(got, `Exec="/opt/my \"odd\" \$dir/hd" app`) {
		t.Fatalf("quoting: %s", got)
	}
}
