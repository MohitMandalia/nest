import AppKit
import Combine
import NestCore

@MainActor
final class DumpStore: ObservableObject {
    @Published private(set) var entries: [DumpEntry] = []
    @Published private(set) var isTransferring = false
    @Published var selected: Set<String> = []
    @Published var error: String? {
        didSet {
            if let error, error != oldValue, recordsDiagnostics { DiagnosticLog.shared.record("dump-error", error) }
        }
    }
    @Published var message: String?
    @Published var isDropTargeted = false
    var acceptingTransfers = true
    var canAcceptTransfers: Bool { acceptingTransfers && !isTransferring }
    private let recordsDiagnostics: Bool
    let folder: URL
    private var watchOwners: Set<UUID> = []
    private var watchTask: Task<Void, Never>?

    init(folder: URL? = nil) {
        recordsDiagnostics = folder == nil
        self.folder = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Nest Dump", isDirectory: true)
    }
    var selectedURLs: [URL] { entries.filter { selected.contains($0.id) }.map(\.url) }
    func startWatching(owner: UUID) {
        watchOwners.insert(owner)
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func stopWatching(owner: UUID) {
        watchOwners.remove(owner)
        if watchOwners.isEmpty { watchTask?.cancel(); watchTask = nil }
    }
    func stopWatching() {
        watchOwners.removeAll()
        watchTask?.cancel(); watchTask = nil
    }
    func refresh() async {
        let folder = folder
        do {
            let files = try await Task.detached(priority: .utility) {
                try DumpFiles.ensureFolder(folder)
                return try DumpFiles.entries(in: folder)
            }.value
            entries = files
            selected.formIntersection(Set(files.map(\.id)))
        } catch { self.error = "Couldn’t open Dump. \(error.localizedDescription)" }
    }
    func openFolder() {
        Task {
            do {
                try DumpFiles.ensureFolder(folder)
                NSWorkspace.shared.open(folder)
            } catch { self.error = error.localizedDescription }
        }
    }
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty, canAcceptTransfers else { return }
        runTransfer(urls, to: folder, mode: .move, incoming: true)
    }
    func transferOut(_ urls: [URL], mode: DumpTransferMode) {
        guard !urls.isEmpty, canAcceptTransfers else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = mode == .move ? "Move selected items to a folder" : "Copy selected items to a folder"
        panel.prompt = mode == .move ? "Move here" : "Copy here"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url, canAcceptTransfers {
            runTransfer(urls, to: destination, mode: mode, incoming: false)
        }
    }
    private func runTransfer(_ urls: [URL], to destination: URL, mode: DumpTransferMode, incoming: Bool) {
        if recordsDiagnostics { DiagnosticLog.shared.record("dump", "Transfer started; count=\(urls.count); mode=\(mode); incoming=\(incoming)") }
        isTransferring = true; error = nil; message = nil
        Task {
            let folder = folder
            let result = await Task.detached(priority: .userInitiated) {
                do { if incoming { try DumpFiles.ensureFolder(folder) } }
                catch { return DumpTransferResult(transferred: [], skipped: [], failures: [DumpFailure(name: "Dump", message: error.localizedDescription)]) }
                return DumpFiles.transfer(urls, to: destination, mode: mode)
            }.value
            if !result.transferred.isEmpty {
                message = "\(result.transferred.count) \(mode == .copy ? "copied" : "moved") to \(destination.lastPathComponent)"
            } else if !result.skipped.isEmpty && result.failures.isEmpty {
                message = "Already in this folder"
            }
            if !result.failures.isEmpty {
                error = result.failures.prefix(3).map { "\($0.name): \($0.message)" }.joined(separator: "\n")
                if result.failures.count > 3 { error! += "\nAnd \(result.failures.count - 3) more items." }
            }
            if recordsDiagnostics { DiagnosticLog.shared.record("dump", "Transfer finished; transferred=\(result.transferred.count); skipped=\(result.skipped.count); failed=\(result.failures.count)") }
            await refresh()
            isTransferring = false
        }
    }
}
