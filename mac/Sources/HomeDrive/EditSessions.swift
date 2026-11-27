import AppKit
import Foundation
import Observation

/// "Open in app": a file opened from HomeDrive in Pages, Word, Preview, etc.
/// We watch its folder and upload the file again each time you save.
@MainActor
@Observable
final class EditSessions {
    final class Session {
        var path: String            // where it lives on the server
        let name: String
        let local: URL
        var baseModified: Double    // server's modified time when we last synced
        var lastLocalChange: Date
        var watcher: DispatchSourceFileSystemObject?
        var pending: DispatchWorkItem?

        init(path: String, name: String, local: URL, baseModified: Double, lastLocalChange: Date) {
            self.path = path
            self.name = name
            self.local = local
            self.baseModified = baseModified
            self.lastLocalChange = lastLocalChange
        }
    }

    private(set) var openCount = 0
    @ObservationIgnored private var sessions: [String: Session] = [:]

    var editRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Editing", isDirectory: true)
    }

    func session(for path: String) -> Session? { sessions[path] }

    func add(_ session: Session, onChange: @escaping @MainActor (Session) -> Void) {
        sessions[session.path]?.watcher?.cancel()
        sessions[session.path] = session
        openCount = sessions.count

        // Apps usually save by writing a new file and swapping it in, so watch the folder.
        let dir = session.local.deletingLastPathComponent()
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak session] in
            guard let session else { return }
            // Wait for the app to finish saving before uploading.
            session.pending?.cancel()
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { onChange(session) }
            }
            session.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        session.watcher = source
    }

    /// Re-key a session (e.g. after it was saved as a conflict copy with a new name).
    func move(_ session: Session, to newPath: String) {
        sessions.removeValue(forKey: session.path)
        session.path = newPath
        sessions[newPath] = session
    }

    func stopAll() {
        for s in sessions.values { s.watcher?.cancel() }
        sessions.removeAll()
        openCount = 0
    }
}
