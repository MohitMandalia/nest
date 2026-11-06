import AppKit
import NestCore

// NSXPC invokes exported objects off the main actor; all engine state stays on it.
private final class BackgroundEndpoint: NSObject, NestBackgroundProtocol {
    let handler: @Sendable (Data, @escaping (Data?, String?) -> Void) -> Void
    init(handler: @escaping @Sendable (Data, @escaping (Data?, String?) -> Void) -> Void) { self.handler = handler }
    func perform(_ data: Data, reply: @escaping (Data?, String?) -> Void) { handler(data, reply) }
}

@MainActor
final class BackgroundCommandHandler {
    let store: AppStore
    init(store: AppStore) { self.store = store }
    func perform(_ command: BackgroundCommand) async {
        switch command {
        case .openDump, .quitAll: break
        case .snapshot:
            // Reply immediately so a person answering macOS's prompt cannot time out XPC polling.
            Task {
                guard await store.requestInitialDownloadsAccessIfNeeded() else { return }
                if store.preferences.source != nil, !store.downloadsPermissionDenied,
                   !store.monitoring, !store.checkingDownloadsAccess { store.startWatching() }
            }
        case .requestDownloadsAccess:
            await store.requestDownloadsAccess()
            if store.preferences.source != nil, !store.downloadsPermissionDenied,
               !store.monitoring, !store.checkingDownloadsAccess { store.startWatching() }
        case .setDestination(let folder):
            do {
                let url = try folder.resolve()
                guard store.validateFolder(url) else { return }
                store.preferences.destination = folder
                store.save()
                store.routePendingFiles()
            } catch { store.error = error.localizedDescription }
        case .togglePause: store.togglePause()
        case .setBackgroundRunning(let enabled): store.setBackgroundRunning(enabled)
        case .route(let id):
            if let file = store.pending.first(where: { $0.id == id }) { store.route(file) }
        case .dismiss(let id):
            if let file = store.pending.first(where: { $0.id == id }) { store.dismiss(file) }
        case .undo(let id):
            if let transfer = store.preferences.history.first(where: { $0.id == id }) { store.undo(transfer) }
        }
    }
}

@MainActor
final class BackgroundWorker: NSObject, NSXPCListenerDelegate {
    let store: AppStore
    let dump: DumpStore
    private let handler: BackgroundCommandHandler
    private let listener: NSXPCListener
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var status: NestStatusItem?
    private var idleTask: Task<Void, Never>?
    private var stopping = false
    private var openingMainWindow = false
    private let clientRequirement: String

    init(clientBundle: URL) throws {
        clientRequirement = try NestBackground.requirement(for: clientBundle)
        store = AppStore(startMonitor: false)
        dump = DumpStore()
        handler = BackgroundCommandHandler(store: store)
        listener = NSXPCListener(machServiceName: NestBackground.name)
        super.init()
        listener.delegate = self
    }
    func start() {
        status = NestStatusItem(store: store, dump: dump, openNest: { [weak self] in
            self?.openMainWindow()
        }, quitNest: { [weak self] in self?.quitAll() })
        listener.resume()
        if store.keepRunningInBackground, store.preferences.source != nil { store.startWatching() }
        scheduleIdleStop()
    }
    func openMainWindow() {
        guard !stopping, !openingMainWindow else { return }
        openingMainWindow = true
        Task {
            defer { openingMainWindow = false }
            if let connection = connections.values.first {
                let revealed = await withCheckedContinuation { continuation in
                    let once = BackgroundResultOnce { data, _ in continuation.resume(returning: data != nil) }
                    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.finish(nil, nil) } as? NestBackgroundClientProtocol
                    proxy?.showMainWindow { once.finish(Data(), nil) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish(nil, nil) }
                }
                if revealed { return }
            }
            // LaunchServices can mistake the helper for the running main app because
            // both executables live in Nest.app. Force a launch when no UI responds.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: NestBackground.mainBundleURL, configuration: config)
            } catch {
                dump.error = "Couldn’t open Nest. \(error.localizedDescription)"
                BackgroundDiagnostics.record("open-window", message: error.localizedDescription)
            }
        }
    }
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Delegate calls arrive on an XPC queue. Serialize acceptance and teardown.
        MainActor.assumeIsolatedIfMainOrSync {
            self.accept(connection)
        }
    }
    private func accept(_ connection: NSXPCConnection) -> Bool {
        guard !stopping, connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: NestBackgroundProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: NestBackgroundClientProtocol.self)
        connection.exportedObject = BackgroundEndpoint { [weak self] data, reply in
            Task { @MainActor in
                guard let self, !self.stopping else { reply(nil, "Nest is stopping."); return }
                do {
                    let command = try JSONDecoder().decode(BackgroundCommand.self, from: data)
                    if case .openDump = command { NotificationCenter.default.post(name: .nestOpenDump, object: nil) }
                    if case .quitAll = command {
                        reply(try JSONEncoder().encode(self.store.backgroundSnapshot), nil)
                        self.quitAll()
                        return
                    }
                    await self.handler.perform(command)
                    reply(try JSONEncoder().encode(self.store.backgroundSnapshot), nil)
                    self.scheduleIdleStop()
                } catch { reply(nil, error.localizedDescription) }
            }
        }
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connections.removeValue(forKey: id)
                self?.scheduleIdleStop()
            }
        }
        connections[id] = connection
        idleTask?.cancel()
        connection.resume()
        if !store.monitoring, !store.checkingDownloadsAccess, !store.downloadsPermissionDenied,
           store.preferences.source != nil { store.startWatching() }
        return true
    }
    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard BackgroundLifetime.shouldStop(backgroundEnabled: store.keepRunningInBackground, clients: connections.count) else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, BackgroundLifetime.shouldStop(backgroundEnabled: self.store.keepRunningInBackground, clients: self.connections.count) else { return }
            self.finishStopping()
        }
    }
    func quitAll() {
        guard !stopping else { return }
        finishStopping(notifyClients: true)
    }
    private func notifyClientsOfShutdown() async {
        let clients = Array(connections.values)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for connection in clients {
                group.enter()
                let once = BackgroundReplyOnce { group.leave() }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.finish() } as? NestBackgroundClientProtocol
                proxy?.serviceWillStop { once.finish() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish() }
            }
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
    private func finishStopping(notifyClients: Bool = false) {
        guard !stopping else { return }
        stopping = true
        dump.acceptingTransfers = false
        store.acceptingTransfers = false
        store.stopWatching()
        Task {
            if notifyClients { await notifyClientsOfShutdown() }
            // Finish in-flight filesystem operations and persist their results before exit.
            while !store.busy.isEmpty || dump.isTransferring { try? await Task.sleep(for: .milliseconds(100)) }
            store.save()
            listener.invalidate()
            for connection in connections.values { connection.invalidate() }
            status?.stop()
            NSApp.terminate(nil)
        }
    }
}

// The delegate method is synchronous, while NSXPC delivers on a background queue.
private extension MainActor {
    nonisolated static func assumeIsolatedIfMainOrSync<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}

@MainActor
final class BackgroundApplicationDelegate: NSObject, NSApplicationDelegate {
    private var worker: BackgroundWorker?
    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundDiagnostics.record("worker", message: "Process started")
        do {
            let worker = try BackgroundWorker(clientBundle: NestBackground.mainBundleURL)
            self.worker = worker
            worker.start()
            BackgroundDiagnostics.record("worker", message: "Listening for Nest")
        } catch {
            BackgroundDiagnostics.record("worker", message: String(describing: error))
            NSLog("Nest background service could not start: %@", error.localizedDescription)
            exit(1)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.shared.finishSession()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        worker?.openMainWindow()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
