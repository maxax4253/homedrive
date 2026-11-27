import SwiftUI

// MARK: - List (table) layout

enum Column: Hashable {
    case modified, size, location, deleted, original

    var title: String {
        switch self {
        case .modified: return "Last modified"
        case .size: return "File size"
        case .location: return "Location"
        case .deleted: return "Date deleted"
        case .original: return "Original location"
        }
    }

    var width: CGFloat {
        switch self {
        case .modified, .deleted: return 150
        case .size: return 110
        case .location, .original: return 190
        }
    }
}

struct FileTable: View {
    let entries: [Entry]
    let columns: [Column]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            TableHeader(columns: columns)
            ForEach(entries) { entry in
                FileRow(entry: entry, columns: columns, siblings: entries)
            }
        }
    }
}

struct TableHeader: View {
    let columns: [Column]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { column in
                    Text(column.title)
                        .frame(width: column.width, alignment: .leading)
                }
                Color.clear.frame(width: 40)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

struct FileRow: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry
    let columns: [Column]
    let siblings: [Entry]

    private var isSelected: Bool { model.selection.contains(entry.id) }
    private var isHovered: Bool { model.hoveredID == entry.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NameCell(entry: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { column in
                    Text(value(for: column))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: column.width, alignment: .leading)
                }
                RowMenu(entry: entry)
                    .frame(width: 40)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: isSelected ? 10 : 0))
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.open(entry) } }
        .simultaneousGesture(TapGesture().onEnded { Actions.select(entry, in: siblings, model: model) })
        .onHover { inside in Hover.update(model, key: entry.id, inside: inside) }
        .contextMenu { ItemMenu(items: Actions.contextItems(clicked: entry, model: model)) }
        .task(id: entry.thumbKey) { await model.loadThumbnail(for: entry) }
    }

    private var rowBackground: Color {
        if isSelected { return Theme.rowSelected }
        if isHovered { return Theme.hover }
        return .clear
    }

    private func value(for column: Column) -> String {
        switch column {
        case .modified: return Format.date(entry.modifiedDate)
        case .size: return entry.isDir ? "—" : Format.size(entry.size)
        case .location: return entry.locationName
        case .deleted: return entry.deletedDate.map(Format.date) ?? "—"
        case .original: return entry.originalLocation
        }
    }
}

struct NameCell: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry

    var body: some View {
        HStack(spacing: 14) {
            if let thumb = model.thumbnail(for: entry) {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                FileGlyph(entry: entry, size: 22)
            }
            Text(entry.name)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.trailing, 12)
    }
}

/// The ⋮ button at the end of a row or card.
struct RowMenu: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry

    var body: some View {
        Menu {
            ItemMenu(items: [entry])
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Grid layout

struct FolderGrid: View {
    let folders: [Entry]
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(folders) { folder in
                FolderCard(entry: folder, siblings: folders)
            }
        }
    }
}

struct FolderCard: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry
    let siblings: [Entry]

    private var isSelected: Bool { model.selection.contains(entry.id) }
    private var isHovered: Bool { model.hoveredID == entry.id }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.folder)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.section != .drive {
                    Text("In \(entry.locationName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            RowMenu(entry: entry)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 58)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { Task { await model.open(entry) } }
        .simultaneousGesture(TapGesture().onEnded { Actions.select(entry, in: siblings, model: model) })
        .onHover { inside in Hover.update(model, key: entry.id, inside: inside) }
        .contextMenu { ItemMenu(items: Actions.contextItems(clicked: entry, model: model)) }
    }

    private var background: Color {
        if isSelected { return Theme.rowSelected }
        if isHovered { return Theme.hover }
        return Theme.card
    }
}

struct FileGrid: View {
    let files: [Entry]
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(files) { file in
                FileCard(entry: file, siblings: files)
            }
        }
    }
}

struct FileCard: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry
    let siblings: [Entry]

    private var isSelected: Bool { model.selection.contains(entry.id) }
    private var isHovered: Bool { model.hoveredID == entry.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FileGlyph(entry: entry, size: 18)
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                RowMenu(entry: entry)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(height: 46)

            CardPreview(entry: entry)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(Theme.cardPreview, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { Task { await model.open(entry) } }
        .simultaneousGesture(TapGesture().onEnded { Actions.select(entry, in: siblings, model: model) })
        .onHover { inside in Hover.update(model, key: entry.id, inside: inside) }
        .contextMenu { ItemMenu(items: Actions.contextItems(clicked: entry, model: model)) }
        .task(id: entry.thumbKey) { await model.loadThumbnail(for: entry) }
    }

    private var background: Color {
        if isSelected { return Theme.rowSelected }
        if isHovered { return Theme.hover }
        return Theme.card
    }
}

struct CardPreview: View {
    @Environment(DriveModel.self) private var model
    let entry: Entry

    var body: some View {
        if let thumb = model.thumbnail(for: entry) {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } else {
            FileGlyph(entry: entry, size: 64)
        }
    }
}

// MARK: - Menus

/// Right-click / ⋮ menu. Shows trash actions when in the Trash.
struct ItemMenu: View {
    @Environment(DriveModel.self) private var model
    let items: [Entry]

    var body: some View {
        if model.section == .trash && model.activeSearch == nil {
            Button("Restore") { Task { await model.restore(items) } }
            Button("Delete forever", role: .destructive) { model.deletingForever = items }
        } else {
            normalMenu
        }
    }

    @ViewBuilder
    private var normalMenu: some View {
        if items.count == 1, let entry = items.first {
            Button(entry.isDir ? "Open" : "Preview") { Task { await model.open(entry) } }
            if model.section != .drive || model.activeSearch != nil {
                Button("Show file location") { Task { await model.showLocation(of: entry) } }
            }
            Divider()
        }
        if items.contains(where: { !$0.isDir }) {
            Button("Download") { Task { await model.download(items) } }
        }
        if items.count == 1, let entry = items.first {
            Button("Rename") {
                model.renameText = entry.name
                model.renaming = entry
            }
        }
        if !items.isEmpty {
            Divider()
            Button("Move to trash", role: .destructive) { model.deleting = items }
        }
    }
}

// MARK: - Dialogs

struct Dialogs: ViewModifier {
    @Environment(DriveModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert("New folder", isPresented: $model.showNewFolder) {
                TextField("Name", text: $model.newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: renameBinding) {
                TextField("Name", text: $model.renameText)
                Button("OK") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding) {
                Button("Move to trash", role: .destructive) { trash() }
            } message: {
                Text("You can restore it from the Trash later.")
            }
            .confirmationDialog(foreverTitle, isPresented: foreverBinding) {
                Button("Delete forever", role: .destructive) { deleteForever() }
            } message: {
                Text("This can't be undone.")
            }
            .confirmationDialog("Empty trash?", isPresented: $model.confirmEmptyTrash) {
                Button("Empty trash", role: .destructive) { Task { await model.emptyTrash() } }
            } message: {
                Text("Everything in the trash will be deleted forever. This can't be undone.")
            }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { !model.deleting.isEmpty }, set: { if !$0 { model.deleting = [] } })
    }

    private var foreverBinding: Binding<Bool> {
        Binding(get: { !model.deletingForever.isEmpty }, set: { if !$0 { model.deletingForever = [] } })
    }

    private var deleteTitle: String {
        if model.deleting.count == 1 { return "Move “\(model.deleting[0].name)” to the trash?" }
        return "Move \(model.deleting.count) items to the trash?"
    }

    private var foreverTitle: String {
        if model.deletingForever.count == 1 { return "Delete “\(model.deletingForever[0].name)” forever?" }
        return "Delete \(model.deletingForever.count) items forever?"
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

    private func deleteForever() {
        let items = model.deletingForever
        Task { await model.deleteForever(items) }
    }
}

// MARK: - Selection & keyboard helpers

@MainActor
enum Actions {
    /// Right-clicking a selected item acts on the whole selection, like Drive.
    static func contextItems(clicked entry: Entry, model: DriveModel) -> [Entry] {
        model.selection.contains(entry.id) ? model.selectedEntries : [entry]
    }

    static func select(_ entry: Entry, in list: [Entry], model: DriveModel) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(entry.id) {
                model.selection.remove(entry.id)
            } else {
                model.selection.insert(entry.id)
            }
            return
        }
        if flags.contains(.shift),
           let anchor = list.firstIndex(where: { model.selection.contains($0.id) }),
           let target = list.firstIndex(of: entry) {
            let lo = min(anchor, target)
            let hi = max(anchor, target)
            model.selection = Set(list[lo...hi].map(\.id))
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

    static func deleteSelection(_ model: DriveModel) {
        let selected = model.selectedEntries
        guard !selected.isEmpty else { return }
        if model.section == .trash && model.activeSearch == nil {
            model.deletingForever = selected
        } else {
            model.deleting = selected
        }
    }
}
