import XCTest
import Foundation
@testable import NestCore

final class DumpFilesTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NestDumpTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try DumpFiles.ensureFolder(url); return url
    }
    func file(_ folder: URL, _ name: String, text: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }
    func testCopyKeepsOriginalAndDoesNotReplaceExistingFile() throws {
        let source = try folder("source"), dump = try folder("Dump")
        let original = try file(source, "notes.txt")
        let existing = try file(dump, "notes.txt", text: "existing")
        let result = DumpFiles.transfer([original], to: dump, mode: .copy)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.transferred.first?.lastPathComponent, "notes (1).txt")
        XCTAssertEqual(try String(contentsOf: existing), "existing")
        XCTAssertEqual(try String(contentsOf: original), "original")
    }
    func testMoveFolderIntoAndOutOfDumpPreservesContents() throws {
        let source = try folder("project"), dump = try folder("Dump"), destination = try folder("destination")
        _ = try file(source, "notes.txt")
        let incoming = DumpFiles.transfer([source], to: dump, mode: .move)
        let staged = try XCTUnwrap(incoming.transferred.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("notes.txt").path))
        let outgoing = DumpFiles.transfer([staged], to: destination, mode: .move)
        XCTAssertTrue(outgoing.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("project/notes.txt")), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testFolderCannotBeCopiedIntoItselfOrDescendant() throws {
        let source = try folder("project"), child = try folder("project/Dump")
        _ = try file(source, "notes.txt")
        for destination in [source, child] {
            let result = DumpFiles.transfer([source], to: destination, mode: .copy)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertTrue(result.transferred.isEmpty)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("notes.txt").path))
    }
    func testDroppingAnItemAlreadyInDumpDoesNotDuplicateIt() throws {
        let dump = try folder("Dump"), staged = try file(dump, "file.txt")
        for mode in DumpTransferMode.allCases {
            let result = DumpFiles.transfer([staged], to: dump, mode: mode)
            XCTAssertEqual(result.skipped, [staged])
            XCTAssertTrue(result.transferred.isEmpty)
        }
        XCTAssertEqual(try DumpFiles.entries(in: dump).count, 1)
    }
    func testSymlinkSourceIsRejectedAndDanglingDestinationNameIsPreserved() throws {
        let source = try folder("source"), dump = try folder("Dump")
        let original = try file(source, "file.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertEqual(DumpFiles.transfer([link], to: dump, mode: .move).failures.count, 1)
        let reserved = dump.appendingPathComponent("file.txt")
        try FileManager.default.createSymbolicLink(at: reserved, withDestinationURL: root.appendingPathComponent("missing"))
        let result = DumpFiles.transfer([original], to: dump, mode: .copy)
        XCTAssertEqual(result.transferred.first?.lastPathComponent, "file (1).txt")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: reserved.path), root.appendingPathComponent("missing").path)
    }
    func testParentAndChildSelectionIsTransferredOnlyOnce() throws {
        let parent = try folder("project"), dump = try folder("Dump")
        let child = try file(parent, "notes.txt")
        let result = DumpFiles.transfer([child, parent, parent], to: dump, mode: .move)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.transferred.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dump.appendingPathComponent("project/notes.txt").path))
    }
    func testMixedBatchReportsFailureAndStillCopiesValidItems() throws {
        let source = try folder("source"), dump = try folder("Dump")
        let valid = try file(source, "file.txt")
        let result = DumpFiles.transfer([source.appendingPathComponent("missing"), valid], to: dump, mode: .copy)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.transferred.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
    }
    func testEnsureFolderDoesNotReplaceAFileAndRejectsWebURLs() throws {
        let conflict = try file(root, "Dump")
        XCTAssertThrowsError(try DumpFiles.ensureFolder(conflict))
        XCTAssertEqual(try String(contentsOf: conflict), "original")
        let dump = try folder("realDump")
        let result = DumpFiles.transfer([URL(string: "https://example.com/file.txt")!], to: dump, mode: .copy)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.transferred.isEmpty)
    }
    func testDuplicateFolderWithDotGetsSuffixAfterWholeName() throws {
        let parent = try folder("source"), dump = try folder("Dump")
        let source = parent.appendingPathComponent("draft.v1")
        try DumpFiles.ensureFolder(source)
        try DumpFiles.ensureFolder(dump.appendingPathComponent("draft.v1"))
        let result = DumpFiles.transfer([source], to: dump, mode: .copy)
        XCTAssertEqual(result.transferred.first?.lastPathComponent, "draft.v1 (1)")
    }
}
