//go:build notray

package main

import "context"

func trayAvailable() bool { return false }

func runTray(ctx context.Context, a *App, quit func()) { <-ctx.Done(); quit() }
