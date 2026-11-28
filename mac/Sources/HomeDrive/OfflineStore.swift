import AppKit
import CoreServices
import Foundation
import Observation

/// Files and folders kept on this Mac and synced both ways ("Make available offline").
///
/// They live in a normal folder, ~/HomeDrive Offline, so any app can open and edit
/// them. The sync logic itself is in DriveModel+Offline.swift; this class holds the
/// pinned list, what each file looked like at the last sync (the "baseline"), and
/// watches the folder for changes.
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

    /// What a file looked like on both sides right after it was last in sync.
    struct Baseline: Codable {
        var serverModified: Double
        var serverSize: Int64
        var localModified: Double
        var localSize: Int64
    }

    struct LocalFile {
        let url: URL
        let modified: Double
        let size: Int64
    }

    private struct SavedState: Codable {
        var items: [Item]
        var baselines: [String: Baseline]
    }

    private(set) var items: [Item] = []
    var isSyncing = false
    /// A change arrived while a sync was running: run again when it finishes.
    @ObservationIgnored var syncRequested = false
    /// Set by the model: called when local files change or the poll timer fires.
    @ObservationIgnored var onNeedsSync: (() -> Void)?

    @ObservationIgnored private(set) var baselines: [String: Baseline] = [:]
    @ObservationIgnored private var stateFile: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var pendingWork: DispatchWorkItem?

    /// ~/HomeDrive Offline: a normal folder you can open in Finder.
    let filesDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("HomeDrive Offline", isDirectory: true)

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func configure(account: String) {
        let safe = account.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = dir.appendingPathComponent("\(safe).json")
        load()
    }

    // MARK: - Lookups

    func isPinned(_ path: String) -> Bool {
        items.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    func isPinnedRoot(_ path: String) -> Bool {
        items.contains { $0.path == path }
    }

    func localURL(for path: String) -> URL {
        filesDir.appendingPathComponent(LocalPath.clean(path))
    }

    /// A local copy you can open right now (nil if it hasn't downloaded yet).
    func availableCopy(of path: String) -> URL? {
        let url = localURL(for: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Server path for a file inside ~/HomeDrive Offline.
    func serverPath(for url: URL) -> String? {
        let base = filesDir.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// Every file currently on disk for one pinned item, keyed by server path.
    func localFiles(under root: Item) -> [String: LocalFile] {
        let rootURL = localURL(for: root.path)
        var result: [String: LocalFile] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        func add(_ url: URL) {
            // Skip system junk and Office/LibreOffice lock files.
            guard !Self.isIgnored(url.lastPathComponent) else { return }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let path = serverPath(for: url) else { return }
            result[path] = LocalFile(url: url,
                                     modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                     size: Int64(v.fileSize ?? 0))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) else { return [:] }
        if !isDir.boolValue {
            add(rootURL)
            return result
        }
        if let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker { add(url) }
        }
        return result
    }

    /// Names offline sync leaves alone on both sides.
    nonisolated static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$")
    }

    func rootExistsLocally(_ root: Item) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: root.path).path)
    }

    // MARK: - Baselines

    func baseline(_ path: String) -> Baseline? { baselines[path] }

    func setBaseline(_ path: String, _ b: Baseline?) {
        baselines[path] = b
    }

    func baselinePaths(under root: String) -> [String] {
        baselines.keys.filter { $0 == root || $0.hasPrefix(root + "/") }
    }

    func update(_ path: String, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.path == path }) { change(&items[i]) }
    }

    // MARK: - Pinning

    func pin(_ entries: [Entry]) {
        for entry in entries where !isPinned(entry.path) {
            // Pinning a folder covers anything inside it that was pinned on its own.
            items.removeAll { $0.path.hasPrefix(entry.path + "/") }
            items.append(Item(path: entry.path, name: entry.name, isDir: entry.isDir))
        }
        save()
    }

    /// Stop keeping it offline. The local copy goes to the Mac's Trash (not deleted
    /// outright), so an edit that hadn't synced yet can still be rescued.
    func unpin(_ path: String) {
        items.removeAll { $0.path == path }
        for key in baselinePaths(under: path) { baselines.removeValue(forKey: key) }
        let url = localURL(for: path)
        if FileManager.default.fileExists(atPath: url.path) {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        save()
    }

    /// Forget a pin without touching any files (used when its local folder disappeared).
    func forget(_ path: String) {
        items.removeAll { $0.path == path }
        for key in baselinePaths(under: path) { baselines.removeValue(forKey: key) }
        save()
    }

    // MARK: - Watching for changes

    /// Poll the server every 2 minutes and watch ~/HomeDrive Offline for edits.
    func startWatching() {
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onNeedsSync?() }
        }
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<OfflineStore>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store.localFolderChanged() }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [filesDir.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    /// Something changed in ~/HomeDrive Offline: sync a few seconds after it settles.
    func localFolderChanged() {
        guard !items.isEmpty else { return }
        scheduleSync(after: 3)
    }

    func scheduleSync(after seconds: Double) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onNeedsSync?() }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func open(_ item: Item) {
        guard let url = availableCopy(of: item.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(filesDir)
    }

    // MARK: - Persistence

    private func load() {
        items = []
        baselines = [:]
        guard let stateFile, let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        items = state.items
        baselines = state.baselines
    }

    func save() {
        guard let stateFile else { return }
        if let data = try? JSONEncoder().encode(SavedState(items: items, baselines: baselines)) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
