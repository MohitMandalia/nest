import XCTest
import AppKit
import NestCore
@testable import Nest

@MainActor
final class DumpStoreTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NestDumpStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func waitForTransfer(_ dump: DumpStore) async throws {
        for _ in 0..<200 {
            if !dump.isTransferring { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Dump transfer did not finish")
    }
    func testDumpIsCreatedLazilyAndIncomingDropMovesOriginal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Dump")
        let dump = DumpStore(folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let source = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: source)
        dump.addFiles([source]); try await waitForTransfer(dump)
        XCTAssertNil(dump.error)
        XCTAssertEqual(dump.entries.map(\.name), ["notes.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testMainAppQuitWaitsForDumpTransferBeforeReplying() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dump = DumpStore(folder: root.appendingPathComponent("Dump"))
        let source = root.appendingPathComponent("notes.txt")
        try Data("keep this transfer".utf8).write(to: source)
        var terminationAllowed = false
        let delegate = NestAppDelegate(dump: dump, replyToTermination: { terminationAllowed = $0 })
        dump.addFiles([source])
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertFalse(dump.acceptingTransfers)
        XCTAssertFalse(terminationAllowed)
        for _ in 0..<200 {
            if terminationAllowed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(terminationAllowed)
        XCTAssertFalse(dump.isTransferring)
        XCTAssertEqual(try String(contentsOf: dump.folder.appendingPathComponent("notes.txt")), "keep this transfer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testMainAppWithoutDumpTransferCanQuitImmediately() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dump = DumpStore(folder: root.appendingPathComponent("Dump"))
        let delegate = NestAppDelegate(dump: dump, replyToTermination: { _ in XCTFail("No deferred reply expected") })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertFalse(dump.acceptingTransfers)
    }
    func testIncomingFoldersMoveWithTheirContents() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Dump")
        let dump = DumpStore(folder: folder)
        let source = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        dump.addFiles([source]); try await waitForTransfer(dump)
        XCTAssertNil(dump.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Project/notes.txt")), "notes")
        XCTAssertEqual(dump.entries.count, 1)
    }
    func testRefreshReflectsExternalMovesAndRemovesStaleSelection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Dump")
        let dump = DumpStore(folder: folder)
        await dump.refresh()
        let staged = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: staged)
        await dump.refresh()
        dump.selected = [staged.path]
        try FileManager.default.moveItem(at: staged, to: root.appendingPathComponent("moved.txt"))
        await dump.refresh()
        XCTAssertTrue(dump.entries.isEmpty)
        XCTAssertTrue(dump.selected.isEmpty)
    }

    func testClosingOneSurfaceKeepsOtherSurfaceWatching() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dump = DumpStore(folder: root.appendingPathComponent("Dump"))
        defer { dump.stopWatching() }
        let tab = UUID(), popover = UUID()
        dump.startWatching(owner: tab)
        dump.startWatching(owner: popover)
        await dump.refresh()
        dump.stopWatching(owner: popover)
        try Data("external change".utf8).write(to: dump.folder.appendingPathComponent("new.txt"))
        for _ in 0..<60 {
            if dump.entries.contains(where: { $0.name == "new.txt" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(dump.entries.map(\.name), ["new.txt"])
    }
}
