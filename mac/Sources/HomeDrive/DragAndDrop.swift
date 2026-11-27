import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A HomeDrive file or folder being dragged inside the app (declared in Info.plist).
    static let homeDriveItem = UTType(exportedAs: "com.maxkaplan.homedrive.item")
}

/// One file or folder inside a drag.
struct DraggedItem: Codable, Hashable {
    let path: String
    let name: String
    let isDir: Bool

    init(_ entry: Entry) {
        path = entry.path
        name = entry.name
        isDir = entry.isDir
    }
}

/// What gets dragged: the item you grabbed, or the whole selection if it was selected.
///
/// Inside HomeDrive it travels as a small JSON record (so dropping on a folder moves
/// everything). Dropped into Finder it's downloaded first: one file arrives as itself,
/// a folder or several items arrive as a single .zip.
struct DraggedItems: Codable, Transferable {
    let items: [DraggedItem]

    var suggestedName: String {
        if items.count == 1, let only = items.first {
            return only.isDir ? only.name + ".zip" : only.name
        }
        return "HomeDrive items.zip"
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .homeDriveItem)
        FileRepresentation(exportedContentType: .data) { dragged in
            let url = try await DriveModel.shared.exportForDrag(dragged)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.suggestedName }
    }
}

/// Lets a folder row/card (or a breadcrumb) accept dragged items and move them in.
struct FolderDropTarget: ViewModifier {
    @Environment(DriveModel.self) private var model
    let folderPath: String

    func body(content: Content) -> some View {
        content
            .dropDestination(for: DraggedItems.self) { drops, _ in
                let movable = drops.flatMap(\.items).filter { $0.path != folderPath }
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
        modifier(DraggableEntry(entry: entry))
    }
}

struct DraggableEntry: ViewModifier {
    @Environment(DriveModel.self) private var model
    let entry: Entry

    /// Dragging a selected item drags the whole selection, like Finder and Drive.
    private var payload: [Entry] {
        model.selection.contains(entry.id) ? model.selectedEntries : [entry]
    }

    func body(content: Content) -> some View {
        let items = payload
        return content.draggable(DraggedItems(items: items.map(DraggedItem.init))) {
            DragPreview(entries: items)
        }
    }
}

struct DragPreview: View {
    let entries: [Entry]

    var body: some View {
        HStack(spacing: 10) {
            if let first = entries.first {
                FileGlyph(entry: first, size: 18)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.rowSelected, in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        if entries.count == 1, let only = entries.first { return only.name }
        return "\(entries.count) items"
    }
}
