import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String {
    case grid, list
}

struct BrowserView: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid

    @State private var showImporter = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: Entry?
    @State private var renameText = ""
    @State private var deleting: [Entry] = []
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                BreadcrumbBar()
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if isDropTarget {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(6)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        Task { await model.upload(urls) }
                        return true
                    } isTargeted: { isDropTarget = $0 }
                Divider()
                StatusBar()
            }
            .navigationTitle(model.folderName)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
            .toolbar { toolbar }
        }
        .quickLookPreview($model.previewURL)
        .task { await model.refresh() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let started = urls.map { $0.startAccessingSecurityScopedResource() }
                await model.upload(urls)
                for (url, ok) in zip(urls, started) where ok { url.stopAccessingSecurityScopedResource() }
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                Task { await model.newFolder(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let entry = renaming {
                    let name = renameText
                    Task { await model.rename(entry, to: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleting.count == 1 ? "Move “\(deleting[0].name)” to the trash?" : "Move \(deleting.count) items to the trash?",
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
        ) {
            Button("Move to Trash", role: .destructive) {
                let items = deleting
                Task { await model.moveToTrash(items) }
            }
        } message: {
            Text("They go to the .trash folder on the server.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView {
                Label("This folder is empty", systemImage: "folder")
            } description: {
                Text("Drag files here or click Upload.")
            }
        } else if viewMode == .grid {
            gridView
        } else {
            listView
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 12)], spacing: 14) {
                ForEach(model.visibleEntries) { entry in
                    FileTile(entry: entry, isSelected: model.selection.contains(entry.id))
                        .onTapGesture(count: 2) { Task { await model.open(entry) } }
                        .simultaneousGesture(TapGesture().onEnded { select(entry) })
                        .contextMenu { menu(for: contextItems(clicked: entry)) }
                }
            }
            .padding(16)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.selection = [] }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { previewSelection() }
        .onKeyPress(.return) { openSelection() }
        .onDeleteCommand { deleting = model.selectedEntries }
    }

    private var listView: some View {
        @Bindable var model = model
        return Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 8) {
                    FileIcon(entry: entry, size: 18)
                    Text(entry.name).lineLimit(1)
                }
            }
            TableColumn("Size") { entry in
                Text(entry.isDir ? "—" : Format.size(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modified") { entry in
                Text(entry.modifiedDate, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 220)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            menu(for: model.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
                Task { await model.open(entry) }
            }
        }
        .onKeyPress(.space) { previewSelection() }
        .onDeleteCommand { deleting = model.selectedEntries }
    }

    // MARK: - Toolbar & menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                newFolderName = "untitled folder"
                showNewFolder = true
            } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder")

            Button { showImporter = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Upload files")

            Button { Task { await model.download(model.selectedEntries) } } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selectedEntries.allSatisfy(\.isDir))
            .help("Download selected files to your Downloads folder")
        }
    }

    @ViewBuilder
    private func menu(for items: [Entry]) -> some View {
        if items.count == 1, let entry = items.first {
            Button(entry.isDir ? "Open" : "Quick Look") { Task { await model.open(entry) } }
            Divider()
        }
        if items.contains(where: { !$0.isDir }) {
            Button("Download") { Task { await model.download(items) } }
        }
        if items.count == 1, let entry = items.first {
            Button("Rename…") {
                renameText = entry.name
                renaming = entry
            }
        }
        if !items.isEmpty {
            Divider()
            Button("Move to Trash", role: .destructive) { deleting = items }
        }
    }

    /// Right-clicking a selected item acts on the whole selection, like Finder.
    private func contextItems(clicked entry: Entry) -> [Entry] {
        model.selection.contains(entry.id) ? model.selectedEntries : [entry]
    }

    private func select(_ entry: Entry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(entry.id) {
                model.selection.remove(entry.id)
            } else {
                model.selection.insert(entry.id)
            }
        } else if flags.contains(.shift),
                  let anchor = model.visibleEntries.firstIndex(where: { model.selection.contains($0.id) }),
                  let target = model.visibleEntries.firstIndex(of: entry) {
            let range = min(anchor, target)...max(anchor, target)
            model.selection = Set(model.visibleEntries[range].map(\.id))
        } else {
            model.selection = [entry.id]
        }
    }

    private func previewSelection() -> KeyPress.Result {
        guard model.previewURL == nil else {
            model.previewURL = nil
            return .handled
        }
        guard let entry = model.selectedEntries.first, !entry.isDir else { return .ignored }
        Task { await model.preview(entry) }
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard model.selectedEntries.count == 1, let entry = model.selectedEntries.first else { return .ignored }
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
                    ForEach(Array(model.breadcrumbs.dropFirst().enumerated()), id: \.offset) { _, crumb in
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
        .safeAreaInset(edge: .bottom) {
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
}

struct BreadcrumbBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.name) { Task { await model.go(to: crumb.path) } }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.breadcrumbs.count - 1 ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .font(.callout)
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
                let count = model.visibleEntries.count
                Text(model.selection.isEmpty
                     ? "\(count) item\(count == 1 ? "" : "s")"
                     : "\(model.selection.count) of \(count) selected")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct FileTile: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry
    let isSelected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(radius: 1, y: 1)
                } else {
                    FileIcon(entry: entry, size: 64)
                }
            }
            .frame(width: 84, height: 72)
            .padding(4)
            .background(isSelected ? Color.secondary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))

            Text(entry.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(entry.isDir ? entry.name : "\(entry.name) — \(Format.size(entry.size))")
        .task(id: entry) {
            thumb = await model.thumbnail(for: entry)
        }
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
