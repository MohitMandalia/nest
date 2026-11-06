import XCTest
@testable import Nest

final class DiagnosticsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testLogsRotateAndRedactHomeWithoutBreakingJSONLines() throws {
        let log = DiagnosticLog(folder: root, role: "test", limit: 1024)
        for index in 0..<30 { log.record("test", "\(index): \(NSHomeDirectory())/secret\nsecond line") }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        XCTAssertEqual(files.count, 2)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 1024)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(NSHomeDirectory()))
            for line in text.split(separator: "\n") {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
            }
        }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("test.log")).contains("29:"))
    }

    func testParallelWritersPreserveEveryEntry() throws {
        let first = DiagnosticLog(folder: root, role: "test")
        let second = DiagnosticLog(folder: root, role: "test")
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            (index.isMultiple(of: 2) ? first : second).record("parallel", String(index))
        }
        let lines = try String(contentsOf: root.appendingPathComponent("test.log")).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        let messages = try lines.map { line -> String in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(json["message"] as? String)
        }
        XCTAssertEqual(Set(messages).count, 100)
    }

    func testSessionMarksCleanShutdownAndDetectsDeadProcess() throws {
        let stale = root.appendingPathComponent("stale.session.json")
        // Darwin's PID range is far below this value.
        try JSONSerialization.data(withJSONObject: ["pid": Int32.max, "role": "app"]).write(to: stale)
        let log = DiagnosticLog(folder: root, role: "test")
        log.startSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("test.log")).contains("unexpected-exit"))
        log.finishSession()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".session.json") })
    }

    func testExportContainsLogsAndOnlyRecentNestCrashReports() throws {
        let logs = root.appendingPathComponent("logs")
        let crashes = root.appendingPathComponent("crashes")
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        for name in ["Nest_recent.ips", "NestBackground_recent.crash", "OtherApp_recent.ips", "Nest_old.ips", "Nest_notes.txt"] {
            try name.write(to: crashes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 86400)], ofItemAtPath: crashes.appendingPathComponent("Nest_old.ips").path)
        let log = DiagnosticLog(folder: logs, role: "test")
        log.record("test", "export breadcrumb")
        let archive = root.appendingPathComponent("report.zip")
        try Diagnostics.export(to: archive, log: log, crashFolders: [crashes])
        let unpack = root.appendingPathComponent("unpacked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, unpack.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let report = unpack.appendingPathComponent("Nest Diagnostics")
        XCTAssertTrue(try String(contentsOf: report.appendingPathComponent("Logs/test.log")).contains("export breadcrumb"))
        let exported = try FileManager.default.contentsOfDirectory(atPath: report.appendingPathComponent("Crash Reports").path)
        XCTAssertEqual(exported.count, 2)
        XCTAssertTrue(exported.contains { $0.hasSuffix("Nest_recent.ips") })
        XCTAssertTrue(exported.contains { $0.hasSuffix("NestBackground_recent.crash") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.appendingPathComponent("README.txt").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("NestDiagnostics-") })
    }
}
