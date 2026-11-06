#if DEBUG
import SwiftUI
import NestCore

// Isolated fixtures for Xcode previews. These never read the user's Nest preferences.
@MainActor
enum NestPreviewFixtures {
    enum State { case setup, connected, paused, activity, denied }
    static func store(_ state: State) -> AppStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NestPreview-\(UUID().uuidString)")
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        guard state != .setup else { return store }
        let downloads = root.appendingPathComponent("Downloads")
        let destination = FolderReference(url: root.appendingPathComponent("AirDrop"))
        store.preferences.source = FolderReference(url: downloads)
        store.preferences.destination = destination
        store.monitoring = true
        store.preferences.paused = state == .paused
        if state == .activity { store.selectedTab = "Activity" }
        for (index, name) in ["IMG_2048.HEIC", "Project notes.pdf", "Recording.m4a"].enumerated() {
            var transfer = Transfer(originalPath: downloads.appendingPathComponent(name).path,
                                    currentPath: URL(fileURLWithPath: destination.path).appendingPathComponent(name).path,
                                    sender: nil, destination: destination)
            transfer.date = Date().addingTimeInterval(-Double(index + 1) * 180)
            store.preferences.history.append(transfer)
        }
        if state == .denied { store.handleDownloadsAccessFailure(CocoaError(.fileReadNoPermission)) }
        return store
    }
}

@MainActor
struct NestPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            MainView().environmentObject(NestPreviewFixtures.store(.setup)).previewDisplayName("Setup")
            MainView().environmentObject(NestPreviewFixtures.store(.connected)).previewDisplayName("Overview")
            MainView().environmentObject(NestPreviewFixtures.store(.paused)).previewDisplayName("Paused")
            MainView().environmentObject(NestPreviewFixtures.store(.activity)).previewDisplayName("Activity")
            MainView().environmentObject(NestPreviewFixtures.store(.denied)).previewDisplayName("Downloads access denied")
            DumpTab(store: NestPreviewFixtures.store(.connected), dump: DumpPanelPreviews.previewDump())
                .padding(26).background(Palette.canvas).previewDisplayName("Dump tab")
        }.environmentObject(DumpPanelPreviews.previewDump()).frame(width: 1180, height: 780).preferredColorScheme(.light)
    }
}

@MainActor
struct DumpPanelPreviews: PreviewProvider {
    static var previews: some View {
        DumpPopover(store: NestPreviewFixtures.store(.connected), dump: previewDump(),
            close: {},
            openNest: {}, transferOut: { _, _ in })
            .previewDisplayName("Menu bar Dump")
    }
    static func previewDump() -> DumpStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NestDumpPreview-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Dump")
        try? DumpFiles.ensureFolder(folder)
        for name in ["Meeting notes.txt", "Project outline.md", "Ideas.txt"] {
            try? Data("Preview fixture".utf8).write(to: folder.appendingPathComponent(name))
        }
        return DumpStore(folder: folder)
    }
}
#endif
