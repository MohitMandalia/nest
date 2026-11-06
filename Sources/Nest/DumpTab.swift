import SwiftUI

struct DumpTab: View {
    @ObservedObject var store: AppStore
    @ObservedObject var dump: DumpStore
    @State private var watchOwner = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text("Dump").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                CountBadge(count: dump.entries.count)
                Spacer()
                Button { dump.openFolder() } label: { Label("Open in Finder", systemImage: "folder") }
                    .buttonStyle(NestActionStyle())
            }.frame(minHeight: 62)
            DumpTabShelf(store: store, dump: dump)
                .frame(maxWidth: .infinity, maxHeight: .infinity).nestPanel()
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(dump.isDropTargeted ? Palette.green : .clear,
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            Text(dump.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .textSelection(.enabled).help(dump.folder.path)
        }
        .onAppear { dump.startWatching(owner: watchOwner) }
        .onDisappear { dump.stopWatching(owner: watchOwner) }
    }
}

private struct DumpTabShelf: NSViewRepresentable {
    var store: AppStore
    var dump: DumpStore

    func makeNSView(context: Context) -> DumpHostingView<DumpTabContents> {
        DumpHostingView(rootView: DumpTabContents(store: store, dump: dump), dump: dump)
    }

    func updateNSView(_ view: DumpHostingView<DumpTabContents>, context: Context) {
        view.rootView = DumpTabContents(store: store, dump: dump)
    }
}

private struct DumpTabContents: View {
    @ObservedObject var store: AppStore
    @ObservedObject var dump: DumpStore

    var body: some View {
        DumpContents(store: store, dump: dump, transferOut: { dump.transferOut($0, mode: $1) })
            .padding(20).background(Palette.panel).foregroundStyle(Palette.ink).tint(Palette.green)
    }

}
