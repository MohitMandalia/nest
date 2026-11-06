import AppKit
import ServiceManagement

final class BackgroundClientObserver: NSObject, NestBackgroundClientProtocol {
    let stopped: @Sendable () -> Void
    init(stopped: @escaping @Sendable () -> Void) { self.stopped = stopped }
    func showMainWindow(reply: @escaping () -> Void) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .nestOpenMainWindow, object: nil)
            reply()
        }
    }
    func serviceWillStop(reply: @escaping () -> Void) { stopped(); reply() }
}

@MainActor
final class BackgroundClient {
    private weak var store: AppStore?
    private let record: (String, String) -> Void
    private let service: any BackgroundRegistration
    private let validateBundle: () throws -> Void
    private let requestOverride: ((BackgroundCommand) async throws -> BackgroundSnapshot)?
    private var connection: NSXPCConnection?
    private var polling: Task<Void, Never>?
    private var stopped = false
    private var observer: BackgroundClientObserver?
    private var registeredOnThisLaunch = false
    private var startupRepairAttempts = 0
    private var startupRecoveryFinished = false
    private var checkedStartupRegistration = false
    private var receivedSnapshot = false
    private var lastConnectionState: String?
    private let startupBegan = ProcessInfo.processInfo.systemUptime
    private var startupEvents: [String] = []
    private func traceStartup(_ phase: String) {
        guard !receivedSnapshot, startupEvents.count < 50 else { return }
        startupEvents.append(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime - startupBegan, phase))
        record("startup", startupEvents.joined(separator: "\n"))
    }

    init(store: AppStore, service: (any BackgroundRegistration)? = nil,
         validateBundle: @escaping () throws -> Void = { try BackgroundBundle.validate(at: NestBackground.mainBundleURL) },
         request: ((BackgroundCommand) async throws -> BackgroundSnapshot)? = nil) {
        record = service == nil ? BackgroundDiagnostics.record : { _, _ in }
        self.store = store
        self.service = service ?? SystemBackgroundRegistration()
        self.validateBundle = validateBundle
        requestOverride = request
    }
    func start() {
        guard polling == nil else { return }
        stopped = false
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                await self.send(.snapshot)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    @discardableResult private func refreshRegistration() -> Bool {
        do { try validateBundle() }
        catch {
            store?.backgroundApprovalRequired = false
            store?.backgroundServiceIssue = error.localizedDescription
            store?.markBackgroundUnavailable()
            return false
        }
        var registrationError: Error?
        if !registeredOnThisLaunch {
            registeredOnThisLaunch = true
            // notFound describes a missing registration too; it does not prove that
            // the bundled executable is missing. Validate the bundle separately.
            if service.status == .notRegistered || service.status == .notFound {
                do { try service.register() }
                catch { registrationError = error }
            }
        }
        store?.backgroundApprovalRequired = service.status == .requiresApproval
        switch service.status {
        case .enabled:
            store?.loginEnabled = SMAppService.mainApp.status == .enabled
            return true
        case .requiresApproval:
            store?.backgroundServiceIssue = "Allow Nest to run in the background in System Settings."
        case .notRegistered, .notFound:
            if let registrationError {
                NSLog("Nest service registration failed: %@", registrationError.localizedDescription)
                store?.backgroundServiceIssue = "Nest couldn’t start automatic AirDrop sorting. Try again or reopen Nest."
            } else if store?.backgroundServiceIssue == nil {
                store?.backgroundServiceIssue = "Automatic AirDrop sorting is off. Try again to turn it on."
            }
        @unknown default:
            store?.backgroundServiceIssue = "Automatic AirDrop sorting is unavailable. Try again."
        }
        store?.markBackgroundUnavailable()
        return false
    }
    func retry() async {
        guard !stopped, store?.connectingToBackground != true else { return }
        store?.connectingToBackground = true
        defer { store?.connectingToBackground = false }
        registeredOnThisLaunch = false
        startupRepairAttempts = 0
        startupRecoveryFinished = false
        checkedStartupRegistration = false
        receivedSnapshot = false
        connection?.invalidate(); connection = nil
        await send(.snapshot)
    }
    func openSettings() { service.openSettings() }
    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        traceStartup("signing requirement begin")
        let requirement = try NestBackground.requirement(for: NestBackground.helperURL)
        traceStartup("signing requirement complete")
        let connection = NSXPCConnection(machServiceName: NestBackground.name)
        connection.remoteObjectInterface = NSXPCInterface(with: NestBackgroundProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NestBackgroundClientProtocol.self)
        let observer = BackgroundClientObserver { [weak self] in
            Task { @MainActor in
                self?.stop()
                NSApp?.terminate(nil)
            }
        }
        self.observer = observer
        connection.exportedObject = observer
        connection.setCodeSigningRequirement(requirement)
        traceStartup("connection resume begin")
        connection.resume()
        traceStartup("connection resume complete")
        self.connection = connection
        return connection
    }
    func send(_ command: BackgroundCommand) async {
        guard !stopped else { return }
        // Re-read the status after registration and deliver the original command.
        // Starting the service must not swallow a user's Check Access click.
        traceStartup("registration check")
        guard refreshRegistration() else { return }
        do {
            if !checkedStartupRegistration {
                checkedStartupRegistration = true
                // A rebuilt ad-hoc helper may leave an EX_CONFIG job behind. Repair
                // that known failure before waiting for an XPC connection to time out.
                traceStartup("preflight begin")
                if try await service.repairIfFailed() {
                    registeredOnThisLaunch = false
                    guard refreshRegistration() else { return }
                }
            }
            traceStartup("preflight complete")
            let snapshot: BackgroundSnapshot
            if let requestOverride { snapshot = try await requestOverride(command) }
            else { snapshot = try await request(command) }
            guard !stopped else { return }
            traceStartup("snapshot received")
            receivedSnapshot = true
            store?.applyBackgroundSnapshot(snapshot)
            store?.backgroundServiceIssue = nil
        } catch {
            guard !stopped else { return }
            connection?.invalidate(); connection = nil
            lastConnectionState = nil
            if !startupRecoveryFinished {
                startupRepairAttempts += 1
                startupRecoveryFinished = startupRepairAttempts >= 3
                do {
                    // ServiceManagement can still be propagating the new executable's
                    // launch metadata. Bound recovery and back off instead of spinning.
                    try await Task.sleep(for: .milliseconds(200 * (1 << (startupRepairAttempts - 1))))
                    guard !stopped else { return }
                    if try await service.repairIfFailed() {
                        registeredOnThisLaunch = false
                        await send(command)
                        return
                    }
                    startupRecoveryFinished = true
                } catch {
                    startupRecoveryFinished = true
                    record("repair", String(describing: error))
                }
            }
            store?.markBackgroundUnavailable()
            record("connection", String(describing: error))
            NSLog("Nest service connection failed: %@", error.localizedDescription)
            store?.backgroundServiceIssue = "Nest couldn’t start automatic AirDrop sorting. Try again or reopen Nest."
        }
    }
    private func request(_ command: BackgroundCommand) async throws -> BackgroundSnapshot {
        let payload = try JSONEncoder().encode(command)
        let connection = try connect()
        var launchCheck: Task<Void, Never>?
        defer { launchCheck?.cancel() }
        let result: (Data?, String?) = await withCheckedContinuation { continuation in
            let reply = BackgroundResultOnce { data, error in
                continuation.resume(returning: (data, error))
            }
            traceStartup("remote proxy begin")
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                reply.finish(nil, error.localizedDescription)
            } as! NestBackgroundProtocol
            traceStartup("remote proxy complete; perform begin")
            proxy.perform(payload) { data, error in reply.finish(data, error) }
            traceStartup("perform returned")
            if !receivedSnapshot {
                launchCheck = Task { [weak self] in
                    self?.traceStartup("launch monitor started")
                    // launchd may reject a new ad-hoc executable after registration.
                    // Notice that failure promptly instead of waiting ten seconds for XPC.
                    for _ in 0..<30 {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, !self.stopped, !self.receivedSnapshot else { return }
                        if await self.service.hasFailedLaunch() {
                            self.traceStartup("launch failure detected")
                            reply.finish(nil, "Nest’s background helper failed to launch.")
                            return
                        }
                    }
                }
            }
            // Permission requests may legitimately wait for a user response.
            if case .requestDownloadsAccess = command { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                reply.finish(nil, "Nest isn’t responding. Try again or reopen Nest.")
            }
        }
        if let error = result.1 { throw BackgroundConnectionError(error) }
        guard let data = result.0 else { throw BackgroundConnectionError("Nest isn’t responding. Try again or reopen Nest.") }
        let snapshot = try JSONDecoder().decode(BackgroundSnapshot.self, from: data)
        let state = "Connected; monitoring=\(snapshot.monitoring); Downloads denied=\(snapshot.downloadsPermissionDenied)"
        if state != lastConnectionState {
            record("connection", state)
            lastConnectionState = state
        }
        return snapshot
    }
    func stop() {
        stopped = true
        polling?.cancel(); polling = nil
        connection?.invalidate(); connection = nil
        observer = nil
    }
}
