import AppKit
import Foundation
import Observation

/// App state: login, current folder, and file actions.
@MainActor
@Observable
final class DriveModel {
    // Connection
    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    private(set) var isLoggedIn = false
    private var api: APIClient?

    // Browsing
    private(set) var path: String = ""
    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    var selection: Set<Entry.ID> = []
    var searchText = ""
    private(set) var storage: MeResponse?

    // Status
    var errorMessage: String?
    private(set) var busyMessage: String?
    var previewURL: URL?

    // UI state. Kept here instead of in @State because SwiftUI's @State needs a
    // macro plugin that only ships with full Xcode, not the command line tools.
    var password = ""
    var showImporter = false
    var showNewFolder = false
    var newFolderName = ""
    var renaming: Entry?
    var renameText = ""
    var deleting: [Entry] = []
    var isDropTarget = false
    private(set) var thumbImages: [String: NSImage] = [:]
    private var thumbsLoading: Set<String> = []

    static let shared = DriveModel()

    init() {
        if let url = URL(string: serverURL), !serverURL.isEmpty,
           let token = Keychain.load(account: serverURL) {
            api = APIClient(baseURL: url, token: token)
            isLoggedIn = true
        }
    }

    var visibleEntries: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !path.isEmpty }
    var folderName: String { path.isEmpty ? "Drive" : (path as NSString).lastPathComponent }

    /// Breadcrumb parts: [("Drive", ""), ("Photos", "Photos"), ("2024", "Photos/2024")]
    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("Drive", "")]
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : "\(current)/\(part)"
            result.append((String(part), current))
        }
        return result
    }

    // MARK: - Login

    func login() async {
        let password = self.password
        var text = serverURL.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else {
            errorMessage = "That server address doesn't look right."
            return
        }
        serverURL = text
        let client = APIClient(baseURL: url)
        busyMessage = "Signing in…"
        defer { busyMessage = nil }
        do {
            let result = try await client.login(username: username, password: password)
            client.token = result.token
            Keychain.save(result.token, account: text)
            UserDefaults.standard.set(text, forKey: "serverURL")
            UserDefaults.standard.set(username, forKey: "username")
            api = client
            isLoggedIn = true
            self.password = ""
            path = ""
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func logout() {
        Keychain.delete(account: serverURL)
        api = nil
        isLoggedIn = false
        entries = []
        path = ""
        backStack = []
        forwardStack = []
        storage = nil
        thumbImages = [:]
    }

    // MARK: - Navigation

    func refresh() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await api.list(path)
            selection = selection.filter { id in entries.contains { $0.id == id } }
            storage = try? await api.me()
        } catch let error as APIError where error.status == 401 {
            logout()
            errorMessage = "Your login expired. Please sign in again."
        } catch let error as APIError where error.status == 404 && !path.isEmpty {
            path = ""
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func go(to newPath: String) async {
        guard newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        path = newPath
        selection = []
        searchText = ""
        await refresh()
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        selection = []
        await refresh()
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        selection = []
        await refresh()
    }

    func goUp() async {
        guard canGoUp else { return }
        await go(to: (path as NSString).deletingLastPathComponent)
    }

    func open(_ entry: Entry) async {
        if entry.isDir {
            await go(to: entry.path)
        } else {
            await preview(entry)
        }
    }

    // MARK: - Files

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Previews", isDirectory: true)
    }

    /// Downloads the file to a cache folder and opens it in Quick Look.
    func preview(_ entry: Entry) async {
        guard let api, !entry.isDir else { return }
        let local = cacheDir.appendingPathComponent(entry.path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
        let cachedSize = (attrs?[.size] as? NSNumber)?.int64Value
        let cachedDate = attrs?[.modificationDate] as? Date
        let fresh = cachedSize == entry.size && (cachedDate ?? .distantPast) >= entry.modifiedDate
        if !fresh {
            busyMessage = "Opening \(entry.name)…"
            defer { busyMessage = nil }
            do {
                try await api.download(entry.path, to: local)
                try? FileManager.default.setAttributes([.modificationDate: entry.modifiedDate], ofItemAtPath: local.path)
            } catch {
                errorMessage = friendly(error)
                return
            }
        }
        previewURL = local
    }

    /// Saves files to ~/Downloads and shows them in Finder.
    func download(_ items: [Entry]) async {
        guard let api else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var saved: [URL] = []
        for (i, entry) in items.enumerated() where !entry.isDir {
            busyMessage = items.count > 1 ? "Downloading \(i + 1) of \(items.count)…" : "Downloading \(entry.name)…"
            let dest = uniqueURL(downloads.appendingPathComponent(entry.name))
            do {
                try await api.download(entry.path, to: dest)
                saved.append(dest)
            } catch {
                errorMessage = friendly(error)
                break
            }
        }
        busyMessage = nil
        if items.contains(where: \.isDir) {
            errorMessage = "Downloading whole folders isn't supported yet, so folders were skipped."
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    /// Uploads files and folders from the Mac into the current folder.
    func upload(_ urls: [URL]) async {
        guard let api else { return }
        let target = path
        var files: [(URL, String)] = []
        var folders: [String] = []
        for url in urls { collect(url, into: target, files: &files, folders: &folders) }

        do {
            for folder in folders {
                busyMessage = "Creating folders…"
                do { try await api.mkdir(folder) } catch let e as APIError where e.status == 409 {}
            }
            for (i, (file, folder)) in files.enumerated() {
                busyMessage = "Uploading \(i + 1) of \(files.count): \(file.lastPathComponent)"
                try await api.upload(file: file, to: folder)
            }
        } catch {
            errorMessage = friendly(error)
        }
        busyMessage = nil
        await refresh()
    }

    private func collect(_ url: URL, into folder: String, files: inout [(URL, String)], folders: inout [String]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            let sub = folder.isEmpty ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
            folders.append(sub)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children { collect(child, into: sub, files: &files, folders: &folders) }
        } else {
            files.append((url, folder))
        }
    }

    func newFolder(named name: String) async {
        guard let api, let name = cleanName(name) else { return }
        do {
            try await api.mkdir(join(path, name))
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func rename(_ entry: Entry, to name: String) async {
        guard let api, let name = cleanName(name), name != entry.name else { return }
        let parent = (entry.path as NSString).deletingLastPathComponent
        do {
            try await api.move(from: entry.path, to: join(parent, name))
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func moveToTrash(_ items: [Entry]) async {
        guard let api else { return }
        for entry in items {
            do {
                try await api.delete(entry.path)
            } catch {
                errorMessage = friendly(error)
                break
            }
        }
        selection = []
        await refresh()
    }

    func thumbnail(for entry: Entry) -> NSImage? {
        thumbImages[entry.thumbKey]
    }

    func loadThumbnail(for entry: Entry) async {
        let key = entry.thumbKey
        guard let api, entry.hasThumbnail, thumbImages[key] == nil, !thumbsLoading.contains(key) else { return }
        thumbsLoading.insert(key)
        defer { thumbsLoading.remove(key) }
        guard let data = try? await api.thumbnail(entry.path, size: 256),
              let image = NSImage(data: data) else { return }
        if thumbImages.count > 1500 { thumbImages.removeAll() }
        thumbImages[key] = image
    }

    // MARK: - Helpers

    private func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    private func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            errorMessage = "That name isn't allowed."
            return nil
        }
        return trimmed
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func friendly(_ error: Error) -> String {
        if let api = error as? APIError { return api.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return "Can't reach the server. Is Tailscale on, and is HomeDrive running?"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "macOS blocked the plain-http connection. Build the app with build-app.sh so its settings allow it."
            default: break
            }
        }
        return error.localizedDescription
    }
}
