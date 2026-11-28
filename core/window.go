//go:build cgo && !nowindow && (darwin || windows)

package main

// The HomeDrive window: the setup page and dashboard in a proper app window
// (the system's own web view: WebKit on a Mac, Edge WebView2 on Windows), so
// nobody sees a browser or an address bar. It runs as its own small process,
// `homedrive-server window`, because the menu-bar icon already owns the main
// thread of the app process.

import (
	webview "github.com/webview/webview_go"
)

func windowAvailable() bool { return true }

func runWindow(url string) {
	w := webview.New(false)
	defer w.Destroy()
	w.SetTitle("HomeDrive")
	w.SetSize(720, 820, webview.HintNone)
	w.SetSize(560, 600, webview.HintMin)
	addWindowMenus(w)
	w.Navigate(url)
	w.Run()
}
