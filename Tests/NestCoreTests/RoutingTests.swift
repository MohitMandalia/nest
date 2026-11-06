import XCTest
import Foundation
import Darwin
@testable import NestCore

final class RoutingTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ folder: URL, _ name: String, contents: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func mark(_ file: URL, agent: String = "sharingd") throws {
        let data = Data("0081;abcdef;\(agent);\(UUID().uuidString)".utf8)
        let result = data.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        XCTAssertEqual(result, 0)
    }
    func testMoveDoesNotOverwriteAndUndoCollisionIsSafe() throws {
        let downloads = try folder("downloads"), destination = try folder("destination")
        let incoming = try file(downloads, "photo.jpg")
        let existing = try file(destination, "photo.jpg", contents: "existing")
        let moved = try FileRouter.move(incoming, to: destination)
        XCTAssertEqual(moved.lastPathComponent, "photo (1).jpg")
        XCTAssertEqual(try String(contentsOf: existing), "existing")
        _ = try file(downloads, "photo (1).jpg", contents: "new download")
        let returned = try FileRouter.move(moved, to: downloads)
        XCTAssertEqual(returned.lastPathComponent, "photo (1) (1).jpg")
        XCTAssertEqual(try String(contentsOf: returned), "original")
    }
    func testMovePreservesDanglingSymlinkAndUsesNextAvailableName() throws {
        let downloads = try folder("downloads"), destination = try folder("destination")
        let incoming = try file(downloads, "photo.jpg")
        let reserved = destination.appendingPathComponent("photo.jpg")
        let missing = root.appendingPathComponent("missing.jpg")
        try FileManager.default.createSymbolicLink(at: reserved, withDestinationURL: missing)
        let moved = try FileRouter.move(incoming, to: destination)
        XCTAssertEqual(moved.lastPathComponent, "photo (1).jpg")
        XCTAssertEqual(try String(contentsOf: moved), "original")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: reserved.path), missing.path)
    }
    func testUnsafeDestinationsAndSymlinks() throws {
        let downloads = try folder("downloads"), nested = try folder("downloads/nested"), other = try folder("other")
        XCTAssertThrowsError(try FileRouter.validate(destination: downloads, sourceFolder: downloads))
        XCTAssertThrowsError(try FileRouter.validate(destination: nested, sourceFolder: downloads))
        XCTAssertNoThrow(try FileRouter.validate(destination: other, sourceFolder: downloads))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        XCTAssertThrowsError(try FileRouter.validate(destination: link, sourceFolder: downloads))
        XCTAssertThrowsError(try FileRouter.move(link, to: other))
    }
    func testMetadataMustHaveExactAgentField() {
        XCTAssertFalse(AirDropMetadata.isAirDrop(quarantine: nil))
        XCTAssertFalse(AirDropMetadata.isAirDrop(quarantine: "0081;abc;Safari;sharingd"))
        XCTAssertFalse(AirDropMetadata.isAirDrop(quarantine: "sharingd"))
        XCTAssertTrue(AirDropMetadata.isAirDrop(quarantine: "0081;abc;sharingd;uuid"))
    }
    func testSettlingResetsWhenFileChanges() throws {
        let input = try file(root, "incoming.jpg")
        var tracker = SettlingTracker()
        let first = try XCTUnwrap(FileSnapshot.read(input))
        let now = Date()
        XCTAssertFalse(tracker.ready(url: input, snapshot: first, now: now))
        XCTAssertFalse(tracker.ready(url: input, snapshot: first, now: now.addingTimeInterval(4)))
        try Data("larger content".utf8).write(to: input)
        let changed = try XCTUnwrap(FileSnapshot.read(input))
        XCTAssertFalse(tracker.ready(url: input, snapshot: changed, now: now.addingTimeInterval(9)))
        XCTAssertTrue(tracker.ready(url: input, snapshot: changed, now: now.addingTimeInterval(18)))
    }
    func testScannerIgnoresExistingAndBrowserFilesAndOnlyEmitsNewAirDropOnce() async throws {
        let downloads = try folder("downloads")
        let old = try file(downloads, "old.jpg"); try mark(old)
        let scanner = DownloadScanner()
        try await scanner.start(folder: downloads)
        let browser = try file(downloads, "browser.jpg"); try mark(browser, agent: "Safari")
        let incoming = try file(downloads, "new.jpg"); try mark(incoming)
        let partial = try file(downloads, "incomplete.download"); try mark(partial)
        let start = Date()
        let early = try await scanner.scan(now: start)
        XCTAssertTrue(early.isEmpty)
        let ready = try await scanner.scan(now: start.addingTimeInterval(10))
        XCTAssertEqual(ready.map(\.url.lastPathComponent), ["new.jpg"])
        let again = try await scanner.scan(now: start.addingTimeInterval(20))
        XCTAssertTrue(again.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: browser.path))
    }
    func testUndoIgnorePreventsRerouting() async throws {
        let downloads = try folder("downloads")
        let scanner = DownloadScanner()
        try await scanner.start(folder: downloads)
        let returned = try file(downloads, "returned.jpg"); try mark(returned)
        await scanner.ignore(path: returned.path)
        let found = try await scanner.scan(now: Date().addingTimeInterval(20), settleDelay: 0)
        XCTAssertTrue(found.isEmpty)
    }
    func testChangedSnapshotRejectsStaleFile() throws {
        let incoming = try file(root, "changing.txt")
        let snapshot = FileSnapshot.read(incoming)
        try Data("modified file".utf8).write(to: incoming)
        XCTAssertNotEqual(snapshot, FileSnapshot.read(incoming))
    }

    func testScannerDetectsReplacementAtRoutedPathBetweenPolls() async throws {
        let downloads = try folder("downloads"), destination = try folder("destination")
        let scanner = DownloadScanner()
        try await scanner.start(folder: downloads)
        let first = try file(downloads, "photo.jpg"); try mark(first)
        let start = Date()
        _ = try await scanner.scan(now: start)
        let detected = try await scanner.scan(now: start.addingTimeInterval(10))
        XCTAssertEqual(detected.count, 1)
        _ = try FileRouter.move(first, to: destination)
        let replacement = try file(downloads, "photo.jpg", contents: "replacement"); try mark(replacement)
        let early = try await scanner.scan(now: start.addingTimeInterval(12))
        XCTAssertTrue(early.isEmpty)
        let settled = try await scanner.scan(now: start.addingTimeInterval(22))
        XCTAssertEqual(settled.map { $0.url.resolvingSymlinksInPath() }, [replacement.resolvingSymlinksInPath()])
        let again = try await scanner.scan(now: start.addingTimeInterval(32))
        XCTAssertTrue(again.isEmpty)
    }

    func testExistingAndUndoFilesStayIgnoredAfterInPlaceEditsButNotReplacement() async throws {
        let downloads = try folder("downloads"), destination = try folder("destination")
        let existing = try file(downloads, "existing.jpg"); try mark(existing)
        let scanner = DownloadScanner()
        try await scanner.start(folder: downloads)
        let returned = try file(downloads, "returned.jpg"); try mark(returned)
        await scanner.ignore(path: returned.path)
        for url in [existing, returned] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data("edited contents".utf8))
            try handle.close()
            try mark(url)
        }
        let start = Date()
        _ = try await scanner.scan(now: start)
        let ignored = try await scanner.scan(now: start.addingTimeInterval(10))
        XCTAssertTrue(ignored.isEmpty)
        for url in [existing, returned] {
            _ = try FileRouter.move(url, to: destination)
            let replacement = try file(downloads, url.lastPathComponent); try mark(replacement)
        }
        _ = try await scanner.scan(now: start.addingTimeInterval(12))
        let replacements = try await scanner.scan(now: start.addingTimeInterval(22))
        XCTAssertEqual(Set(replacements.map { $0.url.resolvingSymlinksInPath() }),
                       Set([existing, returned].map { $0.resolvingSymlinksInPath() }))
    }
}
