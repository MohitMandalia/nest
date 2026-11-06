import Foundation
import Darwin

public struct FolderReference: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?
    public init(url: URL) {
        path = url.path
        bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve() throws -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

public struct PersonRoute: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var contactID: String?
    public var folder: FolderReference
    public init(name: String, contactID: String? = nil, folder: FolderReference) {
        id = UUID(); self.name = name; self.contactID = contactID; self.folder = folder
    }
}

public struct Transfer: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date = Date()
    public var originalPath: String
    public var currentPath: String
    public var sender: String?
    public var destination: FolderReference
    public var undone = false
    public var snapshot: FileSnapshot?
    public var name: String { URL(fileURLWithPath: currentPath).lastPathComponent }
    public init(originalPath: String, currentPath: String, sender: String?, destination: FolderReference) {
        self.originalPath = originalPath; self.currentPath = currentPath
        self.sender = sender; self.destination = destination
    }
}

public enum RoutingError: LocalizedError {
    case invalidDestination, sourceChanged, unsafeSource
    public var errorDescription: String? {
        switch self {
        case .invalidDestination: return "Choose an existing, writable folder outside the watched folder."
        case .sourceChanged: return "This file has changed or disappeared. It was left untouched."
        case .unsafeSource: return "Nest leaves symbolic links untouched."
        }
    }
}

public enum FileRouter {
    public static func validate(destination: URL, sourceFolder: URL) throws {
        let dest = destination.resolvingSymlinksInPath().standardizedFileURL
        let source = sourceFolder.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard dest.path != source.path, !dest.path.hasPrefix(source.path + "/"),
              FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: dest.path) else { throw RoutingError.invalidDestination }
    }
    // moveItem never replaces an existing item. Retry if another writer claims the name.
    public static func move(_ source: URL, to folder: URL) throws -> URL {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw RoutingError.unsafeSource }
        for index in 0..<10_000 {
            let candidate = folder.appendingPathComponent(availableName(source.lastPathComponent, index: index))
            var info = stat()
            if lstat(candidate.path, &info) == 0 { continue }
            do {
                try FileManager.default.moveItem(at: source, to: candidate)
                return candidate
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileWriteFileExists.rawValue,
                   FileManager.default.fileExists(atPath: source.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
    public static func availableName(_ original: String, index: Int) -> String {
        guard index > 0 else { return original }
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? original : url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
    }
}

public enum AirDropMetadata {
    public static func isAirDrop(quarantine: String?) -> Bool {
        guard let quarantine else { return false }
        let parts = quarantine.split(separator: ";", omittingEmptySubsequences: false)
        // This is a best-effort macOS metadata convention, not a public AirDrop API.
        return parts.count >= 3 && parts[2] == "sharingd"
    }
    public static func quarantine(at url: URL) -> String? {
        let name = "com.apple.quarantine"
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count < 65_536 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let read = getxattr(url.path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return String(bytes: bytes.prefix(read), encoding: .utf8)
    }
}

public struct FileSnapshot: Codable, Equatable, Sendable {
    public let size: Int64
    public let modified: Date
    public let identity: String
    public static func read(_ url: URL) -> FileSnapshot? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let identity = "\(info.st_dev):\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return FileSnapshot(size: Int64(info.st_size), modified: modified, identity: identity)
    }
}

public struct SettlingTracker: Sendable {
    private struct Observation: Sendable { var snapshot: FileSnapshot; var since: Date }
    private var observations: [String: Observation] = [:]
    public init() {}
    public mutating func ready(url: URL, snapshot: FileSnapshot, now: Date = Date(), delay: TimeInterval = 8) -> Bool {
        if let previous = observations[url.path], previous.snapshot == snapshot {
            return now.timeIntervalSince(previous.since) >= delay && now.timeIntervalSince(snapshot.modified) >= delay
        }
        observations[url.path] = Observation(snapshot: snapshot, since: now)
        return false
    }
    public mutating func retain(paths: Set<String>) { observations = observations.filter { paths.contains($0.key) } }
}
