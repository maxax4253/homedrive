import AppKit
import SwiftUI

@main
struct HomeDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = DriveModel.shared

    var body: some Scene {
        WindowGroup("HomeDrive", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isLoggedIn)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Task { await model.show(.settings) } }
                    .keyboardShortcut(",")
                    .disabled(!model.isLoggedIn)
                Button("Sign Out") { model.logout() }
                    .disabled(!model.isLoggedIn)
            }
        }

        // On the Mac that keeps the files: one menu-bar icon with its status.
        MenuBarExtra("HomeDrive", systemImage: "externaldrive.connected.to.line.below", isInserted: menuBarBinding) {
            HomeDriveMenu().environment(model)
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.hostsServer }, set: { _ in })
    }
}

struct HomeDriveMenu: View {
    @Environment(DriveModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.localStatus.isEmpty ? "HomeDrive is running" : "HomeDrive: " + model.localStatus)
        Divider()
        Button("Open HomeDrive") { show() }
        Button("Pair a device…") {
            show()
            Task { await model.makePairingCode() }
        }
        Button("Server settings…") {
            show()
            Task { await model.openServerSettings() }
        }
        Divider()
        Button("Quit HomeDrive") { NSApp.terminate(nil) }
        Text("Your files stay reachable after quitting.")
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openWindow(id: "main")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = FinderServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run` so it gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Finder's right-click > Services > "Move to HomeDrive" / "Copy to HomeDrive".
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    /// On the Mac that keeps the files, closing the window leaves the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !LocalServer.isSetUp
    }
}

struct RootView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Group {
            if model.isLoggedIn {
                MainView()
            } else {
                LoginView()
                    .background(Theme.window)
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: serverPageBinding) {
            if let url = model.serverPageURL {
                ServerPageSheet(url: url).environment(model)
            }
        }
        .task { await model.startLocalServerIfNeeded() }
    }

    private var serverPageBinding: Binding<Bool> {
        Binding(get: { model.serverPageURL != nil }, set: { if !$0 { model.serverPageURL = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Handles the Finder right-click Services (declared under NSServices in Info.plist).
final class FinderServices: NSObject {
    @objc func moveToHomeDrive(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in await DriveModel.shared.offload(urls) }
    }

    @objc func copyToHomeDrive(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            await DriveModel.shared.upload(urls)
        }
    }

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        let objects = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}
