import Foundation

/// The decision table for offline sync, kept free of networking and files so it
/// can be unit tested. DriveModel+Offline.swift carries out what it decides.
///
/// For each file we compare the server copy now, the local copy now, and the
/// baseline (both sides right after the last sync):
///
///   only the server changed   -> download it
///   only your Mac changed     -> upload it (old server copy goes to version history)
///   both changed              -> keep both
///   new file on your Mac      -> upload it
///   deleted on your Mac       -> move it to HomeDrive's Trash
///   deleted on the server     -> remove the local copy (unless you edited it: then re-upload)
enum SyncRules {
    struct FileState: Equatable {
        var modified: Double
        var size: Int64
    }

    enum Action: Equatable {
        case nothing
        /// The local file changed in the last couple of seconds: an app may still be saving it.
        case waitStillWriting
        case download
        case uploadEdit
        case uploadNew(note: String)
        case keepBoth(reason: String)
        /// Both exist but were never synced: same file if the contents match, else keep both.
        case compareContents
        case deleteOnServer
        case removeLocal
        case forgetBaseline
    }

    static let bothChanged = "Changed in both places, so both copies were kept"
    static let differentCopies = "Different copies on your Mac and HomeDrive, so both were kept"
    static let reuploaded = "Deleted on HomeDrive but you edited it, so it was uploaded again"
    static let addedLocally = "Added from your HomeDrive Offline folder"

    /// Modified times within a second count as the same (file systems round differently).
    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1 }

    static func serverChanged(_ r: FileState, _ b: OfflineStore.Baseline) -> Bool {
        !same(r.modified, b.serverModified) || r.size != b.serverSize
    }

    static func localChanged(_ l: FileState, _ b: OfflineStore.Baseline) -> Bool {
        !same(l.modified, b.localModified) || l.size != b.localSize
    }

    /// A local deletion: on the server, unchanged since the last sync, but gone from the Mac.
    static func isLocalDeletion(remote r: FileState?, local l: FileState?, baseline b: OfflineStore.Baseline?) -> Bool {
        guard let r, l == nil, let b else { return false }
        return !serverChanged(r, b)
    }

    /// Lots of files vanishing locally at once looks like an accident (or a drive
    /// hiccup), so don't delete them on the server: bring them back instead.
    static func tooManyDeletions(_ deletions: Int, knownFiles: Int) -> Bool {
        deletions > max(10, knownFiles * 3 / 10)
    }

    static func decide(remote r: FileState?, local l: FileState?, baseline b: OfflineStore.Baseline?,
                       now: Double, safetyNet: Bool) -> Action {
        if let l, now - l.modified < 2 { return .waitStillWriting }

        switch (r, l, b) {
        case let (r?, l?, b?):
            let server = serverChanged(r, b), local = localChanged(l, b)
            if server && local { return .keepBoth(reason: bothChanged) }
            if local { return .uploadEdit }
            if server { return .download }
            return .nothing

        case let (r?, l?, nil):
            return l.size == r.size ? .compareContents : .keepBoth(reason: differentCopies)

        case let (r?, nil, b?):
            return serverChanged(r, b) || safetyNet ? .download : .deleteOnServer

        case (_?, nil, nil):
            return .download

        case let (nil, l?, b?):
            return localChanged(l, b) ? .uploadNew(note: reuploaded) : .removeLocal

        case (nil, _?, nil):
            return .uploadNew(note: addedLocally)

        case (nil, nil, _?):
            return .forgetBaseline

        case (nil, nil, nil):
            return .nothing
        }
    }
}
