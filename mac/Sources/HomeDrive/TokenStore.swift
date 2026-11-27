import Foundation

/// Keeps the login token in a private file in Application Support (only your
/// macOS account can read it).
///
/// It used to live in the Keychain, but HomeDrive is signed without a paid Apple
/// developer account, so macOS kept asking for your Mac password before letting
/// the app read its own login. A private file avoids that prompt.
enum TokenStore {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Login", isDirectory: true)
    }

    private static func file(for account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("\(safe).token")
    }

    static func save(_ value: String, account: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(for: account)
        try? Data(value.utf8).write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(account: String) -> String? {
        guard let data = try? Data(contentsOf: file(for: account)) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: file(for: account))
    }
}
