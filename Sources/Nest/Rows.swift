import SwiftUI
import AppKit
import NestCore

struct PendingRow: View {
    @EnvironmentObject var store: AppStore
    var file: DetectedFile
    private var busy: Bool { store.busy.contains(file.id) }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: file.failure == nil ? "doc.badge.clock" : "exclamationmark.circle")
                .font(.system(size: 22, weight: .light)).foregroundStyle(file.failure == nil ? Palette.green : Palette.warning)
                .frame(width: 30, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(file.failure ?? (busy ? "Moving…" : store.preferences.destination == nil ? "Choose a destination folder" : store.preferences.paused ? "Paused" : "Waiting to move"))
                    .font(.system(size: 10)).foregroundStyle(file.failure == nil ? Palette.muted : Palette.warning).lineLimit(2)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small).accessibilityLabel("Moving file")
            } else {
                if store.preferences.destination != nil {
                    Button(file.failure == nil ? "Move now" : "Retry") { store.route(file) }
                        .buttonStyle(NestQuietStyle()).font(.system(size: 11)).foregroundStyle(Palette.green)
                        .help("Move \(file.url.lastPathComponent) to the destination")
                }
                Menu {
                    Button("Leave in Downloads") { store.dismiss(file) }
                } label: { Image(systemName: "ellipsis").frame(width: 18) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Palette.muted)
                    .help("File options").accessibilityLabel("Options for \(file.url.lastPathComponent)")
            }
        }.padding(.vertical, 12)
    }
}

struct HistoryRow: View {
    @EnvironmentObject var store: AppStore
    var transfer: Transfer
    private var busy: Bool { store.busy.contains(transfer.id.uuidString) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.undone ? "arrow.uturn.backward" : fileIcon)
                .font(.system(size: 22, weight: .light)).foregroundStyle(transfer.undone ? Palette.muted : Palette.green)
                .frame(width: 30, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(transfer.undone ? "Returned to Downloads" : URL(fileURLWithPath: transfer.currentPath).deletingLastPathComponent().lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·")
                    Text(transfer.date, style: .time).fixedSize()
                    if let snapshot = transfer.snapshot {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file)).fixedSize()
                    }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small).accessibilityLabel("Undoing move")
            } else if !transfer.undone {
                Button("Undo") { store.undo(transfer) }.buttonStyle(NestQuietStyle())
                    .font(.system(size: 11)).foregroundStyle(Palette.green)
                    .help("Return \(transfer.name) to its original folder")
            } else {
                Text("Undone").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Button { store.reveal(transfer.currentPath) } label: { Image(systemName: "arrow.up.right.square").padding(4) }
                .buttonStyle(NestQuietStyle()).foregroundStyle(Palette.muted)
                .help("Show in Finder").accessibilityLabel("Show \(transfer.name) in Finder")
        }.padding(.vertical, 12)
    }
    private var fileIcon: String {
        switch URL(fileURLWithPath: transfer.currentPath).pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "png", "gif": return "photo"
        case "mov", "mp4": return "film"
        case "mp3", "wav", "m4a": return "waveform"
        case "zip", "gz": return "doc.zipper"
        default: return "doc.text"
        }
    }
}
