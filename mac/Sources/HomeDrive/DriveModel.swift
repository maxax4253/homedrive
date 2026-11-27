import AppKit
import Foundation
import Observation

enum DriveSection: String, CaseIterable {
    case home, drive, recent, trash

    var title: String {
        switch self {
        case .home: return "Home"
        case .drive: return "My Drive"
        case .recent: return "Recent"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .drive: return "externaldrive"
        case .recent: return "clock"
        case .trash: return "trash"
        }
    }
}

/// App state: login, what's on screen, and file actions.
///
/// All UI state lives here instead of in SwiftUI @State, because @State needs a
/// macro plugin that only ships with full Xcode, not the command line tools.
@MainActor
@Observable
final class DriveModel {
    static let shared = DriveModel()

    // Connection
    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    var password = ""
    private(set) var isLoggedIn = false
    private var api: APIClient?

    // What's on screen
    private(set) var section: DriveSection = .home
    private(set) var path: String = ""
    /// Items for the current screen (folder contents, recent files, trash, or search results).
    private(set) var entries: [Entry] = []
    /// Home screen: top-level folders shown as cards.
    private(set) var homeFolders: [Entry] = []
    private(set) var isLoading = false
    private(set) var storage: MeResponse?
    private var backStack: [(DriveSection, String)] = []
    private var forwardStack: [(DriveSection, String)] = []

    // Search
    var searchText = ""
    private(set) var activeSearch: String?

    // Selection & hover
    var selection: Set<Entry.ID> = []
    var hoveredID: Entry.ID?

    // Status
    var errorMessage: String?
    private(set) var busyMessage: String?
    var previewURL: URL?

    // Dialogs & popovers
    var showNewMenu = false
    var showNewFolder = false
    var newFolderName = ""
    var renaming: Entry?
    var renameText = ""
    var deleting: [Entry] = []
    var deletingForever: [Entry] = []
    var confirmEmptyTrash = false
    var isDropTarget = false

    // Thumbnails
    private(set) var thumbImages: [String: NSImage] = [:]
    private var thumbsLoading: Set<String> = []

    init() {
        if let url = URL(string: serverURL), !serverURL.isEmpty,
           let token = Keychain.load(account: serverURL) {
            api = APIClient(baseURL: url, token: token)
            isLoggedIn = true
        }
    }

    // MARK: - Derived

    var folders: [Entry] { entries.filter(\.isDir) }
    var files: [Entry] { entries.filter { !$0.isDir } }
    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canUpload: Bool { activeSearch == nil && (section == .drive || section == .home) }
    /// Where uploads and new folders go.
    var uploadTarget: String { section == .drive ? path : "" }

    /// Breadcrumb parts for My Drive: [("My Drive", ""), ("Photos", "Photos"), ...]
    var breadcrumbs: [Crumb] {
        var result = [Crumb(name: "My Drive", path: "")]
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : "\(current)/\(part)"
            result.append(Crumb(name: String(part), path: current))
        }
        return result
    }

    // MARK: - Login

    func login() async {
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
            password = ""
            isLoggedIn = true
            section = .home
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
        homeFolders = []
        path = ""
        section = .home
        backStack = []
        forwardStack = []
        storage = nil
        thumbImages = [:]
        activeSearch = nil
        searchText = ""
    }

    // MARK: - Loading

    func refresh() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let query = activeSearch {
                entries = try await api.search(query)
            } else {
                switch section {
                case .home:
                    homeFolders = try await api.list("").filter(\.isDir)
                    entries = try await api.recent(limit: 30)
                case .drive:
                    entries = try await api.list(path)
                case .recent:
                    entries = try await api.recent(limit: 200)
                case .trash:
                    entries = try await api.trash()
                }
            }
            selection = selection.filter { id in entries.contains { $0.id == id } }
            storage = try? await api.me()
        } catch let error as APIError where error.status == 401 {
            logout()
            errorMessage = "Your login expired. Please sign in again."
        } catch let error as APIError where error.status == 404 && section == .drive && !path.isEmpty {
            path = ""
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    // MARK: - Navigation

    private func navigate(_ newSection: DriveSection, _ newPath: String = "") async {
        let sameSpot = newSection == section && newPath == path && activeSearch == nil
        if !sameSpot {
            backStack.append((section, path))
            forwardStack.removeAll()
        }
        section = newSection
        path = newPath
        activeSearch = nil
        searchText = ""
        selection = []
        await refresh()
    }

    func show(_ newSection: DriveSection) async {
        await navigate(newSection, "")
    }

    func go(to folder: String) async {
        await navigate(.drive, folder)
    }

    func goBack() async {
        guard let last = backStack.popLast() else { return }
        forwardStack.append((section, path))
        section = last.0
        path = last.1
        activeSearch = nil
        selection = []
        await refresh()
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append((section, path))
        section = next.0
        path = next.1
        activeSearch = nil
        selection = []
        await refresh()
    }

    func search() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            await clearSearch()
            return
        }
        activeSearch = q
        selection = []
        await refresh()
    }

    func clearSearch() async {
        searchText = ""
        guard activeSearch != nil else { return }
        activeSearch = nil
        await refresh()
    }

    func open(_ entry: Entry) async {
        if section == .trash && activeSearch == nil { return }
        if entry.isDir {
            await go(to: entry.path)
        } else {
            await preview(entry)
        }
    }

    /// Jump to the folder a file lives in (from Recent/Search).
    func showLocation(of entry: Entry) async {
        await go(to: entry.parentPath)
        selection = [entry.id]
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
        let fileItems = items.filter { !$0.isDir }
        for (i, entry) in fileItems.enumerated() {
            busyMessage = fileItems.count > 1 ? "Downloading \(i + 1) of \(fileItems.count)…" : "Downloading \(entry.name)…"
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

    func pickFilesToUpload() {
        showNewMenu = false
        let panel = NSOpenPanel()
        panel.title = "Upload files"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await upload(urls) }
    }

    func pickFolderToUpload() {
        showNewMenu = false
        let panel = NSOpenPanel()
        panel.title = "Upload folder"
        panel.prompt = "Upload"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await upload(urls) }
    }

    func startNewFolder() {
        showNewMenu = false
        newFolderName = "Untitled folder"
        showNewFolder = true
    }

    /// Uploads files and folders from the Mac.
    func upload(_ urls: [URL]) async {
        guard let api else { return }
        let target = uploadTarget
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
            try await api.mkdir(join(uploadTarget, name))
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func rename(_ entry: Entry, to name: String) async {
        guard let api, let name = cleanName(name), name != entry.name else { return }
        do {
            try await api.move(from: entry.path, to: join(entry.parentPath, name))
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

    // MARK: - Trash

    func restore(_ items: [Entry]) async {
        guard let api else { return }
        for entry in items {
            guard let name = entry.trashName else { continue }
            do {
                try await api.restore(name)
            } catch {
                errorMessage = friendly(error)
                break
            }
        }
        selection = []
        await refresh()
    }

    func deleteForever(_ items: [Entry]) async {
        guard let api else { return }
        for entry in items {
            guard let name = entry.trashName else { continue }
            do {
                try await api.deleteForever(name)
            } catch {
                errorMessage = friendly(error)
                break
            }
        }
        selection = []
        await refresh()
    }

    func emptyTrash() async {
        guard let api else { return }
        do {
            try await api.emptyTrash()
        } catch {
            errorMessage = friendly(error)
        }
        selection = []
        await refresh()
    }

    // MARK: - Thumbnails

    func thumbnail(for entry: Entry) -> NSImage? {
        thumbImages[entry.thumbKey]
    }

    func loadThumbnail(for entry: Entry) async {
        let key = entry.thumbKey
        guard let api, entry.hasThumbnail, thumbImages[key] == nil, !thumbsLoading.contains(key) else { return }
        thumbsLoading.insert(key)
        defer { thumbsLoading.remove(key) }
        guard let data = try? await api.thumbnail(entry.path, size: 384),
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

struct Crumb: Hashable {
    let name: String
    let path: String
}
