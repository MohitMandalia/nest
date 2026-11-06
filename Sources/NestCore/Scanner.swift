import Foundation
import Darwin

public struct DetectedFile: Identifiable, Codable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var snapshot: FileSnapshot
    public var detected = Date()
    public var failure: String?
    public init(url: URL, snapshot: FileSnapshot) { self.url = url; self.snapshot = snapshot }
}

public actor DownloadScanner {
    // Content and metadata edits keep an existing file ignored, but a new file
    // at the same path must be considered even if no poll saw the path disappear.
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int
        let birthNanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
    private var known: [String: FileIdentity] = [:]
    private var tracker = SettlingTracker()
    private var folder: URL?
    public init() {}
    public func start(folder: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        known = Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            FileIdentity(url).map { (url.resolvingSymlinksInPath().path, $0) }
        })
        tracker = SettlingTracker(); self.folder = folder
    }
    public func ignore(path: String) {
        let url = URL(fileURLWithPath: path)
        known[url.resolvingSymlinksInPath().path] = FileIdentity(url)
    }
    public func scan(now: Date = Date(), settleDelay: TimeInterval = 8) throws -> [DetectedFile] {
        guard let folder else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let paths = Set(urls.map(\.path))
        let resolvedPaths = Set(urls.map { $0.resolvingSymlinksInPath().path })
        known = known.filter { resolvedPaths.contains($0.key) }
        tracker.retain(paths: paths)
        var result: [DetectedFile] = []
        for url in urls {
            let path = url.resolvingSymlinksInPath().path
            guard let identity = FileIdentity(url), known[path] != identity,
                  !["download", "crdownload", "part", "partial", "tmp"].contains(url.pathExtension.lowercased()),
                  let snapshot = FileSnapshot.read(url),
                  tracker.ready(url: url, snapshot: snapshot, now: now, delay: settleDelay),
                  AirDropMetadata.isAirDrop(quarantine: AirDropMetadata.quarantine(at: url)) else { continue }
            known[path] = identity
            result.append(DetectedFile(url: url, snapshot: snapshot))
        }
        return result
    }
}
