package main

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

func openInSystem(target string) error {
	return exec.Command("rundll32", "url.dll,FileProtocolHandler", target).Start()
}

func showError(title, msg string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	box := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(msg)
	_, _, _ = box.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), 0x10) // MB_ICONERROR
}

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

func autostartOn() bool {
	return exec.Command("reg", "query", runKey, "/v", "HomeDrive").Run() == nil
}

func setAutostart(on bool) error {
	if !on {
		if !autostartOn() {
			return nil
		}
		return exec.Command("reg", "delete", runKey, "/v", "HomeDrive", "/f").Run()
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	value := `"` + strings.ReplaceAll(exe, `"`, ``) + `" app`
	return exec.Command("reg", "add", runKey, "/v", "HomeDrive", "/t", "REG_SZ", "/d", value, "/f").Run()
}
