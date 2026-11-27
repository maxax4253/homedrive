import AppKit
import SwiftUI

@main
struct HomeDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DriveModel()

    var body: some Scene {
        WindowGroup("HomeDrive") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run` so it gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isLoggedIn {
                BrowserView()
            } else {
                LoginView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
