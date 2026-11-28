//go:build cgo && !nowindow

package main

import webview "github.com/webview/webview_go"

// Edge WebView2 already has copy/paste and closes the process with the window.
func addWindowMenus(w webview.WebView) {}
