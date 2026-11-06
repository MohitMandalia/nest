import AppKit
import Combine
import NestCore
import ServiceManagement

struct Preferences: Codable {
    var source: FolderReference?
    var destination: FolderReference?
    // Retain previous per-person rules on disk while the feature is unavailable.
    var routes: [PersonRoute] = []
    var paused = false
    var history: [Transfer] = []
    var pendingPaths: [String] = []
    // Optional so existing preferences continue to decode.
    var downloadsAccessDenied: Bool?
    var downloadsAccessRequested: Bool?
    var keepRunningInBackground: Bool?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var preferences = Preferences()
    @Published var pending: [DetectedFile] = []
    @Published var busy: Set<String> = []
    @Published var error: String? {
        didSet {
            if let error, error != oldValue, recordsRuntimeDiagnostics {
                DiagnosticLog.shared.record("app-error", error)
            }
        }
    }
    @Published var monitoring = false
    @Published private(set) var checkingDownloadsAccess = false
    @Published private(set) var downloadsAccessIssue: String?
    @Published var requestingDownloadsAccess = false
    @Published var downloadsPermissionDenied = false
    @Published var notice: String?
    @Published var selectedTab = "Overview"
    @Published var connectingToBackground = false
    @Published var backgroundServiceIssue: String?
    @Published var backgroundApprovalRequired = false
    private(set) var backgroundClient: BackgroundClient?
    private let isBackgroundClient: Bool
    private let recordsRuntimeDiagnostics: Bool
    var usesBackgroundService: Bool { isBackgroundClient }
    var acceptingTransfers = true
    private var downloadsRequestInFlight = false
    private var lastBackgroundError: String?
    private var lastBackgroundNotice: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private let scanner = DownloadScanner()
    private var watchTask: Task<Void, Never>?
    private var sourceAccess: URL?
    private var persistenceURL: URL
    private var settlingPendingPaths: Set<String> = []
    private var pendingTracker = SettlingTracker()
    private var pendingQueueRestored = true
    private var canSave = true
    private let downloadsDirectory: URL
    private let shouldStartMonitor: Bool
    private let checkDownloadsAccess: @Sendable (URL) throws -> Void

    init(storageURL: URL? = nil, startMonitor: Bool = true, downloadsDirectory: URL? = nil, remote: Bool = false,
         checkDownloadsAccess: @escaping @Sendable (URL) throws -> Void = { url in
             // Access, rather than a custom dialog, lets macOS request Downloads consent.
             _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
         }) {
        isBackgroundClient = remote
        recordsRuntimeDiagnostics = storageURL == nil && !remote
        self.downloadsDirectory = downloadsDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        self.checkDownloadsAccess = checkDownloadsAccess
        shouldStartMonitor = startMonitor && !remote
        let defaultSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nest", isDirectory: true)
        persistenceURL = storageURL ?? defaultSupport.appendingPathComponent("preferences.json")
        let support = persistenceURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: persistenceURL.path) {
                preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: persistenceURL))
            }
        } catch {
            if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("settings-error", error.localizedDescription) }
            canSave = false
            self.error = "Nest couldn’t read its settings. Existing settings will not be overwritten. \(error.localizedDescription)"
        }
        pendingQueueRestored = preferences.pendingPaths.isEmpty
        downloadsPermissionDenied = preferences.downloadsAccessDenied == true
        if downloadsPermissionDenied {
            downloadsAccessIssue = Self.deniedAccessMessage
        } else if canSave, shouldStartMonitor, preferences.source != nil {
            startWatching()
        }
    }
    func connectToBackgroundService() {
        guard isBackgroundClient, backgroundClient == nil else { return }
        let client = BackgroundClient(store: self)
        backgroundClient = client
        client.start()
    }
    func sendToBackground(_ command: BackgroundCommand) {
        guard isBackgroundClient else { return }
        Task { await backgroundClient?.send(command) }
    }
    func retryBackgroundService() {
        connectToBackgroundService()
        Task { await backgroundClient?.retry() }
    }
    func openBackgroundSettings() { backgroundClient?.openSettings() }
    var backgroundSnapshot: BackgroundSnapshot {
        BackgroundSnapshot(preferences: preferences, pending: pending, busy: busy,
                           monitoring: monitoring, checkingDownloadsAccess: checkingDownloadsAccess,
                           requestingDownloadsAccess: requestingDownloadsAccess,
                           downloadsPermissionDenied: downloadsPermissionDenied,
                           downloadsAccessIssue: downloadsAccessIssue, error: error, notice: notice)
    }
    func markBackgroundUnavailable() {
        monitoring = false
        checkingDownloadsAccess = false
        requestingDownloadsAccess = downloadsRequestInFlight
    }
    func applyBackgroundSnapshot(_ snapshot: BackgroundSnapshot) {
        preferences = snapshot.preferences
        pending = snapshot.pending
        busy = snapshot.busy
        monitoring = snapshot.monitoring
        checkingDownloadsAccess = snapshot.checkingDownloadsAccess
        requestingDownloadsAccess = downloadsRequestInFlight || snapshot.requestingDownloadsAccess
        downloadsPermissionDenied = snapshot.downloadsPermissionDenied
        downloadsAccessIssue = snapshot.downloadsAccessIssue
        if snapshot.error != lastBackgroundError { error = snapshot.error; lastBackgroundError = snapshot.error }
        if snapshot.notice != lastBackgroundNotice { notice = snapshot.notice; lastBackgroundNotice = snapshot.notice }
    }
    var ready: Bool { preferences.source != nil && preferences.destination != nil }
    var keepRunningInBackground: Bool { preferences.keepRunningInBackground ?? true }
    func setBackgroundRunning(_ enabled: Bool) {
        if isBackgroundClient { sendToBackground(.setBackgroundRunning(enabled)); return }
        preferences.keepRunningInBackground = enabled
        save()
    }
    func save() {
        guard !isBackgroundClient, canSave else { return }
        if pendingQueueRestored || !pending.isEmpty {
            preferences.pendingPaths = pending.map { $0.url.path }
            pendingQueueRestored = true
        }
        persistPreferences()
    }
    private func persistPreferences() {
        guard !isBackgroundClient, canSave else { return }
        do { try JSONEncoder().encode(preferences).write(to: persistenceURL, options: .atomic) }
        catch { self.error = "Couldn’t save settings: \(error.localizedDescription)" }
    }
    private static let deniedAccessMessage = "Enable Nest in System Settings → Privacy & Security → Files & Folders, then retry access."

    private static func isPermissionError(_ error: Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(failure.code) { return true }
        if failure.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(failure.code) { return true }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== failure { return isPermissionError(underlying) }
        return false
    }
    func handleDownloadsAccessFailure(_ failure: Error) {
        stopWatching()
        downloadsPermissionDenied = Self.isPermissionError(failure)
        preferences.downloadsAccessDenied = downloadsPermissionDenied
        downloadsAccessIssue = downloadsPermissionDenied ? Self.deniedAccessMessage : "Nest couldn’t read Downloads. \(failure.localizedDescription)"
        if recordsRuntimeDiagnostics { BackgroundDiagnostics.record("routing", message: "Downloads unavailable: \(failure.localizedDescription)") }
        // Do not rewrite pending paths before a failed startup has restored the queue.
        persistPreferences()
    }
    func chooseFolder(title: String, initial: URL? = nil) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title; panel.message = title; panel.prompt = "Choose folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        return panel.runModal() == .OK ? panel.url : nil
    }
    @discardableResult
    func requestInitialDownloadsAccessIfNeeded() async -> Bool {
        guard !isBackgroundClient, canSave, acceptingTransfers,
              preferences.source == nil, !downloadsPermissionDenied,
              preferences.downloadsAccessRequested != true,
              !requestingDownloadsAccess, !checkingDownloadsAccess else { return false }
        await requestDownloadsAccess()
        return true
    }
    func requestDownloadsAccess() async {
        if isBackgroundClient {
            guard !downloadsRequestInFlight else { return }
            connectToBackgroundService()
            downloadsRequestInFlight = true
            requestingDownloadsAccess = true
            defer { downloadsRequestInFlight = false; requestingDownloadsAccess = false }
            await backgroundClient?.send(.requestDownloadsAccess)
            return
        }
        guard !requestingDownloadsAccess, !checkingDownloadsAccess else { return }
        // Already connected: a second click must not request or restart access.
        if monitoring, preferences.source?.path == downloadsDirectory.path, !downloadsPermissionDenied { return }
        guard busy.isEmpty else { error = "Wait for the current move to finish."; return }
        requestingDownloadsAccess = true
        preferences.downloadsAccessRequested = true
        persistPreferences()
        error = nil
        downloadsAccessIssue = nil
        defer { requestingDownloadsAccess = false }
        let url = downloadsDirectory
        // First UI connection requests consent automatically; later retries are explicit.
        do {
            let check = checkDownloadsAccess
            try await Task.detached(priority: .userInitiated) { try check(url) }.value
        } catch {
            handleDownloadsAccessFailure(error)
            return
        }
        downloadsPermissionDenied = false
        preferences.downloadsAccessDenied = false
        // Save consent independently of the destination. An offline destination must not
        // make the user repeat Downloads setup; each move validates its destination.
        let sameSource = preferences.source?.path == url.path
        if !sameSource {
            pending = []
            preferences.pendingPaths = []
            pendingQueueRestored = true
        } else if !pending.isEmpty {
            preferences.pendingPaths = pending.map { $0.url.path }
        }
        var reference = FolderReference(url: url)
        reference.bookmark = nil
        preferences.source = reference
        // A denial may have prevented queue restoration on startup. Keep those paths
        // until startWatching can revalidate them after access succeeds.
        persistPreferences()
        if shouldStartMonitor && (!sameSource || !monitoring) { startWatching() }
    }

    func openFilesAndFoldersSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }
    func chooseDefault() {
        guard let url = chooseFolder(title: "Choose destination folder") else { return }
        guard validateFolder(url) else { return }
        if isBackgroundClient { sendToBackground(.setDestination(FolderReference(url: url))); return }
        preferences.destination = FolderReference(url: url); save()
    }
    func validateFolder(_ url: URL) -> Bool {
        do {
            let source = try preferences.source?.resolve() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            try FileRouter.validate(destination: url, sourceFolder: source)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func togglePause() {
        if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("routing", "Pause toggled") }
        if isBackgroundClient { sendToBackground(.togglePause); return }
        preferences.paused.toggle(); save()
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notice = "Allow Nest in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = error.localizedDescription }
    }
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        if let old = sourceAccess { old.stopAccessingSecurityScopedResource(); sourceAccess = nil }
        monitoring = false
        checkingDownloadsAccess = false
    }
    func startWatching() {
        guard !isBackgroundClient, acceptingTransfers else { return }
        stopWatching()
        guard !downloadsPermissionDenied, let ref = preferences.source else { return }
        checkingDownloadsAccess = true
        downloadsAccessIssue = nil
        do {
            let source = try ref.resolve()
            if source.startAccessingSecurityScopedResource() { sourceAccess = source }
            let restore = preferences.pendingPaths
            watchTask = Task { [weak self, scanner] in
                do {
                    try await scanner.start(folder: source)
                    guard !Task.isCancelled, let self else { return }
                    self.monitoring = true
                    if self.recordsRuntimeDiagnostics { BackgroundDiagnostics.record("routing", message: "Watching Downloads; mode=\(NestBackground.isWorker ? "service" : "menu bar")") }
                    self.checkingDownloadsAccess = false
                    self.downloadsAccessIssue = nil
                    self.downloadsPermissionDenied = false
                    self.preferences.downloadsAccessDenied = false
                    self.pending = restore.compactMap { path in
                        let url = URL(fileURLWithPath: path)
                        guard url.deletingLastPathComponent().standardizedFileURL == source.standardizedFileURL,
                              AirDropMetadata.isAirDrop(quarantine: AirDropMetadata.quarantine(at: url)),
                              let snapshot = FileSnapshot.read(url) else { return nil }
                        return DetectedFile(url: url, snapshot: snapshot)
                    }
                    self.settlingPendingPaths = Set(self.pending.map(\.id))
                    self.pendingTracker = SettlingTracker()
                    for file in self.pending {
                        _ = self.pendingTracker.ready(url: file.url, snapshot: file.snapshot)
                    }
                    self.pendingQueueRestored = true
                    while !Task.isCancelled {
                        if !self.preferences.paused {
                            let detected = try await scanner.scan()
                            guard !Task.isCancelled else { return }
                            for file in detected where !self.pending.contains(where: { $0.id == file.id }) {
                                self.pending.append(file)
                            }
                            if !detected.isEmpty { self.save() }
                            self.routePendingFiles()
                        }
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled else { return }
                    self?.handleDownloadsAccessFailure(error)
                }
            }
        } catch { handleDownloadsAccessFailure(error) }
    }
    func routePendingFiles() {
        guard !preferences.paused, preferences.destination != nil else { return }
        for file in pending where file.failure == nil && !busy.contains(file.id) { route(file) }
    }
    func route(_ file: DetectedFile, now: Date = Date()) {
        if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("routing", "Route requested") }
        if isBackgroundClient { sendToBackground(.route(file.id)); return }
        guard acceptingTransfers else { return }
        guard !busy.contains(file.id) else { return }
        var file = pending.first(where: { $0.id == file.id }) ?? file
        if let snapshot = FileSnapshot.read(file.url),
           settlingPendingPaths.contains(file.id) || snapshot != file.snapshot {
            // Restored files and files changed while queued must settle again.
            settlingPendingPaths.insert(file.id)
            file.snapshot = snapshot
            file.failure = nil
            if let index = pending.firstIndex(where: { $0.id == file.id }) {
                pending[index] = file
            }
            guard pendingTracker.ready(url: file.url, snapshot: snapshot, now: now) else { return }
            settlingPendingPaths.remove(file.id)
        }
        guard let ref = preferences.destination else {
            error = "Choose a default destination first."; return
        }
        busy.insert(file.id)
        Task { [file] in
            do {
                let destination = try ref.resolve()
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                let sourceFolder = try preferences.source?.resolve() ?? file.url.deletingLastPathComponent()
                let moved = try await Task.detached(priority: .userInitiated) {
                    try FileRouter.validate(destination: destination, sourceFolder: sourceFolder)
                    guard FileSnapshot.read(file.url) == file.snapshot,
                          AirDropMetadata.isAirDrop(quarantine: AirDropMetadata.quarantine(at: file.url)) else { throw RoutingError.sourceChanged }
                    return try FileRouter.move(file.url, to: destination)
                }.value
                if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("routing", "File routed successfully") }
                var transfer = Transfer(originalPath: file.url.path, currentPath: moved.path, sender: nil, destination: ref)
                transfer.snapshot = FileSnapshot.read(moved)
                preferences.history.insert(transfer, at: 0)
                preferences.history = Array(preferences.history.prefix(300))
                pending.removeAll { $0.id == file.id }
                settlingPendingPaths.remove(file.id)
                pendingTracker.retain(paths: settlingPendingPaths)
                notice = "\(moved.lastPathComponent) → \(destination.lastPathComponent)"
                save()
            } catch {
                if let i = pending.firstIndex(where: { $0.id == file.id }) { pending[i].failure = error.localizedDescription }
                self.error = "File left in Downloads. \(error.localizedDescription)"
            }
            busy.remove(file.id)
        }
    }
    func dismiss(_ file: DetectedFile) {
        if isBackgroundClient { sendToBackground(.dismiss(file.id)); return }
        settlingPendingPaths.remove(file.id)
        pendingTracker.retain(paths: settlingPendingPaths)
        pending.removeAll { $0.id == file.id }; save()
    }
    func undo(_ transfer: Transfer) {
        if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("routing", "Undo requested") }
        if isBackgroundClient { sendToBackground(.undo(transfer.id)); return }
        guard acceptingTransfers else { return }
        let key = transfer.id.uuidString
        guard !busy.contains(key), !transfer.undone else { return }
        busy.insert(key)
        Task {
            do {
                let folder = try transfer.destination.resolve()
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let source = URL(fileURLWithPath: transfer.currentPath)
                let target = URL(fileURLWithPath: transfer.originalPath).deletingLastPathComponent()
                let returned = try await Task.detached(priority: .userInitiated) {
                    guard let fingerprint = transfer.snapshot, FileSnapshot.read(source) == fingerprint else { throw RoutingError.sourceChanged }
                    return try FileRouter.move(source, to: target)
                }.value
                if let i = preferences.history.firstIndex(where: { $0.id == transfer.id }) {
                    preferences.history[i].undone = true
                    preferences.history[i].currentPath = returned.path
                }
                if recordsRuntimeDiagnostics { DiagnosticLog.shared.record("routing", "Undo completed") }
                // The scanner ignores a returned item, rather than moving it again.
                await scanner.ignore(path: returned.path)
                notice = "Returned to \(target.lastPathComponent)"; save()
            } catch { self.error = "Couldn’t undo: \(error.localizedDescription)" }
            busy.remove(key)
        }
    }
    func openDestinationFolder() {
        guard let destination = preferences.destination else { return }
        do {
            let folder = try destination.resolve()
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            if !NSWorkspace.shared.open(folder) {
                error = "Couldn’t open the destination folder. Check that it is available."
            }
        } catch {
            self.error = "Couldn’t open the destination folder: \(error.localizedDescription)"
        }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
