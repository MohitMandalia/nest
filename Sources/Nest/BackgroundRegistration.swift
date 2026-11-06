import Foundation
import ServiceManagement
import CoreServices

@MainActor
protocol BackgroundRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func openSettings()
    func repairIfFailed() async throws -> Bool
    func hasFailedLaunch() async -> Bool
}

extension BackgroundRegistration {
    func repairIfFailed() async throws -> Bool { false }
    func hasFailedLaunch() async -> Bool { false }
}

@MainActor
struct SystemBackgroundRegistration: BackgroundRegistration {
    private let service = SMAppService.agent(plistName: NestBackground.plist)
    var status: SMAppService.Status { service.status }
    func register() throws {
        do {
            // Refresh LaunchServices' app metadata before ServiceManagement derives
            // the helper's launch constraint, especially after an ad-hoc rebuild.
            let result = LSRegisterURL(NestBackground.mainBundleURL as CFURL, true)
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
            try service.register()
            BackgroundDiagnostics.record("registration", message: "Registered; status=\(service.status.rawValue)")
        } catch {
            BackgroundDiagnostics.record("registration", message: String(describing: error))
            throw error
        }
    }
    func repairIfFailed() async throws -> Bool {
        guard service.status == .enabled else { return false }
        let report = await Task.detached(priority: .utility) { BackgroundLaunchReport.read() }.value
        BackgroundDiagnostics.record("launch", message: report)
        let currentBuild = Bundle(url: NestBackground.mainBundleURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard BackgroundLaunchReport.canRepair(report, currentBuild: currentBuild) else { return false }
        // Refresh a failed or outdated idle job. Never replace an active mover.
        try await service.unregister()
        try register()
        BackgroundDiagnostics.record("registration", message: "Repaired failed job; status=\(service.status.rawValue)")
        return true
    }
    func retireIdleService() async {
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        let report = await Task.detached(priority: .utility) { BackgroundLaunchReport.read() }.value
        let currentBuild = Bundle(url: NestBackground.mainBundleURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard BackgroundLaunchReport.canRepair(report, currentBuild: currentBuild) else { return }
        do {
            try await service.unregister()
            BackgroundDiagnostics.record("registration", message: "Removed idle helper registration for menu bar mode")
        } catch { BackgroundDiagnostics.record("registration", message: error.localizedDescription) }
    }
    func hasFailedLaunch() async -> Bool {
        BackgroundDiagnostics.record("launch-check", message: "Checking")
        let report = await Task.detached(priority: .utility) { BackgroundLaunchReport.read() }.value
        BackgroundDiagnostics.record("launch-check", message: report)
        return BackgroundLaunchReport.canRepair(report)
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum BackgroundBundle {
    static func validate(at app: URL) throws {
        let plist = app.appendingPathComponent("Contents/Library/LaunchAgents/\(NestBackground.plist)")
        let helper = app.appendingPathComponent("Contents/MacOS/NestBackground")
        guard FileManager.default.fileExists(atPath: plist.path),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BackgroundConnectionError("Nest’s installation is incomplete. Reinstall Nest to restore automatic AirDrop sorting.")
        }
    }
}

struct BackgroundConnectionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}


enum BackgroundLaunchReport {
    static func read() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(NestBackground.name)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch { return error.localizedDescription }
    }
    static func canRepair(_ report: String, currentBuild: String? = nil) -> Bool {
        let lines = report.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(where: { $0.hasPrefix("pid =") }),
              !lines.contains("state = running") else { return false }
        let versionPrefix = "parent bundle version = "
        if let currentBuild, let versionLine = lines.first(where: { $0.hasPrefix(versionPrefix) }),
           String(versionLine.dropFirst(versionPrefix.count)) != currentBuild { return true }
        let signingFailure = lines.contains("last exit reason = OS_REASON_CODESIGNING")
        let configurationFailure = lines.contains(where: { $0.hasPrefix("last exit code = 78") })
        return lines.contains("job state = spawn failed") && (signingFailure || configurationFailure)
    }
}

enum BackgroundDiagnostics {
    static func record(_ phase: String, message: String) {
        DiagnosticLog.shared.record(phase, message)
    }
}
