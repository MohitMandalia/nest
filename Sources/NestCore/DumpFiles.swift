import Foundation
import Darwin

public enum DumpTransferMode: String, Codable, CaseIterable, Sendable {
    case copy, move
}
public struct DumpEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public let modified: Date
    public let size: Int64
    public var name: String { url.lastPathComponent }
}
public struct DumpFailure: Sendable {
    public let name: String
    public let message: String
    public init(name: String, message: String) { self.name = name; self.message = message }
}
public struct DumpTransferResult: Sendable {
    public var transferred: [URL] = []
    public var skipped: [URL] = []
    public var failures: [DumpFailure] = []
    public init(transferred: [URL] = [], skipped: [URL] = [], failures: [DumpFailure] = []) {
        self.transferred = transferred; self.skipped = skipped; self.failures = failures
    }
}
public enum DumpError: LocalizedError {
    case unsupportedItem, invalidDestination, recursiveDestination
    public var errorDescription: String? {
        switch self {
        case .unsupportedItem: return "Choose a regular file or folder. Symbolic links aren’t supported."
        case .invalidDestination: return "The destination must be an existing writable folder."
        case .recursiveDestination: return "A folder can’t be transferred into itself or one of its subfolders."
        }
    }
}
public enum DumpFiles {
    public static func ensureFolder(_ url: URL) throws {
        if exists(url) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw DumpError.invalidDestination }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    public static func entries(in folder: URL) throws -> [DumpEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeRegular || type == .typeDirectory else { return nil }
            return DumpEntry(url: url, isDirectory: type == .typeDirectory,
                             modified: attrs[.modificationDate] as? Date ?? .distantPast,
                             size: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
        }.sorted { $0.modified == $1.modified ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.modified > $1.modified }
    }
    public static func transfer(_ urls: [URL], to destination: URL, mode: DumpTransferMode) -> DumpTransferResult {
        var result = DumpTransferResult()
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
        let sources = normalizedSources(urls)
        for source in sources {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                guard source.isFileURL else { throw DumpError.unsupportedItem }
                let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                let type = attrs[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else { throw DumpError.unsupportedItem }
                let destAttrs = try FileManager.default.attributesOfItem(atPath: destination.path)
                guard destAttrs[.type] as? FileAttributeType == .typeDirectory,
                      FileManager.default.isWritableFile(atPath: destination.path) else { throw DumpError.invalidDestination }
                let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
                let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
                if type == .typeDirectory && (resolvedSource == resolvedDestination || resolvedDestination.path.hasPrefix(resolvedSource.path + "/")) {
                    throw DumpError.recursiveDestination
                }
                if resolvedSource.deletingLastPathComponent() == resolvedDestination {
                    result.skipped.append(source); continue
                }
                let target = try transferOne(source, to: destination, mode: mode, directory: type == .typeDirectory)
                result.transferred.append(target)
            } catch {
                result.failures.append(DumpFailure(name: source.lastPathComponent, message: error.localizedDescription))
            }
        }
        return result
    }
    private static func transferOne(_ source: URL, to folder: URL, mode: DumpTransferMode, directory: Bool) throws -> URL {
        for index in 0..<10_000 {
            let name = directory && index > 0 ? "\(source.lastPathComponent) (\(index))" : FileRouter.availableName(source.lastPathComponent, index: index)
            let candidate = folder.appendingPathComponent(name)
            if exists(candidate) { continue }
            do {
                if mode == .copy { try FileManager.default.copyItem(at: source, to: candidate) }
                else { try FileManager.default.moveItem(at: source, to: candidate) }
                return candidate
            } catch {
                // Retry only a name race. Permission, disk, and partial-copy errors are reported.
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteFileExists.rawValue && exists(source) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
    private static func normalizedSources(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        let unique = urls.map { $0.isFileURL ? $0.standardizedFileURL : $0 }.filter { seen.insert($0.absoluteString).inserted }
        let folders = unique.filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeDirectory }
        return unique.filter { source in !folders.contains { $0 != source && source.path.hasPrefix($0.path + "/") } }
    }
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
