import Foundation

// MARK: - Types for accounts, links, versions and backups

struct UserInfo: Codable, Identifiable, Hashable {
    let username: String
    let isAdmin: Bool
    let quota: Int64?
    let used: Int64?

    var id: String { username }

    enum CodingKeys: String, CodingKey {
        case username, quota, used
        case isAdmin = "is_admin"
    }
}

struct UsersResponse: Codable {
    let users: [UserInfo]
}

struct ShareLink: Codable, Identifiable, Hashable {
    let token: String
    let path: String
    let name: String
    let isDir: Bool
    let created: Double
    let expires: Double?
    let hasPassword: Bool
    let downloads: Int
    let active: Bool
    let url: String?

    var id: String { token }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
    var expiresDate: Date? { expires.map { Date(timeIntervalSince1970: $0) } }

    enum CodingKeys: String, CodingKey {
        case token, path, name, created, expires, downloads, active, url
        case isDir = "is_dir"
        case hasPassword = "has_password"
    }
}

struct SharesResponse: Codable {
    let linksEnabled: Bool
    let shares: [ShareLink]

    enum CodingKeys: String, CodingKey {
        case shares
        case linksEnabled = "links_enabled"
    }
}

struct FileVersion: Codable, Identifiable, Hashable {
    let id: String
    let source: String      // "edit" or "backup"
    let modified: Double
    let size: Int64
    let saved: Double

    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    var savedDate: Date { Date(timeIntervalSince1970: saved) }
    var isBackup: Bool { source == "backup" }
}

struct VersionsResponse: Codable {
    struct Current: Codable {
        let modified: Double
        let size: Int64
    }
    let current: Current
    let versions: [FileVersion]
}

struct BackupStatus: Codable {
    let enabled: Bool
    let running: Bool
    let hour: Int
    let lastRun: Double?
    let lastSuccess: Double?
    let lastError: String?
    let lastDuration: Double?
    let snapshots: [String]
    let free: Int64?
    let total: Int64?

    enum CodingKeys: String, CodingKey {
        case enabled, running, hour, snapshots, free, total
        case lastRun = "last_run"
        case lastSuccess = "last_success"
        case lastError = "last_error"
        case lastDuration = "last_duration"
    }
}

struct LinksStatus: Codable {
    let enabled: Bool
    let publicURL: String?
    let agentInstalled: Bool
    let pending: Bool
    let state: String          // idle, working, done, needs_approval, error
    let message: String?
    let approveURL: String?

    enum CodingKeys: String, CodingKey {
        case enabled, pending, state, message
        case publicURL = "public_url"
        case agentInstalled = "agent_installed"
        case approveURL = "approve_url"
    }

    var isWorking: Bool { pending || state == "working" }
}

struct TokenResponse: Codable {
    let token: String
}

// MARK: - Endpoints

extension APIClient {
    func hash(_ path: String) async throws -> String {
        struct HashResponse: Decodable { let sha256: String }
        return try await decode(HashResponse.self, makeRequest("hash", query: ["path": path])).sha256
    }

    func tree(_ path: String) async throws -> [Entry] {
        try await decode(EntriesResponse.self, makeRequest("tree", query: ["path": path])).entries
    }

    // Version history

    func versions(_ path: String) async throws -> VersionsResponse {
        try await decode(VersionsResponse.self, makeRequest("versions", query: ["path": path]))
    }

    func downloadVersion(_ path: String, version: String, to destination: URL) async throws {
        try await fetchFile(makeRequest("versions/download", query: ["path": path, "version": version]),
                            to: destination, progress: { _, _ in })
    }

    func restoreVersion(_ path: String, version: String) async throws {
        _ = try await send(try jsonRequest("versions/restore", body: ["path": path, "version": version]))
    }

    // Backups

    func backupStatus() async throws -> BackupStatus {
        try await decode(BackupStatus.self, makeRequest("backups"))
    }

    func runBackup() async throws {
        _ = try await send(makeRequest("backups/run", method: "POST"))
    }

    // Share links

    func shares() async throws -> SharesResponse {
        try await decode(SharesResponse.self, makeRequest("shares"))
    }

    func createShare(_ path: String, expiresDays: Double?, password: String?) async throws -> ShareLink {
        struct Body: Encodable {
            let path: String
            let expires_days: Double?
            let password: String?
        }
        return try await decode(ShareLink.self, try jsonRequest("shares", body: Body(path: path, expires_days: expiresDays, password: password)))
    }

    func revokeShare(_ token: String) async throws {
        _ = try await send(makeRequest("shares/\(token)", method: "DELETE"))
    }

    // Share links switch (admin)

    func linksStatus() async throws -> LinksStatus {
        try await decode(LinksStatus.self, makeRequest("admin/links"))
    }

    func setLinks(_ enabled: Bool) async throws -> LinksStatus {
        struct Body: Encodable { let enabled: Bool }
        return try await decode(LinksStatus.self, try jsonRequest("admin/links", body: Body(enabled: enabled)))
    }

    // Accounts

    func users() async throws -> [UserInfo] {
        try await decode(UsersResponse.self, makeRequest("users")).users
    }

    func addUser(_ username: String, password: String, quotaGB: Double?) async throws {
        struct Body: Encodable {
            let username: String
            let password: String
            let quota_gb: Double?
        }
        _ = try await send(try jsonRequest("users", body: Body(username: username, password: password, quota_gb: quotaGB)))
    }

    func resetPassword(_ username: String, password: String) async throws {
        _ = try await send(try jsonRequest("users/\(username)/password", body: ["password": password]))
    }

    func setQuota(_ username: String, quotaGB: Double?) async throws {
        struct Body: Encodable { let quota_gb: Double? }
        _ = try await send(try jsonRequest("users/\(username)/quota", body: Body(quota_gb: quotaGB)))
    }

    func deleteUser(_ username: String) async throws {
        _ = try await send(makeRequest("users/\(username)", method: "DELETE"))
    }

    func changeMyPassword(old: String, new: String) async throws -> String {
        try await decode(TokenResponse.self, try jsonRequest("me/password", body: ["old_password": old, "new_password": new])).token
    }
}
