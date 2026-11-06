import XCTest
import NestCore
import Darwin
@testable import Nest

@MainActor
final class AppStoreTests: XCTestCase {
    func fixture() throws -> (AppStore, URL, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NestTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Downloads"), fallback = root.appendingPathComponent("Default"), person = root.appendingPathComponent("Alex")
        for url in [source, fallback, person] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        store.preferences.source = FolderReference(url: source)
        store.preferences.destination = FolderReference(url: fallback)
        return (store, root, source, fallback, person)
    }
    func testBackgroundRunningDefaultsOnAndRemembersOptOut() throws {
        let (store, root, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(store.keepRunningInBackground)
        store.setBackgroundRunning(false)
        let reopened = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        XCTAssertFalse(reopened.keepRunningInBackground)
        reopened.setBackgroundRunning(true)
        let again = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        XCTAssertTrue(again.keepRunningInBackground)
    }
    func incoming(_ source: URL) throws -> DetectedFile {
        let file = source.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: file)
        let data = Data("0081;abc;sharingd;test".utf8)
        XCTAssertEqual(data.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, data.count, 0, 0) }, 0)
        return DetectedFile(url: file, snapshot: try XCTUnwrap(FileSnapshot.read(file)))
    }
    func settle(_ store: AppStore) async throws {
        for _ in 0..<100 {
            if store.busy.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Routing did not finish")
    }
    func testDefaultRouteAndUndo() async throws {
        let (store, root, source, fallback, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source); store.pending = [file]
        store.route(file); try await settle(store)
        XCTAssertNil(store.error)
        XCTAssertNil(store.preferences.history.first?.sender)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.appendingPathComponent("sample.txt").path))
        XCTAssertTrue(store.pending.isEmpty)
        let transfer = try XCTUnwrap(store.preferences.history.first)
        store.undo(transfer); try await settle(store)
        XCTAssertTrue(store.preferences.history[0].undone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testDefaultRouteAndHistoryPersist() async throws {
        let (store, root, source, fallback, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source); store.pending = [file]
        store.route(file); try await settle(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.appendingPathComponent("sample.txt").path))
        let restored = AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false)
        XCTAssertEqual(restored.preferences.history.count, 1)
        XCTAssertTrue(restored.preferences.pendingPaths.isEmpty)
    }
    func testMissingDestinationLeavesFileAndPendingQueue() async throws {
        let (store, root, source, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: destination)
        let file = try incoming(source); store.pending = [file]
        store.route(file); try await settle(store)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(store.preferences.history.isEmpty)
    }

    func testChangedQueuedFileWaitsForLatestContentsToSettleBeforeMoving() async throws {
        let (store, root, source, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source)
        store.pending = [file]
        func write(_ contents: String) throws {
            let handle = try FileHandle(forWritingTo: file.url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.close()
        }
        try write("first update")
        let start = Date()
        store.route(file, now: start)
        XCTAssertTrue(store.busy.isEmpty)
        XCTAssertEqual(store.pending.first?.snapshot, FileSnapshot.read(file.url))
        store.route(file, now: start.addingTimeInterval(4))
        XCTAssertTrue(store.busy.isEmpty)
        try write("final contents")
        store.route(file, now: start.addingTimeInterval(7))
        store.route(file, now: start.addingTimeInterval(10))
        XCTAssertTrue(store.busy.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        store.route(file, now: start.addingTimeInterval(16))
        try await settle(store)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.preferences.history.count, 1)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sample.txt")), "final contents")
    }

    func testRetryAfterFailedMoveRevalidatesChangedFileAndResumesAutomaticRouting() async throws {
        let (store, root, source, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source)
        store.pending = [file]
        try FileManager.default.removeItem(at: destination)
        store.route(file); try await settle(store)
        XCTAssertNotNil(store.pending.first?.failure)
        store.error = nil
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.write(contentsOf: Data("updated contents".utf8))
        try handle.close()
        store.route(try XCTUnwrap(store.pending.first))
        XCTAssertTrue(store.busy.isEmpty)
        XCTAssertNil(store.pending.first?.failure)
        XCTAssertEqual(store.pending.first?.snapshot, FileSnapshot.read(file.url))
        for _ in 0..<110 {
            store.routePendingFiles()
            if !store.busy.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle(store)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sample.txt")), "updated contents")
    }
    func testDownloadsConsentPersistsOnlyAfterSuccessfulAccess() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("consent.json")
        let store = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source)
        XCTAssertNil(store.preferences.source)
        await store.requestDownloadsAccess()
        XCTAssertNil(store.error)
        XCTAssertFalse(store.requestingDownloadsAccess)
        XCTAssertEqual(store.preferences.source?.path, source.path)
        XCTAssertNil(store.preferences.source?.bookmark)
        let restored = AppStore(storageURL: path, startMonitor: false)
        XCTAssertEqual(restored.preferences.source?.path, source.path)
    }
    func testDeniedDownloadsConsentDoesNotConfigureOrLosePendingFiles() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("denied.json"), startMonitor: false,
                             downloadsDirectory: source, checkDownloadsAccess: { _ in throw CocoaError(.fileReadNoPermission) })
        let file = try incoming(source); store.pending = [file]
        await store.requestDownloadsAccess()
        XCTAssertNil(store.preferences.source)
        XCTAssertTrue(store.downloadsPermissionDenied)
        XCTAssertFalse(store.requestingDownloadsAccess)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.downloadsAccessIssue?.contains("System Settings") == true)
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testCheckingExistingDownloadsAccessPreservesQueue() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("existing.json"), startMonitor: false, downloadsDirectory: source)
        await store.requestDownloadsAccess()
        let file = try incoming(source); store.pending = [file]
        await store.requestDownloadsAccess()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.preferences.pendingPaths, [file.url.path])
    }

    func testLegacyContactSettingsDoNotBlockDefaultRouting() async throws {
        let (_, root, source, destination, person) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var oldPreferences = Preferences()
        oldPreferences.source = FolderReference(url: source)
        oldPreferences.destination = FolderReference(url: destination)
        oldPreferences.routes = [PersonRoute(name: "Alex", folder: FolderReference(url: person))]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldPreferences)) as? [String: Any])
        json["askSender"] = true
        let path = root.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let store = AppStore(storageURL: path, startMonitor: false)
        let file = try incoming(source); store.pending = [file]
        store.routePendingFiles(); try await settle(store)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sample.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: person.appendingPathComponent("sample.txt").path))
        XCTAssertEqual(store.preferences.routes.first?.name, "Alex")
    }

    func waitForWatcher(_ store: AppStore) async throws {
        for _ in 0..<100 {
            if !store.checkingDownloadsAccess { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Watcher startup did not finish")
    }
    func testEngineInitializationWaitsForUIConnectionBeforeRequestingAccess() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AccessProbe()
        let store = AppStore(storageURL: root.appendingPathComponent("fresh.json"), downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        XCTAssertEqual(probe.calls, 0)
        XCTAssertFalse(store.checkingDownloadsAccess)
        XCTAssertFalse(store.monitoring)
        XCTAssertNil(store.error)
    }
    func testFirstUIConnectionAutomaticallyRequestsDownloadsOnlyOnce() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AccessProbe()
        let path = root.appendingPathComponent("automatic.json")
        let store = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        let requested = await store.requestInitialDownloadsAccessIfNeeded()
        XCTAssertTrue(requested)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(store.preferences.source?.path, source.path)
        XCTAssertTrue(store.preferences.downloadsAccessRequested == true)
        await store.requestInitialDownloadsAccessIfNeeded()
        let reopened = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                                checkDownloadsAccess: { try probe.check($0) })
        await reopened.requestInitialDownloadsAccessIfNeeded()
        XCTAssertEqual(probe.calls, 1)
    }
    func testAutomaticRequestDoesNotRepeatSavedDenialAndAllowsExplicitRetry() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AccessProbe(failFirst: true)
        let path = root.appendingPathComponent("automatic-denial.json")
        let store = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        await store.requestInitialDownloadsAccessIfNeeded()
        XCTAssertTrue(store.downloadsPermissionDenied)
        let reopened = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                                checkDownloadsAccess: { try probe.check($0) })
        await reopened.requestInitialDownloadsAccessIfNeeded()
        XCTAssertEqual(probe.calls, 1)
        await reopened.requestDownloadsAccess()
        XCTAssertEqual(probe.calls, 2)
        XCTAssertFalse(reopened.downloadsPermissionDenied)
        XCTAssertEqual(reopened.preferences.source?.path, source.path)
    }
    func testGrantedAccessReconnectsWithoutAnotherRequest() async throws {
        let (original, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        original.save()
        let probe = AccessProbe()
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        defer { store.stopWatching() }
        XCTAssertTrue(store.checkingDownloadsAccess)
        try await waitForWatcher(store)
        XCTAssertTrue(store.monitoring)
        XCTAssertNil(store.downloadsAccessIssue)
        await store.requestDownloadsAccess()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertTrue(store.monitoring)
        XCTAssertNil(store.error)
    }
    func testDeniedAccessPersistsAndDoesNotRequestAgainOnLaunch() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("denial.json")
        let probe = AccessProbe(failFirst: true)
        let first = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        await first.requestDownloadsAccess()
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(first.downloadsPermissionDenied)
        XCTAssertNil(first.error)
        let reopened = AppStore(storageURL: path, downloadsDirectory: source,
                                checkDownloadsAccess: { try probe.check($0) })
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(reopened.downloadsPermissionDenied)
        XCTAssertNotNil(reopened.downloadsAccessIssue)
        XCTAssertFalse(reopened.monitoring)
        XCTAssertFalse(reopened.checkingDownloadsAccess)
        XCTAssertNil(reopened.error)
    }
    func testExplicitRetryClearsSavedDenial() async throws {
        let (_, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("retry.json")
        let probe = AccessProbe(failFirst: true)
        let store = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source,
                             checkDownloadsAccess: { try probe.check($0) })
        await store.requestDownloadsAccess()
        XCTAssertTrue(store.downloadsPermissionDenied)
        await store.requestDownloadsAccess()
        XCTAssertEqual(probe.calls, 2)
        XCTAssertFalse(store.downloadsPermissionDenied)
        XCTAssertNil(store.downloadsAccessIssue)
        let reopened = AppStore(storageURL: path, startMonitor: false)
        XCTAssertFalse(reopened.downloadsPermissionDenied)
        XCTAssertEqual(reopened.preferences.source?.path, source.path)
    }
    func testRevokedAccessIsInlineAndPreservesSavedQueue() throws {
        let (store, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let queuedPath = source.appendingPathComponent("pending.txt").path
        store.preferences.pendingPaths = [queuedPath]
        store.handleDownloadsAccessFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        XCTAssertTrue(store.downloadsPermissionDenied)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.preferences.pendingPaths, [queuedPath])
        let reopened = AppStore(storageURL: root.appendingPathComponent("preferences.json"))
        XCTAssertTrue(reopened.downloadsPermissionDenied)
        XCTAssertEqual(reopened.preferences.pendingPaths, [queuedPath])
        XCTAssertFalse(reopened.checkingDownloadsAccess)
        XCTAssertNil(reopened.error)
    }
    func testRetryAfterDeniedRelaunchRestoresPendingQueue() async throws {
        let (original, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source)
        original.preferences.paused = true
        original.preferences.pendingPaths = [file.url.path]
        original.handleDownloadsAccessFailure(CocoaError(.fileReadNoPermission))
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), downloadsDirectory: source)
        defer { store.stopWatching() }
        XCTAssertTrue(store.downloadsPermissionDenied)
        await store.requestDownloadsAccess()
        try await waitForWatcher(store)
        XCTAssertTrue(store.monitoring)
        XCTAssertFalse(store.downloadsPermissionDenied)
        XCTAssertEqual(store.pending.map { $0.url.path }, [file.url.path])
        XCTAssertEqual(store.preferences.pendingPaths, [file.url.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testRestoredPendingFileSettlesAgainBeforeAutomaticMove() async throws {
        let (original, root, source, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try incoming(source)
        original.pending = [file]
        original.save()
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"), downloadsDirectory: source)
        defer { store.stopWatching() }
        try await waitForWatcher(store)
        XCTAssertEqual(store.pending.map(\.id), [file.id])
        XCTAssertTrue(store.busy.isEmpty)
        XCTAssertTrue(store.preferences.history.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        // Resume writing after relaunch; the restored fingerprint must refresh.
        let finalContents = Data("the transfer finished after Nest relaunched".utf8)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: finalContents)
        try handle.close()
        for _ in 0..<160 {
            if !store.preferences.history.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(store.error)
        XCTAssertEqual(store.preferences.history.count, 1)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(file.url.lastPathComponent)), finalContents)
    }
    func testGrantIsRememberedEvenWhenDestinationIsUnavailable() async throws {
        let (_, root, source, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("offline-destination.json")
        let store = AppStore(storageURL: path, startMonitor: false, downloadsDirectory: source)
        store.preferences.destination = FolderReference(url: destination)
        try FileManager.default.removeItem(at: destination)
        await store.requestDownloadsAccess()
        XCTAssertNil(store.error)
        XCTAssertFalse(store.downloadsPermissionDenied)
        let reopened = AppStore(storageURL: path, startMonitor: false)
        XCTAssertEqual(reopened.preferences.source?.path, source.path)
        XCTAssertFalse(reopened.downloadsPermissionDenied)
    }
    func testUnavailableDownloadsAtStartupDoesNotShowAlertOrMarkDenial() async throws {
        let (original, root, source, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var ref = FolderReference(url: source.appendingPathComponent("missing"))
        ref.bookmark = nil
        original.preferences.source = ref
        original.save()
        let store = AppStore(storageURL: root.appendingPathComponent("preferences.json"))
        defer { store.stopWatching() }
        try await waitForWatcher(store)
        XCTAssertFalse(store.monitoring)
        XCTAssertFalse(store.downloadsPermissionDenied)
        XCTAssertNotNil(store.downloadsAccessIssue)
        XCTAssertNil(store.error)
    }

}


private final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func check(_ url: URL) throws {
        lock.lock()
        count += 1
        let deny = failFirst && count == 1
        lock.unlock()
        if deny { throw CocoaError(.fileReadNoPermission) }
    }
}
