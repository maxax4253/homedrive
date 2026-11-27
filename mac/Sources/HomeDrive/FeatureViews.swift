import SwiftUI

// MARK: - Sheets & dialogs for the newer features

struct FeatureSheets: ViewModifier {
    @Environment(DriveModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: shareBinding) { ShareSheet() }
            .sheet(isPresented: versionsBinding) { VersionsSheet() }
            .sheet(isPresented: $model.showAddUser) { AddUserSheet() }
            .sheet(isPresented: $model.showChangePassword) { ChangePasswordSheet() }
            .alert("Reset password", isPresented: resetBinding) {
                SecureField("New password", text: $model.resetPasswordText)
                Button("Reset") { Task { await model.resetPassword() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll be signed out and need the new password to sign in.")
            }
            .alert("Storage limit", isPresented: quotaBinding) {
                TextField("GB (empty = no limit)", text: $model.quotaText)
                Button("Save") { Task { await model.saveQuota() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("How much space \(model.quotaUser?.username ?? "they") can use, in GB.")
            }
            .confirmationDialog(deleteUserTitle, isPresented: deleteUserBinding) {
                Button("Delete account", role: .destructive) {
                    if let user = model.deletingUser { Task { await model.deleteUser(user) } }
                }
            } message: {
                Text("They won't be able to sign in. Their files stay in Users/\(model.deletingUser?.username ?? "") for you to keep or delete.")
            }
            .confirmationDialog("Turn off this link?", isPresented: revokeBinding) {
                Button("Turn off link", role: .destructive) {
                    if let link = model.revokingLink { Task { await model.revoke(link) } }
                }
            } message: {
                Text("Anyone who has it won't be able to open it anymore.")
            }
            .confirmationDialog("Restore this version?", isPresented: restoreBinding) {
                Button("Restore") {
                    if let v = model.restoringVersion { Task { await model.restore(v) } }
                }
            } message: {
                Text("The current file is kept in version history, so you can switch back.")
            }
    }

    private var shareBinding: Binding<Bool> {
        Binding(get: { model.shareTarget != nil }, set: { if !$0 { model.shareTarget = nil } })
    }
    private var versionsBinding: Binding<Bool> {
        Binding(get: { model.versionsTarget != nil }, set: { if !$0 { model.versionsTarget = nil } })
    }
    private var resetBinding: Binding<Bool> {
        Binding(get: { model.resettingUser != nil }, set: { if !$0 { model.resettingUser = nil } })
    }
    private var quotaBinding: Binding<Bool> {
        Binding(get: { model.quotaUser != nil }, set: { if !$0 { model.quotaUser = nil } })
    }
    private var deleteUserBinding: Binding<Bool> {
        Binding(get: { model.deletingUser != nil }, set: { if !$0 { model.deletingUser = nil } })
    }
    private var revokeBinding: Binding<Bool> {
        Binding(get: { model.revokingLink != nil }, set: { if !$0 { model.revokingLink = nil } })
    }
    private var restoreBinding: Binding<Bool> {
        Binding(get: { model.restoringVersion != nil }, set: { if !$0 { model.restoringVersion = nil } })
    }
    private var deleteUserTitle: String {
        "Delete \(model.deletingUser?.username ?? "this") account?"
    }
}

struct SheetHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Share

struct ShareSheet: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Share “\(model.shareTarget?.name ?? "")”",
                        subtitle: "Anyone with the link can download it. No account needed.")

            if !model.linksEnabled {
                if model.isAdmin {
                    LinksSwitch(compact: true)
                } else {
                    InfoBanner(icon: "exclamationmark.triangle",
                               text: "Share links are turned off. Ask whoever runs this HomeDrive to turn them on in Admin.")
                }
            }

            if let link = model.createdLink {
                CreatedLinkView(link: link)
            } else {
                Form {
                    Picker("Link expires", selection: $model.shareExpiry) {
                        ForEach(ShareExpiry.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Require a password", isOn: $model.sharePasswordOn)
                    if model.sharePasswordOn {
                        SecureField("Password", text: $model.sharePassword)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if model.createdLink == nil {
                    Button("Cancel") { model.shareTarget = nil }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Task { await model.createLink() }
                    } label: {
                        if model.isCreatingLink { ProgressView().controlSize(.small) } else { Text("Create link") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isCreatingLink)
                } else {
                    Button("Done") { model.shareTarget = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct CreatedLinkView: View {
    @Environment(DriveModel.self) private var model
    let link: ShareLink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = link.url {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(Theme.accent)
                    Text(url)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy") { model.copyToClipboard(url) }
                }
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                Label("Link copied to the clipboard", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 0.24))
            } else {
                Text("The link was saved, but it won't work until share links are turned on (Admin → Share links). You'll find it under Shared links.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: Version history

struct VersionsSheet: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Version history",
                        subtitle: model.versionsTarget?.name)
            Group {
                if model.versionsLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if model.versionList.isEmpty {
                    Text("No older versions yet. Older copies appear here after you edit a file with Open in app, or once nightly backups have run.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.versionList) { version in
                                VersionRow(version: version)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
            HStack {
                Spacer()
                Button("Done") { model.versionsTarget = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct VersionRow: View {
    @Environment(DriveModel.self) private var model
    let version: FileVersion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: version.isBackup ? "externaldrive.badge.timemachine" : "pencil.circle")
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(version.modifiedDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(version.isBackup ? "From nightly backup" : "Before an edit") · \(Format.size(version.size))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Download") { Task { await model.downloadVersion(version) } }
            Button("Restore") { model.restoringVersion = version }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

// MARK: Accounts

struct AddUserSheet: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Add a person",
                        subtitle: "They get their own private folder, plus the Shared folder everyone can use.")
            Form {
                TextField("Username", text: $model.newUsername, prompt: Text("e.g. mom"))
                SecureField("Password", text: $model.newUserPassword)
                TextField("Storage limit (GB)", text: $model.newUserQuota, prompt: Text("Leave empty for no limit"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showAddUser = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await model.addUser() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newUsername.isEmpty || model.newUserPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ChangePasswordSheet: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Change password", subtitle: nil)
            Form {
                SecureField("Current password", text: $model.oldPassword)
                SecureField("New password", text: $model.newPassword)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showChangePassword = false }
                    .keyboardShortcut(.cancelAction)
                Button("Change") { Task { await model.changeMyPassword() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.oldPassword.isEmpty || model.newPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Screens

struct ScreenTitle: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

struct InfoBanner: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LinksScreen: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Shared links")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.linksEnabled {
                        if model.isAdmin {
                            LinksSwitch(compact: false)
                        } else {
                            InfoBanner(icon: "exclamationmark.triangle",
                                       text: "Share links are turned off, so people can't open these yet. Ask whoever runs this HomeDrive to turn them on.")
                        }
                    }
                    if model.shareLinks.isEmpty && !model.isLoading {
                        EmptyState(icon: "link", title: "No shared links",
                                   message: "Right-click a file or folder and choose Get link.")
                    } else {
                        LinksTable(links: model.shareLinks)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

struct LinksTable: View {
    let links: [ShareLink]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Expires").frame(width: 120, alignment: .leading)
                Text("Downloads").frame(width: 90, alignment: .leading)
                Color.clear.frame(width: 170)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ForEach(links) { link in
                LinkRow(link: link)
            }
        }
    }
}

struct LinkRow: View {
    @Environment(DriveModel.self) private var model
    let link: ShareLink

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: link.isDir ? "folder.fill" : "doc.fill")
                        .foregroundStyle(Theme.folder)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if link.hasPassword {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .help("Needs a password")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(expiry)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 120, alignment: .leading)
                Text("\(link.downloads)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 8) {
                    if let url = link.url {
                        Button("Copy link") { model.copyToClipboard(url) }
                    }
                    Button("Turn off") { model.revokingLink = link }
                }
                .frame(width: 170, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var subtitle: String {
        if !link.active { return "Not working: the file was moved out of reach or deleted" }
        return "Created \(Format.date(link.createdDate))"
    }

    private var expiry: String {
        guard let date = link.expiresDate else { return "Never" }
        return date < Date() ? "Expired" : Format.date(date)
    }
}

struct OfflineScreen: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Offline", trailing: AnyView(actions))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InfoBanner(icon: "arrow.triangle.2.circlepath",
                               text: "These live in your “HomeDrive Offline” folder (\(Format.size(model.offline.totalBytes))). Open and edit them in any app, even without a connection. Your changes upload automatically, and changes from HomeDrive download every couple of minutes. If a file changes in both places, both copies are kept.")
                    if model.offline.items.isEmpty {
                        EmptyState(icon: "arrow.down.circle", title: "Nothing offline yet",
                                   message: "Right-click a file or folder and choose Make available offline.")
                    } else {
                        ForEach(model.offline.items) { item in
                            OfflineRow(item: item)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.offline.isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            PillButton(title: "Open folder") { model.offline.revealFolder() }
            PillButton(title: "Sync now") { Task { await model.syncOffline() } }
        }
    }
}

struct OfflineRow: View {
    @Environment(DriveModel.self) private var model
    let item: OfflineStore.Item

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.folder)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(item.error == nil ? Theme.textSecondary : Color(red: 0.85, green: 0.19, blue: 0.15))
                }
                Spacer()
                Button("Open") { model.offline.open(item) }
                    .disabled(model.offline.availableCopy(of: item.path) == nil)
                Button("Stop keeping offline") { model.offline.unpin(item.path) }
                    .help("Removes the copy from this Mac. The files stay on HomeDrive.")
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.offline.open(item) }
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var detail: String {
        if let error = item.error { return error }
        var parts = [Format.size(item.bytes)]
        if item.isDir { parts.append("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")") }
        if let synced = item.lastSync {
            parts.append("synced \(Format.date(Date(timeIntervalSince1970: synced)))")
        } else {
            parts.append("downloading…")
        }
        return parts.joined(separator: " · ")
    }
}

struct AdminScreen: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Admin")
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PeopleSection()
                    VStack(alignment: .leading, spacing: 10) {
                        SubHeader(title: "Share links")
                        LinksSwitch(compact: false)
                    }
                    BackupSection()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }
}

struct PeopleSection: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SubHeader(title: "People")
                Spacer()
                PillButton(title: "Add person") { model.showAddUser = true }
            }
            ForEach(model.users) { user in
                UserRow(user: user)
            }
        }
    }
}

struct UserRow: View {
    @Environment(DriveModel.self) private var model
    let user: UserInfo

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(String(user.username.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Color(red: 0.36, green: 0.46, blue: 0.83), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.username + (user.isAdmin ? "  (admin)" : ""))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if !user.isAdmin {
                    Menu {
                        Button("Reset password…") { model.resettingUser = user }
                        Button("Storage limit…") {
                            model.quotaText = user.quota.map { String(format: "%g", Double($0) / 1_073_741_824) } ?? ""
                            model.quotaUser = user
                        }
                        Divider()
                        Button("Delete account…", role: .destructive) { model.deletingUser = user }
                    } label: {
                        Text("⋮")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.vertical, 10)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var detail: String {
        if user.isAdmin { return "Sees the whole drive" }
        let used = Format.size(user.used ?? 0)
        if let quota = user.quota { return "\(used) of \(Format.size(quota)) · Users/\(user.username)" }
        return "\(used) used · no limit · Users/\(user.username)"
    }
}

struct BackupSection: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SubHeader(title: "Nightly backups")
                Spacer()
                if model.backupStatus?.enabled == true {
                    if model.backupStatus?.running == true {
                        ProgressView().controlSize(.small)
                        Text("Backing up…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    } else {
                        PillButton(title: "Back up now") { Task { await model.backUpNow() } }
                    }
                }
            }
            if let status = model.backupStatus, status.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    statusLine(status)
                    Text("Runs every night at \(hourText(status.hour)). Keeps every day for a week, one per week for a month, and one per month for 6 months.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    if let free = status.free, let total = status.total {
                        Text("\(status.snapshots.count) snapshot\(status.snapshots.count == 1 ? "" : "s") · \(Format.size(free)) free of \(Format.size(total)) on the backup drive")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            } else {
                InfoBanner(icon: "externaldrive.badge.xmark",
                           text: "Backups are off. To turn them on, run “homedrive backup /path/to/backup/folder” on the server. Ideally the folder is on a second drive.")
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: BackupStatus) -> some View {
        if let error = status.lastError {
            Label("Last backup failed: \(error)", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Color(red: 0.85, green: 0.19, blue: 0.15))
                .font(.system(size: 14))
        } else if let success = status.lastSuccess {
            Label("Last backup: \(Format.date(Date(timeIntervalSince1970: success)))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 0.24))
                .font(.system(size: 14))
        } else {
            Label("No backups yet: the first one runs tonight, or press Back up now.", systemImage: "clock")
                .foregroundStyle(Theme.textSecondary)
                .font(.system(size: 14))
        }
    }

    private func hourText(_ hour: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Grid sort menu

struct SortMenu: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        Menu {
            option("Name", .name)
            option("Last modified", .modified)
            option("File size", .size)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: model.sortOrder.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }

    private var label: String {
        switch model.sortOrder.key {
        case .name: return "Name"
        case .modified: return "Last modified"
        case .size: return "File size"
        case .deleted: return "Date deleted"
        }
    }

    private func option(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.sort(by: key)
        } label: {
            if model.sortOrder.key == key {
                Label(title + (model.sortOrder.ascending ? " (A→Z, oldest, smallest first)" : " (reversed)"),
                      systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - Share links switch (admin)

/// On/off switch for public share links, with the one-time Tailscale approval step.
struct LinksSwitch: View {
    @Environment(DriveModel.self) private var model
    let compact: Bool

    private var status: LinksStatus? { model.linksStatus }
    private var isOn: Bool { status?.enabled ?? model.linksEnabled }
    private var busy: Bool { model.linksSwitchBusy || (status?.isWorking ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "link.circle.fill" : "link.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "Share links are on" : "Share links are off")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: toggleBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(busy || status?.agentInstalled == false)
            }
            if let status, status.state == "needs_approval", status.approveURL != nil, !isOn {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color.orange)
                    Text("One-time step: Tailscale needs your OK to make share pages public. Approve it, then flip the switch on again.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Approve in Tailscale") { model.openApproval() }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if status?.agentInstalled == false {
                Text("To use this switch, run “sudo homedrive install-agent” on the server once (or “homedrive update”).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .task { await model.loadLinksStatus() }
    }

    private var subtitle: String {
        if busy { return isOn ? "Turning off…" : "Turning on… (HomeDrive restarts for a few seconds)" }
        if isOn, let url = status?.publicURL { return "Links open at \(url). Only share pages are public; your drive stays private." }
        return "Lets people without an account download what you share. Only the share pages become public."
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { isOn }, set: { on in Task { await model.setLinksEnabled(on) } })
    }
}
