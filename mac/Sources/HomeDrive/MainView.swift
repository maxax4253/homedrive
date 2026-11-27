import QuickLook
import SwiftUI

/// The signed-in window: Drive-style sidebar on the left, search bar and content panel on the right.
struct MainView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SideNav()
                .frame(width: 256)
            VStack(spacing: 0) {
                TopBar()
                ContentPanel()
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .background(Theme.window)
        .overlay(alignment: .bottomTrailing) { TransfersPanel() }
        .quickLookPreview($model.previewURL)
        .task {
            await model.refresh()
            model.startOfflineSync()
            await model.syncOffline()
        }
        .modifier(Dialogs())
        .modifier(FeatureSheets())
    }
}

// MARK: - Sidebar

struct SideNav: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Logo()
                .padding(.top, 30)
                .padding(.leading, 22)
                .padding(.bottom, 18)
            NewButton()
                .padding(.leading, 14)
                .padding(.bottom, 18)
            VStack(spacing: 2) {
                ForEach(model.sidebarSections, id: \.self) { section in
                    NavRow(section: section)
                }
            }
            .padding(.trailing, 14)
            Spacer()
            StorageBox()
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
    }
}

struct Logo: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.accent)
            Text("HomeDrive")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

struct NewButton: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button {
            model.showNewMenu = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                Text("New")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .frame(height: 56)
            .background(Theme.newButton, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $model.showNewMenu, arrowEdge: .bottom) {
            NewMenu()
        }
    }
}

struct NewMenu: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "folder.badge.plus", title: "New folder", shortcut: "⇧⌘N") { model.startNewFolder() }
            Divider().padding(.vertical, 6)
            MenuRow(icon: "arrow.up.doc", title: "File upload", shortcut: "⌘U") { model.pickFilesToUpload() }
            MenuRow(icon: "folder", title: "Folder upload", shortcut: "⇧⌘U") { model.pickFolderToUpload() }
            Divider().padding(.vertical, 6)
            MenuRow(icon: "tray.and.arrow.up", title: "Move from Mac…", shortcut: "⌥⌘U") { model.pickFilesToOffload() }
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }
}

struct MenuRow: View {
    @Environment(DriveModel.self) private var model
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void

    private var hoverKey: String { "menu:" + title }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(model.hoveredID == hoverKey ? Theme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in Hover.update(model, key: hoverKey, inside: inside) }
    }
}

struct NavRow: View {
    @Environment(DriveModel.self) private var model
    let section: DriveSection

    private var isSelected: Bool { model.section == section && model.activeSearch == nil }
    private var hoverKey: String { "nav:" + section.rawValue }

    var body: some View {
        Button {
            Task { await model.show(section) }
        } label: {
            HStack(spacing: 18) {
                Image(systemName: isSelected ? section.selectedIcon : section.icon)
                    .font(.system(size: 16))
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 22)
            .frame(height: 34)
            .background(background, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in Hover.update(model, key: hoverKey, inside: inside) }
    }

    private var background: Color {
        if isSelected { return Theme.navSelected }
        if model.hoveredID == hoverKey { return Theme.hover }
        return .clear
    }
}

struct StorageBox: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if let s = model.storage, s.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                UsageBar(fraction: Double(s.used) / Double(s.total))
                Text("\(Format.size(s.used)) of \(Format.size(s.total)) used")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                if model.freedBytes > 0 {
                    Label("Freed \(Format.size(model.freedBytes)) on this Mac", systemImage: "leaf")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 0.24))
                        .padding(.top, 4)
                }
            }
        }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            SearchField()
                .frame(maxWidth: 720)
            Spacer(minLength: 12)
            if model.busyMessage != nil || model.isLoading {
                ProgressView().controlSize(.small)
            }
            AccountMenu()
        }
        .padding(.top, 22)
        .padding(.bottom, 10)
        .padding(.leading, 4)
    }
}

struct SearchField: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search in Drive", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit { Task { await model.search() } }
            if !model.searchText.isEmpty || model.activeSearch != nil {
                Button {
                    Task { await model.clearSearch() }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(Theme.search, in: Capsule())
    }
}

struct AccountMenu: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Menu {
            Text("Signed in as \(model.username)\(model.isAdmin ? " (admin)" : "")")
            Text(model.serverURL)
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
            if !model.isAdmin {
                Button("Change password…") { model.showChangePassword = true }
            }
            Button("Sign Out") { model.logout() }
        } label: {
            Text(initial)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .background(Color(red: 0.36, green: 0.46, blue: 0.83), in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Account")
    }

    private var initial: String {
        String(model.username.prefix(1)).uppercased()
    }
}

// MARK: - Content panel

struct ContentPanel: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        ScreenSwitcher()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay { DropHighlight() }
            .overlay(alignment: .bottom) { StatusToast() }
            .dropDestination(for: URL.self) { urls, _ in
                guard model.canUpload else { return false }
                Task { await model.upload(urls) }
                return true
            } isTargeted: { targeted in
                model.isDropTarget = targeted && model.canUpload
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) { Actions.previewSelection(model) }
            .onKeyPress(.return) { Actions.openSelection(model) }
            .onDeleteCommand { Actions.deleteSelection(model) }
            .background(KeyboardShortcuts())
    }
}

/// Hidden buttons that give the window its keyboard shortcuts.
struct KeyboardShortcuts: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        ZStack {
            Button("") { Task { await model.goBack() } }.keyboardShortcut("[", modifiers: .command)
            Button("") { Task { await model.goForward() } }.keyboardShortcut("]", modifiers: .command)
            Button("") { if model.canUpload { model.startNewFolder() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { if model.canUpload { model.pickFilesToUpload() } }.keyboardShortcut("u", modifiers: .command)
            Button("") { if model.canUpload { model.pickFolderToUpload() } }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("") { model.pickFilesToOffload() }.keyboardShortcut("u", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct DropHighlight: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if model.isDropTarget {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                Label("Drop files to upload them to \(targetName)", systemImage: "icloud.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .allowsHitTesting(false)
        }
    }

    private var targetName: String {
        guard model.section == .drive, let last = model.breadcrumbs.last else { return "My Drive" }
        return last.name
    }
}

/// Dark pill at the bottom while something is uploading/downloading.
struct StatusToast: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if let busy = model.busyMessage {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(busy).lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 20)
            .allowsHitTesting(false)
        }
    }
}

enum Hover {
    @MainActor
    static func update(_ model: DriveModel, key: String, inside: Bool) {
        if inside {
            model.hoveredID = key
        } else if model.hoveredID == key {
            model.hoveredID = nil
        }
    }
}
