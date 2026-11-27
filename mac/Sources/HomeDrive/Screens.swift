import SwiftUI

enum ViewMode: String {
    case list, grid
}

struct ScreenSwitcher: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if model.activeSearch != nil {
            SearchScreen()
        } else {
            switch model.section {
            case .drive: DriveScreen()
            case .recent: RecentScreen()
            case .starred: StarredScreen()
            case .links: LinksScreen()
            case .offline: OfflineScreen()
            case .admin: AdminScreen()
            case .settings: SettingsScreen()
            case .trash: TrashScreen()
            }
        }
    }
}

// MARK: - Screens

struct DriveScreen: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                BreadcrumbTitle()
                Spacer()
                if viewMode == .grid { SortMenu() }
                ViewToggle(mode: $viewMode)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty && !model.isLoading {
            EmptyState(icon: "folder", title: "This folder is empty", message: "Click New or drag files and folders here to upload.")
        } else if viewMode == .list {
            FileTable(entries: model.displayEntries, columns: [.modified, .size])
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !model.folders.isEmpty {
                    SubHeader(title: "Folders")
                    FolderGrid(folders: model.folders)
                        .padding(.bottom, 24)
                }
                if !model.files.isEmpty {
                    SubHeader(title: "Files")
                    FileGrid(files: model.files)
                }
            }
        }
    }
}

struct RecentScreen: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list

    var body: some View {
        ListScreen(title: "Recent", toggle: $viewMode) {
            if model.entries.isEmpty && !model.isLoading {
                EmptyState(icon: "clock", title: "No recent files", message: "Files you upload or change show up here.")
            } else if viewMode == .list {
                FileTable(entries: model.displayEntries, columns: [.modified, .location])
            } else {
                FileGrid(files: model.displayEntries)
            }
        }
    }
}

struct StarredScreen: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list

    var body: some View {
        ListScreen(title: "Starred", toggle: $viewMode) {
            if model.entries.isEmpty && !model.isLoading {
                EmptyState(icon: "star", title: "No starred files", message: "Right-click a file or folder and choose Add to Starred.")
            } else if viewMode == .list {
                FileTable(entries: model.displayEntries, columns: [.modified, .location])
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.folders.isEmpty {
                        SubHeader(title: "Folders")
                        FolderGrid(folders: model.folders).padding(.bottom, 24)
                    }
                    if !model.files.isEmpty {
                        SubHeader(title: "Files")
                        FileGrid(files: model.files)
                    }
                }
            }
        }
    }
}

struct SearchScreen: View {
    @Environment(DriveModel.self) private var model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list

    var body: some View {
        ListScreen(title: "Results for “\(model.activeSearch ?? "")”", toggle: $viewMode) {
            if model.entries.isEmpty && !model.isLoading {
                EmptyState(icon: "magnifyingglass", title: "No matches", message: "Try a different name.")
            } else if viewMode == .list {
                FileTable(entries: model.displayEntries, columns: [.modified, .location])
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.folders.isEmpty {
                        SubHeader(title: "Folders")
                        FolderGrid(folders: model.folders).padding(.bottom, 24)
                    }
                    if !model.files.isEmpty {
                        SubHeader(title: "Files")
                        FileGrid(files: model.files)
                    }
                }
            }
        }
    }
}

struct TrashScreen: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trash")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !model.entries.isEmpty {
                    PillButton(title: "Empty trash") { model.confirmEmptyTrash = true }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 12)

            Text("Items stay in the trash until you empty it or delete them forever.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 28)
                .padding(.bottom, 10)

            ScrollView {
                Group {
                    if model.entries.isEmpty && !model.isLoading {
                        EmptyState(icon: "trash", title: "Trash is empty", message: "Things you delete show up here.")
                    } else {
                        FileTable(entries: model.displayEntries, columns: [.deleted, .original])
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

/// Title + view toggle + scrolling content, for Recent and Search.
struct ListScreen<Content: View>: View {
    let title: String
    @Binding var toggle: ViewMode
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if toggle == .grid { SortMenu() }
                ViewToggle(mode: $toggle)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                content()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - Headers & controls

struct SubHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.bottom, 12)
    }
}

struct BreadcrumbTitle: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.breadcrumbs, id: \.path) { crumb in
                CrumbButton(crumb: crumb, isLast: crumb.path == model.path)
            }
        }
    }
}

struct CrumbButton: View {
    @Environment(DriveModel.self) private var model
    let crumb: Crumb
    let isLast: Bool

    var body: some View {
        HStack(spacing: 2) {
            if !crumb.path.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                Task { await model.go(to: crumb.path) }
            } label: {
                Text(crumb.name)
                    .font(.system(size: 22))
                    .foregroundStyle(isLast ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(crumbBackground, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in Hover.update(model, key: hoverKey, inside: inside) }
            .folderDropTarget(crumb.path)
        }
    }

    private var hoverKey: String { "crumb:" + crumb.path }

    private var crumbBackground: Color {
        if model.dropFolderTarget == crumb.path { return Theme.rowSelected }
        return model.hoveredID == hoverKey ? Theme.hover : Color.clear
    }
}

/// Drive's two-segment list/grid pill with a checkmark on the active side.
struct ViewToggle: View {
    @Binding var mode: ViewMode

    var body: some View {
        HStack(spacing: 0) {
            segment(.list, icon: "list.bullet")
            Rectangle().fill(Theme.textSecondary.opacity(0.6)).frame(width: 1)
            segment(.grid, icon: "square.grid.2x2")
        }
        .frame(height: 32)
        .overlay(Capsule().strokeBorder(Theme.textSecondary.opacity(0.6), lineWidth: 1))
        .clipShape(Capsule())
    }

    private func segment(_ value: ViewMode, icon: String) -> some View {
        Button {
            mode = value
        } label: {
            HStack(spacing: 6) {
                if mode == value {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                }
                Image(systemName: icon).font(.system(size: 14))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 58, height: 32)
            .background(mode == value ? Theme.toggleSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(value == .list ? "List layout" : "Grid layout")
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .overlay(Capsule().strokeBorder(Theme.textSecondary.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
            Text(title)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
