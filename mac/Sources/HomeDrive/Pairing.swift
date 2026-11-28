import AppKit
import SwiftUI

// Device pairing: newer HomeDrive servers only let in devices that were paired
// once with a 6-digit code. Each Mac keeps its own device key (per server and
// account) next to its login; signing out keeps the key, so you only pair once.

// MARK: - Types

struct ServerInfo: Decodable {
    let version: String
    /// True when the server only lets in paired devices (older servers don't say).
    let pairing: Bool?
}

struct PairResponse: Decodable {
    let token: String
    let username: String
    let deviceKey: String

    enum CodingKeys: String, CodingKey {
        case token, username
        case deviceKey = "device_key"
    }
}

struct DeviceInfo: Decodable, Identifiable, Hashable {
    let id: String
    let user: String
    let name: String
    let created: Double
    let lastSeen: Double
    let lastIP: String?
    let thisDevice: Bool

    var lastSeenDate: Date { Date(timeIntervalSince1970: lastSeen) }

    enum CodingKeys: String, CodingKey {
        case id, user, name, created
        case lastSeen = "last_seen"
        case lastIP = "last_ip"
        case thisDevice = "this_device"
    }
}

struct PairingCode: Decodable, Identifiable, Equatable {
    let code: String
    let username: String
    let expires: Double

    var id: String { code }
    var expiresDate: Date { Date(timeIntervalSince1970: expires) }
    /// "123 456" is easier to read out loud.
    var spaced: String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }

    enum CodingKeys: String, CodingKey { case code, username, expires }

    /// Keeps just the digits of whatever was typed or pasted ("123 456" -> "123456").
    static func clean(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }
}

extension APIError {
    /// The server refused this device because it isn't (or is no longer) paired.
    var needsPairing: Bool { status == 403 && message.hasPrefix("This device isn't paired") }
}

extension TokenStore {
    /// Where this Mac's device key for a server + account is kept.
    static func deviceAccount(server: String, user: String) -> String {
        "device \(server) \(user.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}

// MARK: - API

extension APIClient {
    func serverInfo() async throws -> ServerInfo {
        try await decode(ServerInfo.self, makeRequest("health"))
    }

    func pair(code: String, username: String, password: String, deviceName: String) async throws -> PairResponse {
        try await decode(PairResponse.self, try jsonRequest("pair", body: [
            "code": code, "username": username, "password": password, "device_name": deviceName,
        ]))
    }

    func devices() async throws -> [DeviceInfo] {
        struct Reply: Decodable { let devices: [DeviceInfo] }
        return try await decode(Reply.self, makeRequest("devices")).devices
    }

    func removeDevice(_ id: String) async throws {
        _ = try await send(makeRequest("devices/\(id)", method: "DELETE"))
    }

    /// A code to pair another device, for yourself or (admin only) someone else.
    func newPairingCode(for username: String? = nil) async throws -> PairingCode {
        try await decode(PairingCode.self, try jsonRequest("devices/code", body: ["username": username ?? ""]))
    }
}

// MARK: - Model

extension DriveModel {
    static var thisMacName: String {
        Host.current().localizedName ?? "Mac"
    }

    func loadDevices() async {
        guard let api, serverPairing else { return }
        do {
            devices = try await api.devices()
        } catch {
            signOutIfExpired(error)
        }
    }

    func makePairingCode(for username: String? = nil) async {
        guard let api else { return }
        do {
            shownPairingCode = try await api.newPairingCode(for: username)
        } catch {
            signOutIfExpired(error)
            errorMessage = friendly(error)
        }
    }

    func removeDevice(_ device: DeviceInfo) async {
        guard let api else { return }
        do {
            try await api.removeDevice(device.id)
            if device.thisDevice {
                forgetDeviceKey()
                logout()
                needsPairingCode = true
                return
            }
            devices.removeAll { $0.id == device.id }
            toast("Removed \(device.name)")
        } catch {
            signOutIfExpired(error)
            errorMessage = friendly(error)
        }
    }

    /// Called while the sign-in form is filled in: does this server want a pairing
    /// code from this Mac? Then the code box shows up front.
    func checkServerPairing() async {
        let text = Self.normalizedServer(serverURL)
        guard !serverURL.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: text + "/api/health"), url.host != nil else {
            needsPairingCode = false
            return
        }
        if !username.isEmpty,
           TokenStore.load(account: TokenStore.deviceAccount(server: text, user: username)) != nil {
            needsPairingCode = false   // already paired with this server
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(ServerInfo.self, from: data) else { return }
        if !Task.isCancelled { needsPairingCode = info.pairing == true }
    }

    func forgetDeviceKey() {
        TokenStore.delete(account: TokenStore.deviceAccount(server: serverURL, user: username))
    }
}

// MARK: - Settings: this Mac and your other devices

struct DevicesGroup: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Devices") {
            ForEach(model.devices) { device in
                SettingsRow(icon: icon(device.name),
                            title: device.name + (device.thisDevice ? " (this Mac)" : ""),
                            detail: detail(device)) {
                    Button(device.thisDevice ? "Unpair…" : "Remove…") { model.removingDevice = device }
                }
            }
            SettingsRow(icon: "plus.circle", title: "Pair another device",
                        detail: "Get a 6-digit code to type in on the new device. It works once, for 10 minutes.") {
                Button("Get code") { Task { await model.makePairingCode() } }
            }
        }
        .task { await model.loadDevices() }
        .confirmationDialog(removeTitle, isPresented: removeBinding) {
            Button(model.removingDevice?.thisDevice == true ? "Unpair this Mac" : "Remove device", role: .destructive) {
                if let d = model.removingDevice { Task { await model.removeDevice(d) } }
            }
        } message: {
            Text(model.removingDevice?.thisDevice == true
                 ? "You'll be signed out, and need a new pairing code to use HomeDrive on this Mac again."
                 : "It's signed out right away and can't get back in without a new pairing code.")
        }
    }

    private func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") || n.contains("phone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("macbook") { return "laptopcomputer" }
        return "desktopcomputer"
    }

    private func detail(_ d: DeviceInfo) -> String {
        if d.thisDevice { return "Paired \(Date(timeIntervalSince1970: d.created).formatted(date: .abbreviated, time: .omitted))" }
        let seen = d.lastSeenDate.formatted(.relative(presentation: .named))
        return "Last used \(seen)" + (d.lastIP.map { " from \($0)" } ?? "")
    }

    private var removeTitle: String {
        model.removingDevice?.thisDevice == true ? "Unpair this Mac?" : "Remove \(model.removingDevice?.name ?? "this device")?"
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { model.removingDevice != nil }, set: { if !$0 { model.removingDevice = nil } })
    }
}

/// Shows a fresh pairing code (from Settings, or the admin's people list).
struct PairingCodeAlert: ViewModifier {
    @Environment(DriveModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(title, isPresented: binding) {
            Button("Copy code") {
                if let code = model.shownPairingCode?.code {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            Button("Done", role: .cancel) {}
        } message: {
            if let c = model.shownPairingCode {
                Text("On the new device, sign in as \(c.username) and type this code. "
                     + "It works once, until \(c.expiresDate.formatted(date: .omitted, time: .shortened)).")
            }
        }
    }

    private var title: String { "Pairing code: \(model.shownPairingCode?.spaced ?? "")" }

    private var binding: Binding<Bool> {
        Binding(get: { model.shownPairingCode != nil }, set: { if !$0 { model.shownPairingCode = nil } })
    }
}
