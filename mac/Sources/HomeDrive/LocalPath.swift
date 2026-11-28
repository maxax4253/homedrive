import Foundation

/// Turns a path from the server into one that can only point inside a local folder.
///
/// The server is yours, but if it were ever tampered with, a path like
/// "../../Library/LaunchAgents/x" must not let it write anywhere else on this Mac.
enum LocalPath {
    static func clean(_ serverPath: String) -> String {
        serverPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.contains("\0") }
            .joined(separator: "/")
    }
}
