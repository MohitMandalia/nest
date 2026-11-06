import SwiftUI
import NestCore

struct DumpPopover: View {
    @ObservedObject var store: AppStore
    @ObservedObject var dump: DumpStore
    var quitNest: () -> Void = { NSApp.terminate(nil) }
    var close: () -> Void
    var openNest: () -> Void
    var transferOut: ([URL], DumpTransferMode) -> Void

    @State private var watchOwner = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(nsImage: NestBrand.menuBarLogo).renderingMode(.original)
                Text("Dump").font(.system(size: 18, weight: .semibold))
                CountBadge(count: dump.entries.count)
                Text(dump.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(dump.folder.path)
                Spacer()
                Button { dump.openFolder() } label: { Image(systemName: "folder").padding(4) }
                    .buttonStyle(NestQuietStyle()).help("Open Dump in Finder").accessibilityLabel("Open Dump in Finder")
                Button(action: close) { Image(systemName: "xmark").padding(4) }
                    .buttonStyle(NestQuietStyle()).help("Close Dump").accessibilityLabel("Close Dump")
            }
            DumpContents(store: store, dump: dump, transferOut: transferOut)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Button(action: openNest) {
                    Label("Open", systemImage: "arrow.up.right")
                }.buttonStyle(DumpFooterButtonStyle(tone: .primary))
                    .help("Open")
                Spacer()
                Button { store.togglePause() } label: {
                    Label(store.preferences.paused ? "Resume AirDrop" : "Pause AirDrop",
                          systemImage: store.preferences.paused ? "play.fill" : "pause.fill")
                }.buttonStyle(DumpFooterButtonStyle(tone: .standard))
                    .disabled(!store.ready)
                    .help(store.preferences.paused ? "Resume AirDrop" : "Pause AirDrop")
                Button(action: quitNest) {
                    Label("Quit", systemImage: "power")
                }.buttonStyle(DumpFooterButtonStyle(tone: .quit))
                    .help("Quit")
            }.labelStyle(.iconOnly)

        }.padding(18).frame(width: 420, height: 560)
            .background(Palette.canvas).foregroundStyle(Palette.ink).tint(Palette.green).preferredColorScheme(.light)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(dump.isDropTargeted ? Palette.green : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(3).allowsHitTesting(false)
            }
            .onAppear { dump.startWatching(owner: watchOwner) }.onDisappear { dump.stopWatching(owner: watchOwner) }
    }

}

private struct DumpFooterButtonStyle: ButtonStyle {
    enum Tone { case primary, standard, quit }
    var tone: Tone
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var accent: Color {
        tone == .quit ? Color(red: 0.67, green: 0.24, blue: 0.20) : Palette.green
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 36, height: 36)
            .foregroundStyle(tone == .primary ? Color.white : accent)
            .background(tone == .primary ? accent : accent.opacity(hovering && enabled ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(tone == .primary ? 0 : hovering && enabled ? 0.30 : 0.16)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct DumpContents: View {
    @ObservedObject var store: AppStore
    @ObservedObject var dump: DumpStore
    var transferOut: ([URL], DumpTransferMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dump.isTransferring {
                HStack { ProgressView().controlSize(.small); Text("Transferring…").font(.system(size: 11)) }
            }
            if let error = dump.error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.warning).lineLimit(4)
                    Spacer()
                    Button { dump.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(NestQuietStyle()).help("Dismiss error")
                }
            } else if let message = dump.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.green).lineLimit(2)
            }
            if dump.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("Dump is empty").font(.system(size: 14, weight: .medium))
                    Text("Drag items back out, or use Move to… when you need them.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(dump.entries) { entry in row(entry) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ entry: DumpEntry) -> some View {
        HStack(spacing: 8) {
            Toggle("Select \(entry.name)", isOn: Binding(get: { dump.selected.contains(entry.id) }, set: { checked in
                if checked { dump.selected.insert(entry.id) } else { dump.selected.remove(entry.id) }
            })).labelsHidden().toggleStyle(.checkbox)
            DumpDragLabel(entry: entry, dump: dump).frame(maxWidth: .infinity).frame(height: 44)
                .help("Drag to Finder or another app. Command-click to select multiple items.")
            Menu {
                Button("Move to…") { transferOut([entry.url], .move) }
                Button("Copy to…") { transferOut([entry.url], .copy) }
                Button("Show in Finder") { store.reveal(entry.url.path) }
            } label: { Image(systemName: "ellipsis").padding(4) }.menuStyle(.borderlessButton).fixedSize()
                .help("Options for \(entry.name)")
        }.padding(.horizontal, 8).padding(.vertical, 3)
            .background(dump.selected.contains(entry.id) ? Palette.mint : .clear, in: RoundedRectangle(cornerRadius: 8))
            .disabled(dump.isTransferring)
    }
}
