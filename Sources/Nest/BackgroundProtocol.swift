import AppKit
import NestCore
import Security
import Darwin

// Only the worker owns preferences and filesystem mutations. The window is a client.
enum BackgroundCommand: Codable {
    case snapshot, requestDownloadsAccess, setDestination(FolderReference)
    case togglePause, setBackgroundRunning(Bool), route(String), dismiss(String), undo(UUID)
    case openDump, quitAll
}

struct BackgroundSnapshot: Codable {
    var preferences: Preferences
    var pending: [DetectedFile]
    var busy: Set<String>
    var monitoring: Bool
    var checkingDownloadsAccess: Bool
    var requestingDownloadsAccess: Bool
    var downloadsPermissionDenied: Bool
    var downloadsAccessIssue: String?
    var error: String?
    var notice: String?
}

@objc protocol NestBackgroundProtocol {
    func perform(_ data: Data, reply: @escaping (Data?, String?) -> Void)
}

@objc protocol NestBackgroundClientProtocol {
    func showMainWindow(reply: @escaping () -> Void)
    func serviceWillStop(reply: @escaping () -> Void)
}

enum NestBackground {
    static let usesSeparateService: Bool = {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.executableURL! as CFURL, [], &code) == errSecSuccess,
              let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information else { return false }
        return (information as NSDictionary)[kSecCodeInfoTeamIdentifier] as? String != nil
    }()
    static let name = "com.nest.local.background"
    static let plist = "com.nest.local.background.plist"
    static var isWorker: Bool { CommandLine.arguments.contains("--nest-background-worker") }
    static var mainBundleURL: URL {
        guard isWorker else { return Bundle.main.bundleURL }
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&path, &size)
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var helperURL: URL { mainBundleURL.appendingPathComponent("Contents/MacOS/NestBackground") }
    // Pin both sides of XPC to the code actually bundled with this build. Never trust
    // an identifier alone, which another local program could copy.
    static func requirement(for bundle: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        let flags = SecCSFlags(rawValue: 0)
        guard SecStaticCodeCreateWithPath(bundle as CFURL, flags, &code) == errSecSuccess,
              let code,
              SecCodeCopyDesignatedRequirement(code, flags, &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, flags, &text) == errSecSuccess,
              let text else { throw CocoaError(.executableNotLoadable) }
        return text as String
    }
}

enum BackgroundLifetime {
    static func shouldStop(backgroundEnabled: Bool, clients: Int) -> Bool {
        !backgroundEnabled && clients == 0
    }
}

// A disconnected peer and a reply can race with the shutdown deadline.
final class BackgroundReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (() -> Void)?
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func finish() {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?()
    }
}

// Every request must complete once, including when timeout and XPC failure race.
final class BackgroundResultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, String?) -> Void)?
    init(_ callback: @escaping (Data?, String?) -> Void) { self.callback = callback }
    func finish(_ data: Data?, _ error: String?) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(data, error)
    }
}
