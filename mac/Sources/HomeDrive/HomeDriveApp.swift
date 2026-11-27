import AppKit
import SwiftUI

@main
struct HomeDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = DriveModel.shared

    var body: some Scene {
        WindowGroup("HomeDrive") {
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
            CommandGroup(after: .appSettings) {
                Button("Sign Out") { model.logout() }
                    .disabled(!model.isLoggedIn)
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
