import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Google Drive-inspired colors that follow light/dark mode.
enum Theme {
    static let window = adaptive(light: 0xF8FAFD, dark: 0x1B1C1D)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x131314)
    static let card = adaptive(light: 0xF0F4F9, dark: 0x282A2C)
    static let cardPreview = adaptive(light: 0xFFFFFF, dark: 0x1E1F20)
    static let search = adaptive(light: 0xE9EEF6, dark: 0x282A2C)
    static let newButton = adaptive(light: 0xFFFFFF, dark: 0x37393B)
    static let navSelected = adaptive(light: 0xC2E7FF, dark: 0x004A77)
    static let rowSelected = adaptive(light: 0xC2E7FF, dark: 0x004A77)
    static let hover = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.07)
    static let divider = adaptive(light: 0xE1E3E1, dark: 0x3C4043)
    static let textPrimary = adaptive(light: 0x1F1F1F, dark: 0xE3E3E3)
    static let textSecondary = adaptive(light: 0x444746, dark: 0xC4C7C5)
    static let accent = adaptive(light: 0x0B57D0, dark: 0xA8C7FA)
    static let toggleSelected = adaptive(light: 0xC2E7FF, dark: 0x004A77)
    static let folder = adaptive(light: 0x444746, dark: 0xC4C7C5)

    private static func adaptive(light: Int, dark: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? color(dark, darkAlpha) : color(light, lightAlpha)
        }
        return Color(nsColor: ns)
    }

    private static func color(_ hex: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Icon + color for a file, Drive-style (colored glyphs instead of Finder icons).
struct FileGlyph: View {
    let entry: Entry
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.85, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }

    private var kind: FileKind { FileKind(entry) }
    private var symbol: String { kind.symbol }
    private var tint: Color { kind.tint }
}

enum FileKind {
    case folder, image, video, audio, pdf, doc, sheet, slides, archive, code, text, other

    init(_ entry: Entry) {
        self.init(name: entry.name, isDir: entry.isDir)
    }

    init(name: String, isDir: Bool) {
        if isDir { self = .folder; return }
        let ext = (name as NSString).pathExtension.lowercased()
        let t = UTType(filenameExtension: ext) ?? .data
        if t.conforms(to: .image) { self = .image }
        else if t.conforms(to: .movie) || t.conforms(to: .video) { self = .video }
        else if t.conforms(to: .audio) { self = .audio }
        else if t.conforms(to: .pdf) { self = .pdf }
        else if ["doc", "docx", "pages", "rtf", "odt"].contains(ext) { self = .doc }
        else if ["xls", "xlsx", "csv", "numbers", "ods"].contains(ext) { self = .sheet }
        else if ["ppt", "pptx", "key", "odp"].contains(ext) { self = .slides }
        else if t.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz"].contains(ext) { self = .archive }
        else if t.conforms(to: .sourceCode) || ["py", "js", "ts", "swift", "json", "html", "css", "lua", "ipynb"].contains(ext) { self = .code }
        else if t.conforms(to: .text) { self = .text }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext.fill"
        case .doc: return "doc.text.fill"
        case .sheet: return "tablecells.fill"
        case .slides: return "rectangle.on.rectangle.angled.fill"
        case .archive: return "archivebox.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .folder: return Theme.folder
        case .image: return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .video: return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .audio: return Color(red: 0.61, green: 0.32, blue: 0.82)
        case .pdf: return Color(red: 0.86, green: 0.20, blue: 0.18)
        case .doc: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .sheet: return Color(red: 0.06, green: 0.62, blue: 0.35)
        case .slides: return Color(red: 0.96, green: 0.71, blue: 0.0)
        case .archive: return Color(red: 0.47, green: 0.47, blue: 0.47)
        case .code: return Color(red: 0.0, green: 0.59, blue: 0.53)
        case .text: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .other: return Color(red: 0.47, green: 0.47, blue: 0.47)
        }
    }
}
