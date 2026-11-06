import XCTest
import AppKit
import NestCore
@testable import Nest

@MainActor
final class BackgroundTests: XCTestCase {
    private func fixture() throws -> (AppStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NestBackgroundTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false, downloadsDirectory: source)
        store.preferences.source = FolderReference(url: source)
        return (store, root, source)
    }
    func testWindowClientDoesNotStartScannerOrWriteWorkerPreferences() throws {
        let (worker, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        worker.preferences.paused = true
        worker.save()
        let path = root.appendingPathComponent("preferences.json")
        let saved = try Data(contentsOf: path)
        // Exercise the same mode selection as NestApp, including ad-hoc builds.
        let client = AppStore(storageURL: path, downloadsDirectory: source, remote: true)
        XCTAssertTrue(client.usesBackgroundService)
        client.startWatching()
        XCTAssertFalse(client.checkingDownloadsAccess)
        XCTAssertFalse(client.monitoring)
        client.preferences.paused = false
        client.save()
        XCTAssertEqual(try Data(contentsOf: path), saved)
    }
    func testSnapshotRoundTripRestoresHistoryPendingAndDenialWithoutStartingWatcher() throws {
        let (worker, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("example.txt")
        try Data("example".utf8).write(to: file)
        var pending = DetectedFile(url: file, snapshot: try XCTUnwrap(FileSnapshot.read(file)))
        pending.failure = "Destination is offline"
        worker.pending = [pending]
        worker.handleDownloadsAccessFailure(CocoaError(.fileReadNoPermission))
        worker.preferences.history = [Transfer(originalPath: file.path, currentPath: "/tmp/moved.txt", sender: nil, destination: FolderReference(url: root))]
        let data = try JSONEncoder().encode(worker.backgroundSnapshot)
        let client = AppStore(storageURL: root.appendingPathComponent("client.json"), remote: true)
        client.applyBackgroundSnapshot(try JSONDecoder().decode(BackgroundSnapshot.self, from: data))
        XCTAssertTrue(client.downloadsPermissionDenied)
        XCTAssertEqual(client.pending.first?.failure, "Destination is offline")
        XCTAssertEqual(client.preferences.history.count, 1)
        XCTAssertFalse(client.monitoring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("client.json").path))
    }
    func testOnlyWorkerExecutesValidatedCommands() async throws {
        let (worker, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = BackgroundCommandHandler(store: worker)
        await handler.perform(.togglePause)
        XCTAssertTrue(worker.preferences.paused)
        await handler.perform(.setBackgroundRunning(false))
        XCTAssertFalse(worker.keepRunningInBackground)
        await handler.perform(.setDestination(FolderReference(url: source)))
        XCTAssertNil(worker.preferences.destination)
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await handler.perform(.setDestination(FolderReference(url: destination)))
        XCTAssertEqual(worker.preferences.destination?.path, destination.path)
        let before = worker.preferences.history
        await handler.perform(.route("/arbitrary/path"))
        await handler.perform(.undo(UUID()))
        XCTAssertEqual(worker.preferences.history.count, before.count)
        XCTAssertTrue(worker.busy.isEmpty)
        let restored = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        XCTAssertFalse(restored.keepRunningInBackground)
        XCTAssertEqual(restored.preferences.destination?.path, destination.path)
    }
    func testExitingBeforeWatcherRestoresQueuePreservesSavedPendingPaths() throws {
        let (worker, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        worker.preferences.pendingPaths = [source.appendingPathComponent("waiting.txt").path]
        // Write the same persisted format a previous worker leaves behind.
        let path = root.appendingPathComponent("preferences.json")
        try JSONEncoder().encode(worker.preferences).write(to: path)
        let relaunched = AppStore(storageURL: path, startMonitor: false)
        relaunched.setBackgroundRunning(false)
        relaunched.stopWatching()
        relaunched.save()
        let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: path))
        XCTAssertEqual(saved.pendingPaths, worker.preferences.pendingPaths)
    }
    func testAppDelegateSupportsFrameworkDefaultInitializer() {
        let delegateType: NSObject.Type = NestAppDelegate.self
        let delegate = delegateType.init()
        XCTAssertTrue(delegate is NestAppDelegate)
    }
    func testFirstSnapshotStartsAutomaticDownloadsRequest() async throws {
        let (_, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = expectation(description: "Downloads requested after UI connects")
        let store = AppStore(storageURL: root.appendingPathComponent("fresh.json"), startMonitor: false,
                             downloadsDirectory: source, checkDownloadsAccess: { _ in requested.fulfill() })
        defer { store.stopWatching() }
        let handler = BackgroundCommandHandler(store: store)
        await handler.perform(.snapshot)
        await fulfillment(of: [requested], timeout: 2)
        for _ in 0..<100 {
            if store.monitoring { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.monitoring)
        XCTAssertEqual(store.preferences.source?.path, source.path)
    }
    func testLocalWindowCloseRespectsBackgroundPreference() throws {
        let (store, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = NestAppDelegate(dump: nil, store: store)
        XCTAssertFalse(store.usesBackgroundService)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        store.preferences.keepRunningInBackground = false
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
    func testLocalShutdownWaitsForInFlightRoutingBeforeSaving() async throws {
        let (store, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.preferences.keepRunningInBackground = false
        store.busy = ["in-flight-transfer"]
        let finished = expectation(description: "Safe local shutdown")
        let delegate = NestAppDelegate(dump: nil, store: store, replyToTermination: { allowed in
            XCTAssertTrue(allowed)
            XCTAssertTrue(store.busy.isEmpty)
            finished.fulfill()
        })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertFalse(store.acceptingTransfers)
        store.busy.removeAll()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path))
    }
    func testClosingMainWindowKeepsAppAvailableToReopen() {
        let delegate = NestAppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
    func testHelperOpenWindowRequestReachesMainProcess() async {
        let shown = expectation(forNotification: .nestOpenMainWindow, object: nil)
        let replied = expectation(description: "Open-window request acknowledged")
        let observer = BackgroundClientObserver { XCTFail("Opening the window must not stop the client") }
        observer.showMainWindow { replied.fulfill() }
        await fulfillment(of: [shown, replied], timeout: 2)
    }
    func testBackgroundLifetimeAfterWindowDisconnect() {
        XCTAssertFalse(BackgroundLifetime.shouldStop(backgroundEnabled: true, clients: 0))
        XCTAssertFalse(BackgroundLifetime.shouldStop(backgroundEnabled: false, clients: 1))
        XCTAssertTrue(BackgroundLifetime.shouldStop(backgroundEnabled: false, clients: 0))
    }
    func testShutdownRejectsNewMovesWithoutDroppingPendingFiles() throws {
        let (worker, root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("pending.txt")
        try Data("keep me".utf8).write(to: file)
        let pending = DetectedFile(url: file, snapshot: try XCTUnwrap(FileSnapshot.read(file)))
        worker.pending = [pending]
        worker.acceptingTransfers = false
        worker.route(pending)
        XCTAssertTrue(worker.busy.isEmpty)
        XCTAssertEqual(worker.pending.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let dump = DumpStore(folder: root.appendingPathComponent("Dump"))
        dump.acceptingTransfers = false
        dump.addFiles([file])
        XCTAssertFalse(dump.isTransferring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dump.folder.path))
    }
}
