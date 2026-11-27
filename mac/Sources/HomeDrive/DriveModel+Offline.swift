import AppKit
import CryptoKit
import Foundation

/// Two-way sync for files kept offline in ~/HomeDrive Offline.
///
/// For every file we compare three things: the server copy now, the local copy now,
/// and the "baseline" (both sides right after the last sync). That tells us who
/// changed what:
///
///   only the server changed   -> download it
///   only your Mac changed     -> upload it (old server copy goes to version history)
///   both changed              -> keep both: yours is uploaded as a "(conflict …)" copy
///   new file on your Mac      -> upload it
///   deleted on your Mac       -> move it to HomeDrive's Trash (recoverable)
///   deleted on the server     -> remove the local copy (unless you edited it: then re-upload)
extension DriveModel {
    struct SyncResult {
        var serverChanged = false
        var needsAnotherPass = false
        var notes: [String] = []
    }

    // MARK: - Turning offline on and off

    func setOffline(_ items: [Entry], _ on: Bool) async {
        if on {
            offline.pin(items)
            await syncOffline()
        } else {
            for item in items where offline.isPinnedRoot(item.path) {
                offline.unpin(item.path)
            }
        }
    }

    func startOfflineSync() {
        offline.onNeedsSync = { [weak self] in
            Task { await self?.syncOffline() }
        }
        offline.startWatching()
    }

    // MARK: - Syncing

    func syncOffline() async {
        guard let api, !offline.items.isEmpty else { return }
        if offline.isSyncing {
            offline.syncRequested = true
            return
        }
        offline.isSyncing = true
        offline.syncRequested = false
        var anotherPass = false
        var serverChanged = false
        var notes: [String] = []

        for root in offline.items {
            guard offline.isPinnedRoot(root.path) else { continue }
            do {
                let result = try await syncRoot(root, api: api)
                anotherPass = anotherPass || result.needsAnotherPass
                serverChanged = serverChanged || result.serverChanged
                notes += result.notes
                let files = offline.localFiles(under: root)
                offline.update(root.path) { item in
                    item.bytes = files.values.reduce(0) { $0 + $1.size }
                    item.fileCount = files.count
                    item.lastSync = Date().timeIntervalSince1970
                    item.error = nil
                }
            } catch let error as APIError where error.status == 404 {
                offline.update(root.path) { $0.error = "No longer on HomeDrive (moved or deleted). Your local copy is still here." }
            } catch let error as APIError where error.status == 401 {
                signOutIfExpired(error)
                break
            } catch {
                offline.update(root.path) { $0.error = "Can't reach HomeDrive. Changes will sync when you're back online." }
            }
        }

        offline.isSyncing = false
        offline.save()
        if let note = notes.first { errorMessage = note }
        if anotherPass || offline.syncRequested { offline.scheduleSync(after: anotherPass ? 3 : 1) }
        if serverChanged { await refresh() }
    }

    private func syncRoot(_ root: OfflineStore.Item, api: APIClient) async throws -> SyncResult {
        var result = SyncResult()

        // You deleted the whole thing from ~/HomeDrive Offline: treat that as
        // "stop keeping it offline", never as "delete everything on HomeDrive".
        if !offline.rootExistsLocally(root) && !offline.baselinePaths(under: root.path).isEmpty {
            offline.forget(root.path)
            result.notes.append("“\(root.name)” was removed from your HomeDrive Offline folder, so it's no longer kept offline. Nothing was deleted from HomeDrive.")
            return result
        }

        let remoteList = try await api.tree(root.path)
        var remote: [String: Entry] = [:]
        for entry in remoteList where !entry.isDir { remote[entry.path] = entry }
        let local = offline.localFiles(under: root)
        let known = Set(offline.baselinePaths(under: root.path))
        let allPaths = Set(remote.keys).union(local.keys).union(known)
        let now = Date().timeIntervalSince1970

        // Safety net: if lots of files vanished locally at once (an accident, or a
        // drive hiccup), don't delete them on the server. Bring them back instead.
        let localDeletions = allPaths.filter { p in
            guard let r = remote[p], local[p] == nil, let b = offline.baseline(p) else { return false }
            return same(r.modified, b.serverModified) && r.size == b.serverSize
        }
        let tooManyDeletions = localDeletions.count > max(10, known.count * 3 / 10)
        if tooManyDeletions {
            result.notes.append("\(localDeletions.count) files disappeared from “\(root.name)” in your HomeDrive Offline folder at once. To be safe they weren't deleted from HomeDrive. They'll download again.")
        }

        for path in allPaths.sorted() {
            guard offline.isPinnedRoot(root.path) else { break }   // un-pinned mid-sync
            let r = remote[path]
            let l = local[path]
            let b = offline.baseline(path)

            // Still being written by an app: come back in a few seconds.
            if let l, now - l.modified < 2 {
                result.needsAnotherPass = true
                continue
            }

            switch (r, l, b) {
            case let (r?, l?, b?):
                let serverChanged = !same(r.modified, b.serverModified) || r.size != b.serverSize
                let localChanged = !same(l.modified, b.localModified) || l.size != b.localSize
                if serverChanged && localChanged {
                    try await keepBoth(path: path, local: l, remote: r, api: api, reason: "Changed in both places, so both copies were kept")
                    result.serverChanged = true
                } else if localChanged {
                    try await uploadEdit(path: path, local: l, base: b, remote: r, api: api)
                    result.serverChanged = true
                } else if serverChanged {
                    try await download(r, api: api)
                }

            case let (r?, l?, nil):
                // Both exist but we never synced them (first sync): same file?
                if l.size == r.size, try await sameContents(local: l, remotePath: path, api: api) {
                    offline.setBaseline(path, .init(serverModified: r.modified, serverSize: r.size,
                                                    localModified: l.modified, localSize: l.size))
                } else {
                    try await keepBoth(path: path, local: l, remote: r, api: api, reason: "Different copies on your Mac and HomeDrive, so both were kept")
                    result.serverChanged = true
                }

            case let (r?, nil, b?):
                let serverChanged = !same(r.modified, b.serverModified) || r.size != b.serverSize
                if serverChanged || tooManyDeletions {
                    try await download(r, api: api)          // changed on server, or safety net: bring it back
                } else {
                    try await deleteOnServer(path, api: api)  // you deleted it locally
                    result.serverChanged = true
                }

            case let (r?, nil, nil):
                try await download(r, api: api)               // new on the server

            case let (nil, l?, b?):
                let localChanged = !same(l.modified, b.localModified) || l.size != b.localSize
                if localChanged {
                    try await uploadNew(path: path, local: l, api: api, note: "Deleted on HomeDrive but you edited it, so it was uploaded again")
                    result.serverChanged = true
                } else {
                    try? FileManager.default.removeItem(at: l.url)   // deleted on the server
                    offline.setBaseline(path, nil)
                }

            case let (nil, l?, nil):
                try await uploadNew(path: path, local: l, api: api, note: "Added from your HomeDrive Offline folder")
                result.serverChanged = true

            case (nil, nil, _?):
                offline.setBaseline(path, nil)                 // gone everywhere

            case (nil, nil, nil):
                break
            }
        }
        return result
    }

    // MARK: - Steps

    private func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1 }

    private func download(_ entry: Entry, api: APIClient) async throws {
        let url = offline.localURL(for: entry.path)
        try await api.download(entry.path, to: url)
        try? FileManager.default.setAttributes([.modificationDate: entry.modifiedDate], ofItemAtPath: url.path)
        recordBaseline(entry.path, url: url, serverModified: entry.modified, serverSize: entry.size)
    }

    private func uploadEdit(path: String, local: OfflineStore.LocalFile, base: OfflineStore.Baseline,
                            remote: Entry, api: APIClient) async throws {
        let folder = (path as NSString).deletingLastPathComponent
        let id = addTransfer(Transfer(name: local.url.lastPathComponent, kind: .upload, isFolder: false, bytesTotal: local.size))
        updateTransfer(id) { $0.state = .active }
        do {
            let saved = try await api.upload(file: local.url, to: folder, replace: true,
                                             ifModified: base.serverModified, progress: transferProgress(id))
            recordBaseline(path, url: local.url, serverModified: saved.modified, serverSize: saved.size)
            updateTransfer(id) { t in t.state = .done; t.note = "Synced from HomeDrive Offline" }
            scheduleAutoClose()
        } catch let error as APIError where error.status == 409 {
            updateTransfer(id) { t in t.state = .done; t.note = "Changed on HomeDrive too, so both copies were kept" }
            try await keepBoth(path: path, local: local, remote: remote, api: api, reason: nil)
        } catch {
            let message = friendly(error)
            updateTransfer(id) { $0.state = .failed(message) }
            throw error
        }
    }

    private func uploadNew(path: String, local: OfflineStore.LocalFile, api: APIClient, note: String) async throws {
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty {
            do { try await api.mkdir(folder) } catch let e as APIError where e.status == 409 { _ = e }
        }
        let id = addTransfer(Transfer(name: local.url.lastPathComponent, kind: .upload, isFolder: false, bytesTotal: local.size))
        updateTransfer(id) { $0.state = .active }
        do {
            let saved = try await api.upload(file: local.url, to: folder, progress: transferProgress(id))
            var url = local.url
            if saved.path != path {
                // The server picked a different name (one already existed): match it locally.
                let newURL = offline.localURL(for: saved.path)
                try? FileManager.default.moveItem(at: local.url, to: newURL)
                url = newURL
            }
            recordBaseline(saved.path, url: url, serverModified: saved.modified, serverSize: saved.size)
            updateTransfer(id) { t in t.state = .done; t.note = note }
            scheduleAutoClose()
        } catch {
            let message = friendly(error)
            updateTransfer(id) { $0.state = .failed(message) }
            throw error
        }
    }

    /// Upload your version under a new "(conflict …)" name, then download the server's
    /// version over the original. You end up with both, nothing lost.
    private func keepBoth(path: String, local: OfflineStore.LocalFile, remote: Entry,
                          api: APIClient, reason: String?) async throws {
        let folder = (path as NSString).deletingLastPathComponent
        let copy = try conflictCopy(of: local.url)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let saved = try await api.upload(file: copy, to: folder)
        // Put the conflict copy next to the original locally too, already in sync.
        let copyURL = offline.localURL(for: saved.path)
        try? FileManager.default.removeItem(at: copyURL)
        try FileManager.default.copyItem(at: local.url, to: copyURL)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: saved.modified)],
                                               ofItemAtPath: copyURL.path)
        recordBaseline(saved.path, url: copyURL, serverModified: saved.modified, serverSize: saved.size)
        try await download(remote, api: api)
        if let reason {
            let id = addTransfer(Transfer(name: copyURL.lastPathComponent, kind: .upload, isFolder: false, bytesTotal: local.size))
            updateTransfer(id) { t in t.state = .done; t.note = reason }
            scheduleAutoClose()
        }
    }

    private func deleteOnServer(_ path: String, api: APIClient) async throws {
        do {
            try await api.delete(path)
        } catch let e as APIError where e.status == 404 {
            _ = e   // already gone
        }
        offline.setBaseline(path, nil)
    }

    private func recordBaseline(_ path: String, url: URL, serverModified: Double, serverSize: Int64) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let localModified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? serverModified
        let localSize = (attrs?[.size] as? NSNumber)?.int64Value ?? serverSize
        offline.setBaseline(path, .init(serverModified: serverModified, serverSize: serverSize,
                                        localModified: localModified, localSize: localSize))
    }

    private func sameContents(local: OfflineStore.LocalFile, remotePath: String, api: APIClient) async throws -> Bool {
        let remoteHash = try await api.hash(remotePath)
        return remoteHash == Self.sha256(of: local.url)
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
