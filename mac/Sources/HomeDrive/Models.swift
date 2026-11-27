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

    var id: String { path }
    var thumbKey: String { "\(path)|\(modified)|\(size)" }
    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    var deletedDate: Date? { deleted.map { Date(timeIntervalSince1970: $0) } }

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified, mime, original, deleted
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

struct LoginResponse: Codable {
    let token: String
    let username: String
}

struct MeResponse: Codable {
    let username: String
    let total: Int64
    let used: Int64
    let free: Int64
}

struct ServerError: Codable {
    let detail: String
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
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
