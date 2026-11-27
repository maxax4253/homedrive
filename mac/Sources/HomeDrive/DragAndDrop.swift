import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A HomeDrive file or folder being dragged inside the app (declared in Info.plist).
    static let homeDriveItem = UTType(exportedAs: "com.maxkaplan.homedrive.item")
}

/// What gets dragged when you pick up a file or folder.
///
/// Inside HomeDrive it travels as a small JSON record (so dropping on a folder
/// moves it). Dropped into Finder, it's downloaded first and arrives as a real
/// file; folders arrive as a .zip.
struct DraggedItem: Codable, Transferable {
    let path: String
    let name: String
    let isDir: Bool

    init(_ entry: Entry) {
        path = entry.path
        name = entry.name
        isDir = entry.isDir
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .homeDriveItem)
        FileRepresentation(exportedContentType: .data) { item in
            let url = try await DriveModel.shared.exportForDrag(item)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.isDir ? $0.name + ".zip" : $0.name }
    }
}

/// Lets a folder row/card (or a breadcrumb) accept dragged items and move them in.
struct FolderDropTarget: ViewModifier {
    @Environment(DriveModel.self) private var model
    let folderPath: String

    func body(content: Content) -> some View {
        content
            .dropDestination(for: DraggedItem.self) { items, _ in
                let movable = items.filter { $0.path != folderPath }
                guard !movable.isEmpty else { return false }
                Task { await model.move(movable, into: folderPath) }
                return true
            } isTargeted: { targeted in
                if targeted {
                    model.dropFolderTarget = folderPath
                } else if model.dropFolderTarget == folderPath {
                    model.dropFolderTarget = nil
                }
            }
    }
}

extension View {
    func folderDropTarget(_ path: String) -> some View {
        modifier(FolderDropTarget(folderPath: path))
    }

    /// Makes a row/card draggable: into Finder (downloads it) or onto a folder (moves it).
    func draggableEntry(_ entry: Entry) -> some View {
        draggable(DraggedItem(entry)) {
            DragPreview(entry: entry)
        }
    }
}

struct DragPreview: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 10) {
            FileGlyph(entry: entry, size: 18)
            Text(entry.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.rowSelected, in: RoundedRectangle(cornerRadius: 10))
    }
}
