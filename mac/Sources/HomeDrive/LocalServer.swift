import AppKit
import Foundation
import SwiftUI
import WebKit

// When this Mac is the one that keeps your files, the HomeDrive server runs
// hidden inside this app (HomeDrive.app/Contents/MacOS/homedrive-server). It
// keeps running when the app is closed and starts with the Mac, so your other
// devices can always reach your files. Its setup page and settings are shown in
// this app's own window; this Mac signs itself in (no pairing code).

struct LocalServerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum LocalServer {
    static let address = "http://127.0.0.1:8093"

    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive Server", isDirectory: true)
    }

    /// The server program inside this app (missing in a plain `swift run` build).
    static var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "homedrive-server") }

    /// This Mac has been set up to keep files.
    static var isSetUp: Bool {
        FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("app.json").path)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Is it running, and which version? (Before setup it answers without a version.)
    static func health() async -> (running: Bool, version: String?) {
        var req = URLRequest(url: URL(string: address + "/api/health")!)
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode, status == 200 || status == 503 else {
            return (false, nil)
        }
        struct Health: Decodable { let version: String }
        return (true, (try? JSONDecoder().decode(Health.self, from: data))?.version)
    }

    /// Starts the server if it isn't running, or replaces an older copy (after
    /// this app was updated).
    static func ensureRunning() async throws {
        let h = await health()
        if h.running {
            guard let v = h.version, v != appVersion, helper != nil else { return }
            _ = try? await call("shutdown", body: [:])
            for _ in 0..<40 {
                if await !health().running { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let helper else {
            throw LocalServerError("This copy of HomeDrive can't keep files. Install it with the install command or from the website.")
        }
        let p = Process()
        p.executableURL = helper
        p.arguments = ["app", "-embedded"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        for _ in 0..<60 {
            if await health().running, secret() != nil { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw LocalServerError("HomeDrive couldn't start on this Mac. If an older “HomeDrive Server” app is open, quit it from its menu-bar icon and try again.")
    }

    /// The running server's secret (only programs of this Mac user can read it).
    static func secret() -> String? {
        guard let s = try? String(contentsOf: dataDir.appendingPathComponent("app-url"), encoding: .utf8),
              let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return c.queryItems?.first { $0.name == "t" }?.value
    }

    /// The setup page / server settings, opened with the secret.
    static var pageURL: URL? {
        secret().flatMap { URL(string: address + "/app/open?t=" + $0) }
    }

    /// Calls the server's local page API (the same calls its page makes).
    static func call(_ path: String, body: [String: String]?) async throws -> Data {
        guard let token = secret() else { throw LocalServerError("HomeDrive isn't running on this Mac.") }
        var req = URLRequest(url: URL(string: address + "/app/api/" + path)!)
        req.timeoutInterval = 20
        req.httpShouldHandleCookies = false
        req.setValue("homedrive_app=\(token)", forHTTPHeaderField: "Cookie")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(address, forHTTPHeaderField: "Origin")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Detail: Decodable { let detail: String }
            let msg = (try? JSONDecoder().decode(Detail.self, from: data))?.detail ?? "HomeDrive on this Mac answered \(status)."
            throw LocalServerError(msg)
        }
        return data
    }

    struct State: Decodable {
        let setupDone: Bool
        let running: Bool?
        let filesRoot: String?
        let tailscaleStatus: Tailnet?
        let needsTailscaleLogin: Bool?

        struct Tailnet: Decodable {
            let state: String
            let address: String?
            let funnel: Bool?
            let funnelError: String?
            let error: String?
            enum CodingKeys: String, CodingKey {
                case state, address, funnel, error
                case funnelError = "funnel_error"
            }
        }
        enum CodingKeys: String, CodingKey {
            case running
            case setupDone = "setup_done"
            case filesRoot = "files_root"
            case tailscaleStatus = "tailscale_status"
            case needsTailscaleLogin = "needs_tailscale_login"
        }
    }

    static func state() async -> State? {
        guard let data = try? await call("state", body: nil) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// One line about how this Mac's HomeDrive is doing.
    static func describe(_ s: State?) -> (text: String, ok: Bool) {
        guard let s else { return ("Not running", false) }
        guard s.running == true else { return ("Couldn't start. Open its settings for details.", false) }
        switch s.tailscaleStatus?.state ?? "off" {
        case "running":
            if s.tailscaleStatus?.funnel == true { return ("Reachable from anywhere", true) }
            return ("Reachable from your devices on Tailscale", true)
        case "needs_login": return ("Needs Tailscale sign-in", false)
        case "needs_approval": return ("Waiting for Tailscale approval", false)
        case "certificate": return ("Almost ready", true)
        case "error": return ("Tailscale problem", false)
        case "off": return ("Only this Mac can reach it", false)
        default: return ("Starting…", true)
        }
    }
}

// MARK: - The server's page, in this app's window

struct ServerPage: NSViewRepresentable {
    let url: URL
    var onMessage: @MainActor (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "homedrive")
        config.websiteDataStore = .nonPersistent() // the secret changes every start; nothing to keep
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "homedrive")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onMessage: @MainActor (String) -> Void
        init(onMessage: @escaping @MainActor (String) -> Void) { self.onMessage = onMessage }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String else { return }
            Task { @MainActor in self.onMessage(text) }
        }
    }
}

/// Setup (first time) or the server's settings, in a sheet.
struct ServerPageSheet: View {
    @Environment(DriveModel.self) private var model
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.serverPageIsSetup ? "Set up HomeDrive on this Mac" : "HomeDrive on this Mac")
                    .font(.headline)
                Spacer()
                Button(model.serverPageIsSetup ? "Cancel" : "Done") { model.serverPageURL = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ServerPage(url: url) { message in
                if message == "setup-done" {
                    Task { await model.signInThisMac() }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 640, idealHeight: 820)
    }
}

// MARK: - Settings

/// Settings → "This Mac keeps your files".
struct ThisMacGroup: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        SettingsGroup(title: "This Mac keeps your files") {
            SettingsRow(icon: "internaldrive",
                        title: model.localStatus.isEmpty ? "HomeDrive on this Mac" : model.localStatus,
                        detail: detail) {
                Button("Server settings…") { Task { await model.openServerSettings() } }
            }
            Text("Address, pairing codes, the files folder, Tailscale and updates. HomeDrive keeps running on this Mac when this window is closed, and starts with the Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 46)
        }
        .task {
            while !Task.isCancelled {
                await model.refreshLocalStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var detail: String {
        let s = model.localServerState
        var parts: [String] = []
        if let a = s?.tailscaleStatus?.address { parts.append(a) }
        if let f = s?.filesRoot { parts.append("Files in " + f.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if let e = s?.tailscaleStatus?.funnelError, s?.tailscaleStatus?.funnel != true { parts.append(e) }
        return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
    }
}

// MARK: - Model

extension DriveModel {
    /// This Mac keeps the files (its server runs inside this app).
    var hostsServer: Bool { LocalServer.isSetUp }

    /// Signed in to this Mac's own server.
    var isLocalServer: Bool { serverURL == LocalServer.address }

    /// "Keep my files on this Mac": start the server and show its setup page.
    func setUpThisMac() async {
        busyMessage = "Starting HomeDrive…"
        defer { busyMessage = nil }
        do {
            try await LocalServer.ensureRunning()
            if LocalServer.isSetUp, await LocalServer.state()?.setupDone == true {
                await signInThisMac() // set up before (e.g. reinstalled the app)
                return
            }
            serverPageIsSetup = true
            serverPageURL = LocalServer.pageURL
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Show this Mac's server settings (address, pairing codes, folder, updates).
    func openServerSettings() async {
        do {
            try await LocalServer.ensureRunning()
            serverPageIsSetup = false
            serverPageURL = LocalServer.pageURL
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Sign this Mac in to its own HomeDrive: no password or code needed, since
    /// only this Mac's user can reach the server's secret.
    func signInThisMac() async {
        do {
            struct Reply: Decodable {
                let token: String
                let username: String
                let address: String
                let deviceKey: String
                enum CodingKeys: String, CodingKey {
                    case token, username, address
                    case deviceKey = "device_key"
                }
            }
            let data = try await LocalServer.call("this-device", body: ["name": Self.thisMacName])
            let r = try JSONDecoder().decode(Reply.self, from: data)
            guard let url = URL(string: r.address) else { return }
            TokenStore.save(r.deviceKey, account: TokenStore.deviceAccount(server: r.address, user: r.username))
            let client = APIClient(baseURL: url, deviceKey: r.deviceKey)
            serverPageURL = nil
            await finishSignIn(client: client, server: r.address, token: r.token, username: r.username)
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// On launch: keep this Mac's server running, and sign in to it if needed.
    func startLocalServerIfNeeded() async {
        guard LocalServer.isSetUp else { return }
        do {
            try await LocalServer.ensureRunning()
        } catch {
            errorMessage = friendly(error)
            return
        }
        if !isLoggedIn, await LocalServer.state()?.setupDone == true {
            await signInThisMac()
        }
        await refreshLocalStatus()
    }

    func refreshLocalStatus() async {
        guard hostsServer else { return }
        let s = await LocalServer.state()
        localServerState = s
        localStatus = LocalServer.describe(s).text
    }
}
