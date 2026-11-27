import Foundation
import UniformTypeIdentifiers

struct Entry: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: Double
    let mime: String?

    var id: String { path }
    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified, mime
        case isDir = "is_dir"
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
}
