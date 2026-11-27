import AppKit
import Foundation

enum ShareExpiry: String, CaseIterable, Identifiable {
    case day, week, month, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "1 day"
        case .week: return "7 days"
        case .month: return "30 days"
        case .never: return "Never"
        }
    }

    var days: Double? {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .never: return nil
        }
    }
}

extension DriveModel {
    // MARK: - Share links

    func startShare(_ entry: Entry) {
        shareTarget = entry
        Task { await loadLinksStatus() }
        shareExpiry = .week
        sharePasswordOn = false
        sharePassword = ""
        createdLink = nil
    }

    func createLink() async {
        guard let api, let entry = shareTarget else { return }
        if sharePasswordOn && sharePassword.isEmpty {
            errorMessage = "Type a password, or turn the password off."
            return
        }
        isCreatingLink = true
        defer { isCreatingLink = false }
        do {
            let link = try await api.createShare(entry.path, expiresDays: shareExpiry.days,
                                                 password: sharePasswordOn ? sharePassword : nil)
            createdLink = link
            if let url = link.url {
                copyToClipboard(url)
                toast("Link copied")
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Admin switch: ask the server helper to turn public share links on or off,
    /// then watch until it's done (the server restarts briefly while it switches).
    func setLinksEnabled(_ on: Bool) async {
        guard let api, isAdmin else { return }
        linksSwitchBusy = true
        defer { linksSwitchBusy = false }
        do {
            linksStatus = try await api.setLinks(on)
        } catch {
            errorMessage = friendly(error)
            return
        }
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            guard let status = try? await api.linksStatus() else { continue }   // restarting
            linksStatus = status
            if !status.isWorking && status.enabled == on { break }
            if status.state == "needs_approval" || status.state == "error" { break }
        }
        linksEnabled = linksStatus?.enabled ?? linksEnabled
        if let status = linksStatus, status.state == "error", let message = status.message {
            errorMessage = message
        }
        await refresh()
    }

    func openApproval() {
        guard let s = linksStatus?.approveURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    func loadLinksStatus() async {
        guard let api, isAdmin else { return }
        linksStatus = try? await api.linksStatus()
    }

    func revoke(_ link: ShareLink) async {
        guard let api else { return }
        do {
            try await api.revokeShare(link.token)
        } catch {
            errorMessage = friendly(error)
        }
        await refresh()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Version history

    func showVersions(_ entry: Entry) async {
        guard let api else { return }
        versionsTarget = entry
        versionList = []
        versionsLoading = true
        defer { versionsLoading = false }
        do {
            versionList = try await api.versions(entry.path).versions
        } catch {
            errorMessage = friendly(error)
        }
    }

    func restore(_ version: FileVersion) async {
        guard let api, let entry = versionsTarget else { return }
        do {
            try await api.restoreVersion(entry.path, version: version.id)
            versionsTarget = nil
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Saves an older copy next to your Downloads, named with its date.
    func downloadVersion(_ version: FileVersion) async {
        guard let api, let entry = versionsTarget else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (entry.name as NSString).deletingPathExtension
        let ext = (entry.name as NSString).pathExtension
        let stamp = version.modifiedDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        let name = ext.isEmpty ? "\(base) (\(stamp))" : "\(base) (\(stamp)).\(ext)"
        let dest = uniqueURL(downloads.appendingPathComponent(name))
        let id = addTransfer(Transfer(name: name, kind: .download, isFolder: false, bytesTotal: version.size))
        transfersCollapsed = false
        await runTransfer(id) { _ in
            try await api.downloadVersion(entry.path, version: version.id, to: dest)
            return dest
        }
    }

    // MARK: - Accounts

    func addUser() async {
        guard let api else { return }
        let name = newUsername.trimmingCharacters(in: .whitespaces).lowercased()
        let quota = Double(newUserQuota.trimmingCharacters(in: .whitespaces))
        guard !name.isEmpty, !newUserPassword.isEmpty else {
            errorMessage = "Enter a username and a password."
            return
        }
        do {
            try await api.addUser(name, password: newUserPassword, quotaGB: quota)
            showAddUser = false
            newUsername = ""
            newUserPassword = ""
            newUserQuota = ""
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func resetPassword() async {
        guard let api, let user = resettingUser else { return }
        let pw = resetPasswordText
        resettingUser = nil
        resetPasswordText = ""
        guard !pw.isEmpty else { return }
        do {
            try await api.resetPassword(user.username, password: pw)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func saveQuota() async {
        guard let api, let user = quotaUser else { return }
        let text = quotaText.trimmingCharacters(in: .whitespaces)
        quotaUser = nil
        let quota = Double(text)
        if !text.isEmpty && quota == nil {
            errorMessage = "Enter a number of GB, or leave it empty for no limit."
            return
        }
        do {
            try await api.setQuota(user.username, quotaGB: (quota ?? 0) > 0 ? quota : nil)
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func deleteUser(_ user: UserInfo) async {
        guard let api else { return }
        do {
            try await api.deleteUser(user.username)
            await refresh()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func changeMyPassword() async {
        guard let api else { return }
        do {
            let token = try await api.changeMyPassword(old: oldPassword, new: newPassword)
            replaceToken(token)
            showChangePassword = false
            oldPassword = ""
            newPassword = ""
        } catch {
            errorMessage = friendly(error)
        }
    }

    // MARK: - Backups

    func backUpNow() async {
        guard let api else { return }
        do {
            try await api.runBackup()
        } catch {
            errorMessage = friendly(error)
        }
        await refresh()
        // Check back a few times while it runs.
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(5))
            guard section == .admin, let status = try? await api.backupStatus() else { break }
            backupStatus = status
            if !status.running { break }
        }
    }

    // MARK: - Edit and save back

    /// Opens a file in its usual app; every time you save, the new version uploads.
    func openInApp(_ entry: Entry) async {
        guard let api, !entry.isDir else { return }
        // Kept offline? Open the copy in ~/HomeDrive Offline; offline sync uploads your saves.
        if offline.isPinned(entry.path), let local = offline.availableCopy(of: entry.path) {
            NSWorkspace.shared.open(local)
            return
        }
        if let existing = editing.session(for: entry.path), FileManager.default.fileExists(atPath: existing.local.path) {
            NSWorkspace.shared.open(existing.local)
            return
        }
        let dir = editing.editRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let local = dir.appendingPathComponent(entry.name)
        busyMessage = "Opening \(entry.name)…"
        defer { busyMessage = nil }
        do {
            try await api.download(entry.path, to: local)
            try? FileManager.default.setAttributes([.modificationDate: entry.modifiedDate], ofItemAtPath: local.path)
        } catch {
            errorMessage = friendly(error)
            return
        }
        let session = EditSessions.Session(path: entry.path, name: entry.name, local: local,
                                           baseModified: entry.modified, lastLocalChange: entry.modifiedDate)
        editing.add(session) { [weak self] changed in
            Task { await self?.saveBack(changed) }
        }
        NSWorkspace.shared.open(local)
    }

    /// Upload the edited file. If the server copy changed meanwhile, keep both.
    func saveBack(_ session: EditSessions.Session) async {
        guard let api else { return }
        // Apps often save twice in a row. Uploading both at once would make the second
        // look like a conflict, so queue it until the first finishes.
        if session.uploading {
            session.savedAgain = true
            return
        }
        session.uploading = true
        defer {
            session.uploading = false
            if session.savedAgain {
                session.savedAgain = false
                Task { await self.saveBack(session) }
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: session.local.path)
        guard let changed = attrs?[.modificationDate] as? Date, changed > session.lastLocalChange.addingTimeInterval(0.5) else { return }
        session.lastLocalChange = changed

        let folder = (session.path as NSString).deletingLastPathComponent
        let id = addTransfer(Transfer(name: session.name, kind: .upload, isFolder: false,
                                      bytesTotal: (attrs?[.size] as? NSNumber)?.int64Value ?? -1))
        transfersCollapsed = false
        updateTransfer(id) { $0.state = .active }
        do {
            let saved = try await api.upload(file: session.local, to: folder, replace: true, ifModified: session.baseModified)
            session.baseModified = saved.modified
            updateTransfer(id) { t in t.state = .done; t.note = "Saved to HomeDrive" }
            scheduleAutoClose()
        } catch let error as APIError where error.status == 409 || error.status == 404 {
            // Changed or deleted on the server since you opened it: save yours as a separate copy.
            do {
                let copy = try conflictCopy(of: session.local)
                let saved = try await api.upload(file: copy, to: folder)
                try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
                editing.move(session, to: saved.path)
                session.baseModified = saved.modified
                let note = error.status == 409 ? "Changed on the server too, so yours was saved as a copy"
                                               : "Deleted on the server, so it was saved again"
                updateTransfer(id) { t in t.state = .done; t.note = note }
            } catch {
                let message = friendly(error)
                updateTransfer(id) { $0.state = .failed(message) }
            }
        } catch {
            let message = friendly(error)
            updateTransfer(id) { $0.state = .failed(message) }
            signOutIfExpired(error)
        }
        await refresh()
    }

    func conflictCopy(of file: URL) throws -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
            .replacingOccurrences(of: ":", with: ".")
        let name = ext.isEmpty ? "\(base) (conflict \(stamp))" : "\(base) (conflict \(stamp)).\(ext)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}
