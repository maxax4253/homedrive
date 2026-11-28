//go:build !cgo || nowindow || !(darwin || windows)

package main

// Without the window (Linux, or builds without it), the page opens in the browser.

func windowAvailable() bool { return false }

func runWindow(url string) { _ = openInSystem(url) }
