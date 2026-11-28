//go:build !notray

package main

// The menu-bar icon (Mac) / tray icon (Windows, Linux):
//
//	HomeDrive is running · reachable from anywhere
//	Open HomeDrive…
//	Pair a device…
//	Open files folder
//	─────────
//	✓ Start when this computer starts
//	Quit HomeDrive

import (
	"context"
	_ "embed"
	"os"
	"runtime"
	"time"

	"fyne.io/systray"
)

//go:embed assets/tray-template.png
var trayTemplateIcon []byte

//go:embed assets/tray.png
var trayPNG []byte

//go:embed assets/tray.ico
var trayICO []byte

func trayAvailable() bool {
	if runtime.GOOS == "linux" || runtime.GOOS == "freebsd" {
		// Needs a desktop session (not e.g. a server reached over SSH).
		return (os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != "") && os.Getenv("DBUS_SESSION_BUS_ADDRESS") != ""
	}
	return true
}

func runTray(ctx context.Context, a *App, quit func()) {
	systray.Run(func() { trayReady(ctx, a) }, quit)
}

func trayReady(ctx context.Context, a *App) {
	switch runtime.GOOS {
	case "darwin":
		systray.SetTemplateIcon(trayTemplateIcon, trayTemplateIcon) // follows light/dark menu bar
	case "windows":
		systray.SetIcon(trayICO)
	default:
		systray.SetIcon(trayPNG)
	}
	systray.SetTooltip("HomeDrive")

	status := systray.AddMenuItem("HomeDrive is starting…", "")
	status.Disable()
	open := systray.AddMenuItem("Open HomeDrive…", "Status, settings and pairing codes")
	pairItem := systray.AddMenuItem("Pair a device…", "Get a code to sign in on a new device")
	folder := systray.AddMenuItem("Open files folder", "")
	update := systray.AddMenuItem("Update available…", "Install the new version of HomeDrive")
	update.Hide()
	systray.AddSeparator()
	autostart := systray.AddMenuItemCheckbox("Start when this computer starts", "", autostartOn())
	quitItem := systray.AddMenuItem("Quit HomeDrive", "Your devices can't reach your files while it's closed")

	refresh := func() {
		text, ok := trayStatus(a)
		status.SetTitle(text)
		if ok {
			pairItem.Enable()
			folder.Enable()
		} else {
			pairItem.Disable()
			folder.Disable()
		}
		if rel := a.updates.available(); rel != nil {
			update.SetTitle("Update to version " + rel.Version + "…")
			update.Show()
		} else {
			update.Hide()
		}
		if autostartOn() {
			autostart.Check()
		} else {
			autostart.Uncheck()
		}
	}
	refresh()

	go func() {
		tick := time.NewTicker(3 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				systray.Quit()
				return
			case <-tick.C:
				refresh()
			case <-open.ClickedCh:
				_ = openInSystem(a.OpenURL())
			case <-pairItem.ClickedCh:
				_ = openInSystem(a.OpenURL()) // the dashboard has the pairing code button
			case <-update.ClickedCh:
				_ = openInSystem(a.OpenURL()) // the page asks first and shows progress
			case <-folder.ClickedCh:
				if s := a.settings.Load(); s != nil {
					_ = openInSystem(s.FilesRoot)
				}
			case <-autostart.ClickedCh:
				_ = setAutostart(!autostartOn())
				refresh()
			case <-quitItem.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

// trayStatus is the one-line status shown at the top of the menu.
func trayStatus(a *App) (string, bool) {
	if !a.SetupDone() {
		return "Not set up yet", false
	}
	d := a.drive.Load()
	if d == nil {
		return "Couldn't start (open HomeDrive for details)", false
	}
	s := a.settings.Load()
	if !s.Tailscale {
		return "Running · this computer only", true
	}
	switch ts := d.tailnetStatus(); ts.State {
	case "running":
		if ts.Funnel {
			return "Running · reachable from anywhere", true
		}
		return "Running · your devices only", true
	case "needs_login":
		return "Needs Tailscale sign-in", true
	case "needs_approval":
		return "Waiting for Tailscale approval", true
	case "error":
		return "Tailscale problem (open HomeDrive)", true
	}
	return "Starting…", true
}
