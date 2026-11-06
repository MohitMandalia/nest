import AppKit
import UniformTypeIdentifiers
import Darwin

/// Synchronous, bounded breadcrumbs survive abrupt process termination. macOS owns
/// fatal-signal reporting; avoid running Foundation or Swift from signal handlers.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(
        folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nest", isDirectory: true),
        role: NestBackground.isWorker ? "background" : "app")
    let folder: URL
    private let role: String
    private let limit: Int
    private let lock = NSLock()
    private let session = UUID().uuidString
    private var marker: URL { folder.appendingPathComponent("\(session).session.json") }
    private var logURL: URL { folder.appendingPathComponent("\(role).log") }

    init(folder: URL, role: String, limit: Int = 512 * 1024) {
        self.folder = folder; self.role = role; self.limit = limit
    }

    func record(_ category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Also serialize separate instances of the app, and export snapshots.
            let fd = open(folder.appendingPathComponent("diagnostics.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { return }
            defer { flock(fd, LOCK_UN); close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }
            let cleaned = String(message.replacingOccurrences(of: NSHomeDirectory(), with: "~").prefix(8192))
            let entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "pid": getpid(),
                                       "session": session, "category": category, "message": cleaned]
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0a)
            let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > limit {
                let previous = folder.appendingPathComponent("\(role).previous.log")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                if FileManager.default.fileExists(atPath: logURL.path) { try FileManager.default.moveItem(at: logURL, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { NSLog("Nest diagnostics write failed: %@", error.localizedDescription) }
    }

    func startSession() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasSuffix(".session.json") {
                guard let data = try? Data(contentsOf: url),
                      let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = old["pid"] as? Int32 else { continue }
                if kill(pid, 0) == -1 && errno == ESRCH {
                    record("unexpected-exit", "Previous session had no clean shutdown (crash, force quit, or power loss): \(old)")
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "role": role,
                "started": ISO8601DateFormatter().string(from: Date())])
            try data.write(to: marker, options: .atomic)
            record("lifecycle", "Started; version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development"); build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"); OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        } catch { record("diagnostics-error", error.localizedDescription) }
    }

    func finishSession() {
        record("lifecycle", "Clean shutdown")
        try? FileManager.default.removeItem(at: marker)
    }

    func snapshot(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("diagnostics.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "log" || url.lastPathComponent.hasSuffix(".session.json") {
            try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }
}

enum Diagnostics {
    static func start() {
        DiagnosticLog.shared.startSession()
        NSSetUncaughtExceptionHandler { exception in
            DiagnosticLog.shared.record("uncaught-exception", "\(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }
    }

    static func export(to destination: URL, log: DiagnosticLog = .shared,
                       crashFolders: [URL]? = nil) throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("NestDiagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let report = temporary.appendingPathComponent("Nest Diagnostics")
        try log.snapshot(to: report.appendingPathComponent("Logs"))
        let crashDestination = report.appendingPathComponent("Crash Reports")
        try fm.createDirectory(at: crashDestination, withIntermediateDirectories: true)
        let folders = crashFolders ?? [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                                      URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var candidates: [(URL, Date)] = []
        for folder in folders {
            // Retired reports may be moved into this subfolder by macOS.
            for directory in [folder, folder.appendingPathComponent("Retired")] {
                for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])) ?? [] {
                    guard ["Nest_", "Nest-", "NestBackground_", "NestBackground-"].contains(where: { url.lastPathComponent.hasPrefix($0) }),
                          ["ips", "crash"].contains(url.pathExtension),
                          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, (values.fileSize ?? Int.max) <= 5 * 1024 * 1024,
                          let date = values.contentModificationDate, date > Date().addingTimeInterval(-14 * 86400) else { continue }
                    candidates.append((url, date))
                }
            }
        }
        var copied = 0
        var unavailable = 0
        for (index, candidate) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(5).enumerated() {
            do {
                try fm.copyItem(at: candidate.0, to: crashDestination.appendingPathComponent("\(index + 1)-\(candidate.0.lastPathComponent)"))
                copied += 1
            } catch { unavailable += 1 }
        }
        let summary = """
        Nest diagnostics exported \(ISO8601DateFormatter().string(from: Date()))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development")
        Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")
        Recent crash reports included: \(copied); unavailable during copying: \(unavailable)

        Logs retain up to 2 x 512 KiB per process role (app and background helper).
        Up to five Nest macOS crash reports from the past 14 days are included when available.
        macOS may take a few moments to write a crash report. Export again later if missing.
        Unexpected exits can also mean force quit or power loss; they do not prove a crash.
        No file contents, preferences, or transfer history are included. Error messages can
        contain file names or paths; crash reports can contain system and account details.
        Review this archive before attaching it to your bug report. Nothing is uploaded automatically.
        Please describe what happened, when it happened, and how to reproduce it.
        """
        try summary.write(to: report.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let archive = temporary.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", report.path, archive.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
}

@MainActor
enum DiagnosticsExport {
    private static var exporting = false
    static func show() {
        guard !exporting else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export Nest Diagnostics"
        panel.message = "Save logs and recent crash reports to attach to a bug report. Reports may contain file paths and system details. Review before sharing."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Nest-Diagnostics-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-" )).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        DiagnosticLog.shared.record("diagnostics", "Export requested")
        Task {
            defer { exporting = false }
            do {
                try await Task.detached(priority: .utility) { try Diagnostics.export(to: url) }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                DiagnosticLog.shared.record("diagnostics-error", error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Couldn’t export diagnostics"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
