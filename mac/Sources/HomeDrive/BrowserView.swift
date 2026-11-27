import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String {
    case grid, list
}

// Note: no @State anywhere. UI state lives in DriveModel so the app also builds
// with only the Xcode command line tools.

struct BrowserView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            DetailColumn()
        }
        .quickLookPreview($model.previewURL)
        .task { await model.refresh() }
        .modifier(BrowserDialogs())
    }
}

struct DetailColumn: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()
            DropArea(viewMode: viewMode)
            Divider()
            StatusBar()
        }
        .navigationTitle(model.folderName)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
        .toolbar { BrowserToolbar(viewMode: $viewMode) }
    }
}

struct DropArea: View {
    @Environment(DriveModel.self) private var model
    let viewMode: ViewMode

    var body: some View {
        FolderContent(viewMode: viewMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { dropHighlight }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.upload(urls) }
                return true
            } isTargeted: { targeted in
                model.isDropTarget = targeted
            }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if model.isDropTarget {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(6)
        }
    }
}

struct FolderContent: View {
    @Environment(DriveModel.self) private var model
    let viewMode: ViewMode

    var body: some View {
        if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView {
                Label("This folder is empty", systemImage: "folder")
            } description: {
                Text("Drag files here or click Upload.")
            }
        } else if viewMode == .grid {
            FileGrid()
        } else {
            FileList()
        }
    }
}

// MARK: - Grid

struct FileGrid: View {
    @Environment(DriveModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(model.visibleEntries) { entry in
                    tile(entry)
                }
            }
            .padding(16)
        }
        .background { backgroundTap }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { Actions.previewSelection(model) }
        .onKeyPress(.return) { Actions.openSelection(model) }
        .onDeleteCommand { model.deleting = model.selectedEntries }
    }

    private func tile(_ entry: Entry) -> some View {
        FileTile(entry: entry, isSelected: model.selection.contains(entry.id))
            .onTapGesture(count: 2) { Task { await model.open(entry) } }
            .simultaneousGesture(TapGesture().onEnded { Actions.select(entry, in: model) })
            .contextMenu { EntryMenu(items: Actions.contextItems(clicked: entry, in: model)) }
    }

    private var backgroundTap: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
    }
}

// MARK: - List

struct FileList: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Name") { (entry: Entry) in
                NameCell(entry: entry)
            }
            TableColumn("Size") { (entry: Entry) in
                SizeCell(entry: entry)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modified") { (entry: Entry) in
                DateCell(entry: entry)
            }
            .width(min: 120, ideal: 170, max: 220)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            EntryMenu(items: model.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            openFirst(ids)
        }
        .onKeyPress(.space) { Actions.previewSelection(model) }
        .onDeleteCommand { model.deleting = model.selectedEntries }
    }

    private func openFirst(_ ids: Set<Entry.ID>) {
        guard let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) else { return }
        Task { await model.open(entry) }
    }
}

struct NameCell: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 8) {
            FileIcon(entry: entry, size: 18)
            Text(entry.name).lineLimit(1)
        }
    }
}

struct SizeCell: View {
    let entry: Entry
    var body: some View {
        Text(entry.isDir ? "—" : Format.size(entry.size))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

struct DateCell: View {
    let entry: Entry
    var body: some View {
        Text(entry.modifiedDate, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Toolbar, menus, dialogs

struct BrowserToolbar: ToolbarContent {
    @Environment(DriveModel.self) private var model
    @Binding var viewMode: ViewMode

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.goBack() } } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button { Task { await model.goForward() } } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            Button { Task { await model.goUp() } } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                .disabled(!model.canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Change how files are shown")

            Button {
                model.newFolderName = "untitled folder"
                model.showNewFolder = true
            } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder")

            Button { model.showImporter = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Upload files")

            Button { Task { await model.download(model.selectedEntries) } } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selectedEntries.allSatisfy(\.isDir))
            .help("Download selected files to your Downloads folder")
        }
    }
}

struct EntryMenu: View {
    @Environment(DriveModel.self) private var model
    let items: [Entry]

    var body: some View {
        if items.count == 1, let entry = items.first {
            Button(entry.isDir ? "Open" : "Quick Look") { Task { await model.open(entry) } }
            Divider()
        }
        if items.contains(where: { !$0.isDir }) {
            Button("Download") { Task { await model.download(items) } }
        }
        if items.count == 1, let entry = items.first {
            Button("Rename…") {
                model.renameText = entry.name
                model.renaming = entry
            }
        }
        if !items.isEmpty {
            Divider()
            Button("Move to Trash", role: .destructive) { model.deleting = items }
        }
    }
}

struct BrowserDialogs: ViewModifier {
    @Environment(DriveModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("New Folder", isPresented: $model.showNewFolder) {
                TextField("Name", text: $model.newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Name", text: $model.renameText)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding) {
                Button("Move to Trash", role: .destructive) { trash() }
            } message: {
                Text("They go to the .trash folder on the server.")
            }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { !model.deleting.isEmpty }, set: { if !$0 { model.deleting = [] } })
    }

    private var deleteTitle: String {
        if model.deleting.count == 1 { return "Move “\(model.deleting[0].name)” to the trash?" }
        return "Move \(model.deleting.count) items to the trash?"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            let started = urls.map { $0.startAccessingSecurityScopedResource() }
            await model.upload(urls)
            for (url, ok) in zip(urls, started) where ok { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func createFolder() {
        let name = model.newFolderName
        Task { await model.newFolder(named: name) }
    }

    private func rename() {
        guard let entry = model.renaming else { return }
        let name = model.renameText
        Task { await model.rename(entry, to: name) }
    }

    private func trash() {
        let items = model.deleting
        Task { await model.moveToTrash(items) }
    }
}

// MARK: - Selection helpers

@MainActor
enum Actions {
    /// Right-clicking a selected item acts on the whole selection, like Finder.
    static func contextItems(clicked entry: Entry, in model: DriveModel) -> [Entry] {
        model.selection.contains(entry.id) ? model.selectedEntries : [entry]
    }

    static func select(_ entry: Entry, in model: DriveModel) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(entry.id) {
                model.selection.remove(entry.id)
            } else {
                model.selection.insert(entry.id)
            }
            return
        }
        let entries = model.visibleEntries
        if flags.contains(.shift),
           let anchor = entries.firstIndex(where: { model.selection.contains($0.id) }),
           let target = entries.firstIndex(of: entry) {
            let lo = min(anchor, target)
            let hi = max(anchor, target)
            model.selection = Set(entries[lo...hi].map(\.id))
            return
        }
        model.selection = [entry.id]
    }

    static func previewSelection(_ model: DriveModel) -> KeyPress.Result {
        if model.previewURL != nil {
            model.previewURL = nil
            return .handled
        }
        guard let entry = model.selectedEntries.first, !entry.isDir else { return .ignored }
        Task { await model.preview(entry) }
        return .handled
    }

    static func openSelection(_ model: DriveModel) -> KeyPress.Result {
        let selected = model.selectedEntries
        guard selected.count == 1, let entry = selected.first else { return .ignored }
        Task { await model.open(entry) }
        return .handled
    }
}

// MARK: - Pieces

struct Sidebar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        List {
            Section("Locations") {
                Button {
                    Task { await model.go(to: "") }
                } label: {
                    Label("Drive", systemImage: "externaldrive")
                }
                .buttonStyle(.plain)
            }
            if model.breadcrumbs.count > 1 {
                Section("Current Path") {
                    ForEach(crumbs, id: \.path) { crumb in
                        Button {
                            Task { await model.go(to: crumb.path) }
                        } label: {
                            Label(crumb.name, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { StorageGauge() }
    }

    private var crumbs: [Crumb] {
        model.breadcrumbs.dropFirst().map { Crumb(name: $0.name, path: $0.path) }
    }
}

struct Crumb: Hashable {
    let name: String
    let path: String
}

struct StorageGauge: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if let s = model.storage, s.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(s.used), total: Double(s.total))
                Text("\(Format.size(s.free)) free of \(Format.size(s.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

struct BreadcrumbBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items, id: \.path) { crumb in
                    crumbView(crumb)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .font(.callout)
    }

    private var items: [Crumb] {
        model.breadcrumbs.map { Crumb(name: $0.name, path: $0.path) }
    }

    @ViewBuilder
    private func crumbView(_ crumb: Crumb) -> some View {
        if !crumb.path.isEmpty {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        let isLast = crumb.path == model.path
        Button(crumb.name) { Task { await model.go(to: crumb.path) } }
            .buttonStyle(.plain)
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
    }
}

struct StatusBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(busy).lineLimit(1)
            } else if model.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…")
            } else {
                Text(summary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let count = model.visibleEntries.count
        if model.selection.isEmpty { return "\(count) item\(count == 1 ? "" : "s")" }
        return "\(model.selection.count) of \(count) selected"
    }
}

struct FileTile: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            preview
                .frame(width: 84, height: 72)
                .padding(4)
                .background(isSelected ? Color.secondary.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            label
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(entry.isDir ? entry.name : "\(entry.name) — \(Format.size(entry.size))")
        .task(id: entry) { await model.loadThumbnail(for: entry) }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumb = model.thumbnail(for: entry) {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 1, y: 1)
        } else {
            FileIcon(entry: entry, size: 64)
        }
    }

    private var label: some View {
        Text(entry.name)
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct FileIcon: View {
    let entry: Entry
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: entry.utType))
            .resizable()
            .frame(width: size, height: size)
    }
}
