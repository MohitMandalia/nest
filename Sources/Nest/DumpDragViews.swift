import SwiftUI
import AppKit
import NestCore

// The hosting view owns drop registration so the full panel is a destination,
// including its blank space, header, file list, and footer.
final class DumpHostingView<Content: View>: NSHostingView<Content> {
    private let dump: DumpStore
    init(rootView: Content, dump: DumpStore) {
        self.dump = dump
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    required init(rootView: Content) { fatalError("Use init(rootView:dump:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = DumpDropPayload.operation(sender, canAccept: dump.canAcceptTransfers)
        dump.isDropTargeted = !operation.isEmpty
        return operation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dump.isDropTargeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !DumpDropPayload.operation(sender, canAccept: dump.canAcceptTransfers).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dump.isDropTargeted = false
        guard !DumpDropPayload.operation(sender, canAccept: dump.canAcceptTransfers).isEmpty else { return false }
        dump.addFiles(DumpDropPayload.urls(sender))
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dump.isDropTargeted = false }
}

private enum DumpDropPayload {
    static func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { ($0 as? NSURL).map { $0 as URL } }.filter(\.isFileURL)
    }
    static func operation(_ sender: NSDraggingInfo, canAccept: Bool) -> NSDragOperation {
        canAccept && !urls(sender).isEmpty && sender.draggingSourceOperationMask.contains(.move) ? .move : []
    }
}

final class FileDropView: NSView {
    var canAccept: () -> Bool = { true }
    var receive: ([URL]) -> Void = { _ in }
    var clicked: ((NSEvent) -> Void)?
    var showBorder = true
    private var targeted = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        DumpDropPayload.operation(sender, canAccept: canAccept())
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let value = operation(sender); targeted = !value.isEmpty; return value
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !operation(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !operation(sender).isEmpty else { targeted = false; return false }
        let files = DumpDropPayload.urls(sender)
        targeted = false
        receive(files)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { targeted = false }
    override func mouseDown(with event: NSEvent) { clicked?(event) }
    override func rightMouseDown(with event: NSEvent) { clicked?(event) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: showBorder ? 10 : 5, yRadius: showBorder ? 10 : 5)
        if targeted {
            NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.31, alpha: 0.12).setFill(); path.fill()
        }
        if showBorder {
            NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.31, alpha: targeted ? 0.7 : 0.25).setStroke()
            path.lineWidth = 1
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

struct DumpDragLabel: NSViewRepresentable {
    var entry: DumpEntry
    @ObservedObject var dump: DumpStore
    func makeNSView(context: Context) -> DumpDragSourceView { DumpDragSourceView() }
    func updateNSView(_ view: DumpDragSourceView, context: Context) {
        view.host.rootView = DumpFileLabel(entry: entry)
        view.select = { command in
            if command {
                if dump.selected.contains(entry.id) { dump.selected.remove(entry.id) } else { dump.selected.insert(entry.id) }
            } else if !dump.selected.contains(entry.id) {
                dump.selected = [entry.id]
            }
        }
        view.files = { dump.selected.contains(entry.id) ? dump.selectedURLs : [entry.url] }
        view.canDrag = { dump.canAcceptTransfers }
        view.finished = { Task { await dump.refresh() } }
    }
}

struct DumpFileLabel: View {
    var entry: DumpEntry?
    var body: some View {
        HStack(spacing: 10) {
            if let entry {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(entry.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }.foregroundStyle(Palette.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

final class DumpDragSourceView: NSView, NSDraggingSource {
    let host = NSHostingView(rootView: DumpFileLabel(entry: nil))
    var select: (Bool) -> Void = { _ in }
    var files: () -> [URL] = { [] }
    var canDrag: () -> Bool = { true }
    var finished: () -> Void = {}
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) {
        guard canDrag() else { return }
        select(event.modifierFlags.contains(.command))
    }
    override func mouseDragged(with event: NSEvent) {
        guard canDrag() else { return }
        let point = convert(event.locationInWindow, from: nil)
        let items = files().enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 3) * 3)
            item.setDraggingFrame(NSRect(x: point.x + offset, y: point.y + offset, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { finished() }
}
