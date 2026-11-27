import Foundation
import UniformTypeIdentifiers

struct Entry: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: Double
    let mime: String?
    // Only set for items in the trash.
    let trashName: String?
    let original: String?
    let deleted: Double?
    let starred: Bool?

    var isStarred: Bool { starred ?? false }
    var id: String { path }
    var thumbKey: String { "\(path)|\(modified)|\(size)" }
    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    var deletedDate: Date? { deleted.map { Date(timeIntervalSince1970: $0) } }

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified, mime, original, deleted, starred
        case isDir = "is_dir"
        case trashName = "trash_name"
    }

    /// Folder this item lives in ("" = top of the drive).
    var parentPath: String { (path as NSString).deletingLastPathComponent }

    /// Name of the containing folder, Drive-style.
    var locationName: String {
        parentPath.isEmpty ? "My Drive" : (parentPath as NSString).lastPathComponent
    }

    /// For trash items: the folder it was deleted from.
    var originalLocation: String {
        let parent = ((original ?? "") as NSString).deletingLastPathComponent
        return parent.isEmpty ? "My Drive" : parent
    }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var utType: UTType {
        if isDir { return .folder }
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    /// Files the server can make thumbnails for.
    var hasThumbnail: Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif"].contains(fileExtension)
    }
}

struct ListResponse: Codable {
    let path: String
    let entries: [Entry]
}

struct EntriesResponse: Codable {
    let entries: [Entry]
}

struct UploadResult: Decodable {
    struct Saved: Decodable {
        let path: String
        let size: Int64
        let modified: Double
        let sha256: String?
    }
    let saved: [Saved]
}

struct LoginResponse: Codable {
    let token: String
    let username: String
}

struct MeResponse: Codable {
    let username: String
    let total: Int64
    let used: Int64
    let free: Int64
    let isAdmin: Bool?
    let quota: Int64?
    let linksEnabled: Bool?
    let backupsEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case username, total, used, free, quota
        case isAdmin = "is_admin"
        case linksEnabled = "links_enabled"
        case backupsEnabled = "backups_enabled"
    }
}

struct ServerError: Codable {
    let detail: String
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false  // "0 KB", not "Zero KB"
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    /// Drive-style dates: "3:42 PM" today, "Nov 20" this year, "Dec 15, 2025" otherwise.
    static func date(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.month(.abbreviated).day())
        }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Transfers

struct Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable {
        case waiting, active, done
        case failed(String)
    }

    let id = UUID()
    let name: String
    let kind: Kind
    let isFolder: Bool
    var state: State = .waiting
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = -1
    /// For finished downloads: where the file was saved.
    var localURL: URL?
    /// Extra status shown under the name when done, e.g. "Verified · moved to Trash".
    var note: String?

    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

// MARK: - Sorting

enum SortKey: String {
    case name, modified, size, deleted
}

struct SortSetting: Equatable {
    var key: SortKey
    var ascending: Bool
}
