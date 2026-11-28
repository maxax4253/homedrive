//go:build cgo && !nowindow

package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa
#import <Cocoa/Cocoa.h>

// A Mac window without menus has no Copy and Paste: add the usual app and
// Edit menus (and Close Window), so Cmd+C, Cmd+V, Cmd+A, Cmd+W and Cmd+Q work.
static void hdAddMenus(void) {
	NSMenu *bar = [[NSMenu alloc] init];

	NSMenuItem *appItem = [[NSMenuItem alloc] init];
	NSMenu *app = [[NSMenu alloc] initWithTitle:@"HomeDrive"];
	[app addItemWithTitle:@"Close HomeDrive Window" action:@selector(terminate:) keyEquivalent:@"q"];
	appItem.submenu = app;
	[bar addItem:appItem];

	NSMenuItem *editItem = [[NSMenuItem alloc] init];
	NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
	[edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
	NSMenuItem *redo = [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
	redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	[edit addItem:[NSMenuItem separatorItem]];
	[edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
	[edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
	editItem.submenu = edit;
	[bar addItem:editItem];

	NSMenuItem *winItem = [[NSMenuItem alloc] init];
	NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
	[win addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
	[win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	winItem.submenu = win;
	[bar addItem:winItem];

	[NSApp setMainMenu:bar];
}

// Closing the window ends this little window process (the server keeps running).
static void hdQuitWhenClosed(void *window) {
	NSWindow *w = (__bridge NSWindow *)window;
	[[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
		object:w queue:nil usingBlock:^(NSNotification *note) { [NSApp terminate:nil]; }];
}
*/
import "C"

import webview "github.com/webview/webview_go"

func addWindowMenus(w webview.WebView) {
	C.hdAddMenus()
	C.hdQuitWhenClosed(w.Window())
}
