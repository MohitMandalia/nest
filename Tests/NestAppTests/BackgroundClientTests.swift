import XCTest
import ServiceManagement
@testable import Nest

@MainActor
private final class RegistrationStub: BackgroundRegistration {
    var status: SMAppService.Status = .notFound
    var registrations = 0
    var settingsOpened = 0
    var repairs = 0
    var canRepair = false
    var error: Error?
    func register() throws {
        registrations += 1
        if let error { throw error }
        status = .enabled
    }
    func openSettings() { settingsOpened += 1 }
    func repairIfFailed() async throws -> Bool {
        repairs += 1
        return canRepair
    }
}

@MainActor
final class BackgroundClientTests: XCTestCase {
    private func store() -> (AppStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NestClientTests-\(UUID().uuidString)")
        return (AppStore(storageURL: root.appendingPathComponent("preferences.json"), startMonitor: false), root)
    }
    func testCheckAccessRegistersNotFoundServiceAndDeliversOriginalClick() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        var requestedAccess = false
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { command in
            if case .requestDownloadsAccess = command { requestedAccess = true }
            return store.backgroundSnapshot
        })
        await client.send(.requestDownloadsAccess)
        XCTAssertEqual(registration.registrations, 1)
        XCTAssertTrue(requestedAccess)
        XCTAssertNil(store.backgroundServiceIssue)
    }
    func testRetryRegistersNotFoundServiceAndFetchesItsState() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            requests += 1
            var snapshot = store.backgroundSnapshot
            snapshot.monitoring = true
            return snapshot
        })
        await client.retry()
        XCTAssertEqual(registration.registrations, 1)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(store.monitoring)
        XCTAssertFalse(store.connectingToBackground)
    }
    func testFailedRegistrationShowsUserActionAndRetryReallyAttemptsAgain() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.error = BackgroundConnectionError("Registration rejected by macOS")
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            requests += 1
            return store.backgroundSnapshot
        })
        await client.retry()
        XCTAssertEqual(registration.registrations, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(store.backgroundServiceIssue?.contains("automatic AirDrop sorting") == true)
        XCTAssertFalse(store.backgroundServiceIssue?.contains("Registration rejected by macOS") == true)
        registration.error = nil
        await client.retry()
        XCTAssertEqual(registration.registrations, 2)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(store.backgroundServiceIssue)
    }
    func testApprovalRequiredIsShownInsteadOfSilentlyDiscardingCheckAccess() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .requiresApproval
        var stale = store.backgroundSnapshot
        stale.checkingDownloadsAccess = true
        stale.requestingDownloadsAccess = true
        store.applyBackgroundSnapshot(stale)
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            requests += 1
            return store.backgroundSnapshot
        })
        await client.send(.requestDownloadsAccess)
        XCTAssertEqual(registration.registrations, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(store.backgroundApprovalRequired)
        XCTAssertFalse(store.checkingDownloadsAccess)
        XCTAssertFalse(store.requestingDownloadsAccess)
        XCTAssertNotNil(store.backgroundServiceIssue)
        client.openSettings()
        XCTAssertEqual(registration.settingsOpened, 1)
        registration.status = .enabled
        await client.send(.requestDownloadsAccess)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(store.backgroundApprovalRequired)
        XCTAssertNil(store.backgroundServiceIssue)
    }
    func testRetryRecoversAfterConnectionFailure() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        var failed = true
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            if failed { throw BackgroundConnectionError("Disconnected") }
            return store.backgroundSnapshot
        })
        await client.send(.snapshot)
        XCTAssertTrue(store.backgroundServiceIssue?.contains("Try again or reopen Nest") == true)
        failed = false
        await client.retry()
        XCTAssertNil(store.backgroundServiceIssue)
        XCTAssertFalse(store.connectingToBackground)
    }
    func testKnownFailedLaunchIsRepairedBeforeFirstRequestWithoutTimeout() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        registration.canRepair = true
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { command in
            guard case .requestDownloadsAccess = command else { throw BackgroundConnectionError("Wrong command") }
            XCTAssertEqual(registration.repairs, 1, "Repair must happen before the first connection attempt")
            requests += 1
            return store.backgroundSnapshot
        })
        await client.send(.requestDownloadsAccess)
        XCTAssertEqual(registration.repairs, 1)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(store.backgroundServiceIssue)
    }
    func testFailureAfterRefreshingStaleRegistrationStillGetsOneRepair() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        registration.canRepair = true
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            requests += 1
            if requests == 1 { throw BackgroundConnectionError("Launch constraint violation after registration refresh") }
            return store.backgroundSnapshot
        })
        await client.send(.snapshot)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(registration.repairs, 2)
        XCTAssertNil(store.backgroundServiceIssue)
    }
    func testRepeatedLaunchFailuresHaveBoundedRecovery() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        registration.canRepair = true
        var requests = 0
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            requests += 1
            throw BackgroundConnectionError("Launch metadata still unavailable")
        })
        await client.send(.snapshot)
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(registration.repairs, 4)
        await client.send(.snapshot)
        XCTAssertEqual(registration.repairs, 4, "Polling must not restart exhausted recovery")
        XCTAssertNotNil(store.backgroundServiceIssue)
    }
    func testHealthyStartupIsCheckedOnceAcrossPollingRequests() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in store.backgroundSnapshot })
        await client.send(.snapshot)
        await client.send(.snapshot)
        XCTAssertEqual(registration.repairs, 1)
        await client.retry()
        XCTAssertEqual(registration.repairs, 2)
    }
    func testFailedRepairIsNotRepeatedByPolling() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        registration.status = .enabled
        let client = BackgroundClient(store: store, service: registration, validateBundle: {}, request: { _ in
            throw BackgroundConnectionError("Not connected")
        })
        await client.send(.snapshot)
        await client.send(.snapshot)
        // One preflight check, then one check for a failure that occurred during connection.
        XCTAssertEqual(registration.repairs, 2)
        await client.retry()
        XCTAssertEqual(registration.repairs, 4)
    }
    func testOnlyConfigurationFailureWithoutLiveProcessIsSafeToRepair() {
        let failed = "state = spawn scheduled\nlast exit code = 78: EX_CONFIG\njob state = spawn failed"
        XCTAssertTrue(BackgroundLaunchReport.canRepair(failed))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(failed + "\npid = 123"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(failed + "\nstate = running"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair("last exit code = 1\njob state = spawn failed"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair("Could not find service"))
    }
    func testImmediateSigningFailureIsRecognizedBeforeEX_CONFIGAppears() {
        // Captured from the first failed launch; the numeric exit code appears later.
        let failed = "state = spawn scheduled\nlast exit reason = OS_REASON_CODESIGNING\njob state = spawn failed"
        XCTAssertTrue(BackgroundLaunchReport.canRepair(failed))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(failed + "\npid = 123"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(failed + "\nstate = running"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair("last exit reason = OS_REASON_CODESIGNING\njob state = running"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair("last exit reason = OS_REASON_OTHER\njob state = spawn failed"))
    }
    func testOutdatedIdleRegistrationIsRefreshedBeforeAnyLaunchFailure() {
        let idle = "state = not running\nparent bundle version = 15\nlast exit code = 0\njob state = exited"
        XCTAssertTrue(BackgroundLaunchReport.canRepair(idle, currentBuild: "16"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(idle, currentBuild: "15"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(idle + "\npid = 123", currentBuild: "16"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair(idle + "\nstate = running", currentBuild: "16"))
        XCTAssertFalse(BackgroundLaunchReport.canRepair("Could not find service", currentBuild: "16"))
    }
    func testMissingExecutableDoesNotAttemptRegistration() async {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = RegistrationStub()
        let client = BackgroundClient(store: store, service: registration, validateBundle: {
            try BackgroundBundle.validate(at: root)
        })
        await client.retry()
        XCTAssertEqual(registration.registrations, 0)
        XCTAssertEqual(store.backgroundServiceIssue, "Nest’s installation is incomplete. Reinstall Nest to restore automatic AirDrop sorting.")
    }
}
