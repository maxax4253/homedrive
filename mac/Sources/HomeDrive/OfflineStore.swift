import AppKit
import Foundation
import Observation

/// Files and folders you chose to keep on this Mac ("Make available offline").
///
/// Copies live in ~/Library/Application Support/HomeDrive/Offline/<account>/Files and
/// are refreshed from the server every 10 minutes (and when you press Sync now).
@MainActor
@Observable
final class OfflineStore {
    struct Item: Codable, Identifiable, Hashable {
        let path: String
        let name: String
        let isDir: Bool
        var lastSync: Double?
        var bytes: Int64 = 0
        var fileCount: Int = 0
        var error: String?

        var id: String { path }
    }

    private struct FileState: Codable {
        var modified: Double
        var size: Int64
    }

    private struct SavedState: Codable {
        var items: [Item]
        var files: [String: FileState]
    }

    private(set) var items: [Item] = []
    private(set) var isSyncing = false
    private var files: [String: FileState] = [:]
    private var baseDir: URL?
    private var timer: Timer?

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func configure(account: String) {
        let safe = account.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Offline/\(safe)", isDirectory: true)
        load()
    }

    // MARK: - Lookups

    func isPinned(_ path: String) -> Bool {
        items.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    func isPinnedRoot(_ path: String) -> Bool {
        items.contains { $0.path == path }
    }

    func localURL(for path: String) -> URL? {
        baseDir?.appendingPathComponent("Files", isDirectory: true).appendingPathComponent(path)
    }

    /// A local copy you can open right now (nil if it hasn't downloaded yet).
    func availableCopy(of path: String) -> URL? {
        guard let url = localURL(for: path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Pinning

    func pin(_ entries: [Entry], api: APIClient) async {
        for entry in entries where !isPinned(entry.path) {
            // Pinning a folder covers anything inside it that was pinned on its own.
            items.removeAll { $0.path.hasPrefix(entry.path + "/") }
            items.append(Item(path: entry.path, name: entry.name, isDir: entry.isDir))
        }
        save()
        await sync(api: api)
    }

    func unpin(_ path: String) {
        items.removeAll { $0.path == path }
        for key in files.keys where key == path || key.hasPrefix(path + "/") {
            files.removeValue(forKey: key)
        }
        if let url = localURL(for: path) { try? FileManager.default.removeItem(at: url) }
        save()
    }

    func removeAll() {
        for item in items { unpin(item.path) }
    }

    // MARK: - Syncing

    func startTimer(api: @escaping @MainActor () -> APIClient?) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let client = api() else { return }
                await self.sync(api: client)
            }
        }
    }

    /// Download anything new or changed, and delete local copies of things removed on the server.
    func sync(api: APIClient) async {
        guard !isSyncing, !items.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false; save() }

        for root in items {
            // Look the item up again after each await, in case it was removed meanwhile.
            func update(_ change: (inout Item) -> Void) {
                if let i = items.firstIndex(where: { $0.path == root.path }) { change(&items[i]) }
            }
            do {
                let remote = try await api.tree(root.path)
                var bytes: Int64 = 0
                var seen = Set<String>()
                for entry in remote where !entry.isDir {
                    guard isPinnedRoot(root.path) else { break }  // removed while syncing
                    seen.insert(entry.path)
                    bytes += entry.size
                    let known = files[entry.path]
                    let local = localURL(for: entry.path)
                    let exists = local.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    if !exists || known?.modified != entry.modified || known?.size != entry.size {
                        guard let local else { continue }
                        try await api.download(entry.path, to: local)
                        try? FileManager.default.setAttributes([.modificationDate: entry.modifiedDate], ofItemAtPath: local.path)
                        files[entry.path] = FileState(modified: entry.modified, size: entry.size)
                    }
                }
                // Remove local files that no longer exist on the server.
                for key in files.keys where (key == root.path || key.hasPrefix(root.path + "/")) && !seen.contains(key) {
                    files.removeValue(forKey: key)
                    if let url = localURL(for: key) { try? FileManager.default.removeItem(at: url) }
                }
                update { item in
                    item.bytes = bytes
                    item.fileCount = seen.count
                    item.lastSync = Date().timeIntervalSince1970
                    item.error = nil
                }
            } catch let error as APIError where error.status == 404 {
                update { $0.error = "No longer on the server" }
            } catch {
                let message = "Couldn't sync: \(error.localizedDescription)"
                update { $0.error = message }
            }
        }
    }

    func open(_ item: Item) {
        guard let url = availableCopy(of: item.path) else { return }
        if item.isDir {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Persistence

    private var stateFile: URL? { baseDir?.appendingPathComponent("offline.json") }

    private func load() {
        items = []
        files = [:]
        guard let stateFile, let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        items = state.items
        files = state.files
    }

    private func save() {
        guard let baseDir, let stateFile else { return }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(SavedState(items: items, files: files)) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
