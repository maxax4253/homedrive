import SwiftUI

/// Drive-style upload/download box in the bottom-right corner.
struct TransfersPanel: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if !model.transfers.isEmpty {
            VStack(spacing: 0) {
                header
                if !model.transfersCollapsed {
                    list
                }
            }
            .frame(width: 380)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.trailing, 28)
            .padding(.bottom, 28)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(icon: model.transfersCollapsed ? "chevron.up" : "chevron.down",
                       help: model.transfersCollapsed ? "Expand" : "Minimize") {
                model.transfersCollapsed.toggle()
            }
            if model.activeTransferCount == 0 {
                IconButton(icon: "xmark", help: "Close") { model.clearTransfers() }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(Theme.card)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.transfers.reversed())) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
        }
        .frame(height: min(CGFloat(model.transfers.count) * 52, 280))
    }

    private var title: String {
        let active = model.transfers.filter { !$0.isFinished }
        if !active.isEmpty {
            let uploads = active.filter { $0.kind == .upload }.count
            let downloads = active.count - uploads
            if downloads == 0 { return "Uploading \(uploads) item\(uploads == 1 ? "" : "s")" }
            if uploads == 0 { return "Downloading \(downloads) item\(downloads == 1 ? "" : "s")" }
            return "\(active.count) transfers in progress"
        }
        let failed = model.transfers.filter { if case .failed = $0.state { return true } else { return false } }.count
        let done = model.transfers.count - failed
        let allUploads = model.transfers.allSatisfy { $0.kind == .upload }
        let allDownloads = model.transfers.allSatisfy { $0.kind == .download }
        let noun = allUploads ? "upload" : (allDownloads ? "download" : "transfer")
        var text = "\(done) \(noun)\(done == 1 ? "" : "s") complete"
        if failed > 0 { text += ", \(failed) failed" }
        return text
    }
}

struct TransferRow: View {
    @Environment(DriveModel.self) private var model
    let transfer: Transfer

    private var hoverKey: String { "transfer:" + transfer.id.uuidString }
    private var kind: FileKind { FileKind(name: transfer.name, isDir: false) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transfer.isFolder ? "doc.zipper" : kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(transfer.isFolder ? FileKind.archive.tint : kind.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(model.hoveredID == hoverKey ? Theme.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in Hover.update(model, key: hoverKey, inside: inside) }
        .onTapGesture { model.reveal(transfer) }
        .help(helpText)
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(Theme.textSecondary)
        case .active:
            if let f = transfer.fraction {
                ProgressRing(fraction: f)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done:
            if transfer.kind == .download && model.hoveredID == hoverKey {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 0.24))
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(red: 0.85, green: 0.19, blue: 0.15))
        }
    }

    private var detail: String? {
        switch transfer.state {
        case .waiting:
            return "Waiting…"
        case .active:
            if transfer.bytesTotal > 0 {
                return "\(Format.size(transfer.bytesDone)) of \(Format.size(transfer.bytesTotal))"
            }
            return transfer.bytesDone > 0 ? Format.size(transfer.bytesDone) : nil
        case .done:
            return transfer.note
        case .failed(let message):
            return message
        }
    }

    private var helpText: String {
        if case .failed(let message) = transfer.state { return message }
        if transfer.kind == .download && transfer.state == .done { return "Show in Finder" }
        return transfer.name
    }
}

struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.divider, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .animation(.linear(duration: 0.15), value: fraction)
    }
}

struct IconButton: View {
    @Environment(DriveModel.self) private var model
    let icon: String
    let help: String
    let action: () -> Void

    private var hoverKey: String { "icon:" + icon + help }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(model.hoveredID == hoverKey ? Theme.hover : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in Hover.update(model, key: hoverKey, inside: inside) }
    }
}
