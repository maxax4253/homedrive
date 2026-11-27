import AppKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SettingsGroup(title: "Share links") {
                        if model.isAdmin {
                            LinksSwitch(compact: false)
                        } else {
                            SettingsRow(icon: "link", title: model.linksEnabled ? "Share links are on" : "Share links are off",
                                        detail: model.linksEnabled ? "You can send people links to your files."
                                                                   : "Ask whoever runs this HomeDrive to turn them on.") { EmptyView() }
                        }
                    }

                    SettingsGroup(title: "Account") {
                        SettingsRow(icon: "person.crop.circle",
                                    title: model.username + (model.isAdmin ? " (admin)" : ""),
                                    detail: model.serverURL) {
                            HStack(spacing: 8) {
                                if !model.isAdmin {
                                    Button("Change password…") { model.showChangePassword = true }
                                }
                                Button("Sign out") { model.logout() }
                            }
                        }
                        if model.isAdmin {
                            Text("The admin password is set on the server: run “homedrive password” there.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.leading, 46)
                        }
                    }

                    SettingsGroup(title: "Offline") {
                        SettingsRow(icon: "arrow.triangle.2.circlepath",
                                    title: "~/HomeDrive Offline",
                                    detail: "\(model.offline.items.count) item\(model.offline.items.count == 1 ? "" : "s") kept offline · \(Format.size(model.offline.totalBytes)) on this Mac") {
                            HStack(spacing: 8) {
                                Button("Open folder") { model.offline.revealFolder() }
                                Button("Remove all…") { model.confirmRemoveOffline = true }
                                    .disabled(model.offline.items.isEmpty)
                            }
                        }
                    }

                    SettingsGroup(title: "About") {
                        SettingsRow(icon: "app.badge",
                                    title: "HomeDrive \(model.appVersion)",
                                    detail: updateDetail) {
                            HStack(spacing: 8) {
                                if model.checkingForUpdate {
                                    ProgressView().controlSize(.small)
                                }
                                if model.updateAvailable {
                                    Button("Install update") { Task { await model.installUpdate() } }
                                        .keyboardShortcut(.defaultAction)
                                } else {
                                    Button("Check for updates") { Task { await model.checkForUpdate() } }
                                }
                            }
                        }
                        SettingsRow(icon: "server.rack",
                                    title: "Server \(model.serverVersion ?? "…")",
                                    detail: "Update the server with “homedrive update” on the server.") { EmptyView() }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .confirmationDialog("Remove all offline copies?", isPresented: removeBinding) {
            Button("Remove from this Mac", role: .destructive) {
                for item in model.offline.items { model.offline.unpin(item.path) }
            }
        } message: {
            Text("This frees up space on your Mac. Everything stays on HomeDrive. Make sure any edits you made offline have synced first.")
        }
    }

    private var updateDetail: String {
        if let latest = model.latestRelease {
            return model.updateAvailable ? "Version \(latest) is available." : "You're up to date."
        }
        return "Mac app"
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { model.confirmRemoveOffline }, set: { model.confirmRemoveOffline = $0 })
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubHeader(title: title)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Model: toast, version, updates

extension DriveModel {
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var updateAvailable: Bool {
        guard let latest = latestRelease else { return false }
        return latest.compare(appVersion, options: .numeric) == .orderedDescending
    }

    /// Short confirmation at the bottom of the window ("Link copied").
    func toast(_ text: String) {
        toastMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toastMessage == text { toastMessage = nil }
        }
    }

    private static let releasesAPI = URL(string: "https://api.github.com/repos/maxax4253/homedrive/releases/latest")!
    private static let latestZip = URL(string: "https://github.com/maxax4253/homedrive/releases/latest/download/HomeDrive.zip")!

    func checkForUpdate() async {
        checkingForUpdate = true
        defer { checkingForUpdate = false }
        struct Release: Decodable { let tag_name: String }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.releasesAPI)
            let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
            latestRelease = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        } catch {
            errorMessage = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    /// Download the newest build, swap it in place of this app, and relaunch.
    func installUpdate() async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("homedrive-update-\(UUID().uuidString)", isDirectory: true)
        busyMessage = "Downloading update…"
        defer { busyMessage = nil }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (zip, _) = try await URLSession.shared.download(from: Self.latestZip)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            let newApp = work.appendingPathComponent("HomeDrive.app")
            guard unzip.terminationStatus == 0, fm.fileExists(atPath: newApp.path) else {
                errorMessage = "The update download didn't look right, so nothing was changed."
                return
            }
            let current = Bundle.main.bundleURL
            guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                errorMessage = "HomeDrive can't replace itself in \(current.deletingLastPathComponent().path). Run the install command in Terminal instead."
                return
            }
            // A tiny script finishes the swap after HomeDrive quits, then reopens it.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1" && mv "$2" "$1" && xattr -dr com.apple.quarantine "$1" 2>/dev/null
            /System/Library/CoreServices/pbs -update >/dev/null 2>&1
            open "$1"
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script, "sh", current.path, newApp.path]
            try swap.run()
            NSApp.terminate(nil)
        } catch {
            errorMessage = "Couldn't install the update: \(error.localizedDescription)"
        }
    }
}
