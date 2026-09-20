import Foundation

/// Immutable resource bytes explicitly supplied by an extension host. This is
/// not a filesystem, URL loader, or authority to load additional executable code.
public struct InterpretedAPKResources: Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidPath
        case tooManyResources
        case resourceTooLarge
        case totalSizeExceeded
        case duplicatePath
    }

    static let maximumCount = 64
    static let maximumResourceBytes = 256 * 1024
    static let maximumTotalBytes = 1024 * 1024
    private let contents: [String: [UInt8]]

    public init() {
        contents = [:]
    }

    public init(contents: [String: [UInt8]]) throws {
        guard contents.count <= Self.maximumCount else { throw Error.tooManyResources }
        var total = 0
        for (path, bytes) in contents {
            guard Self.validPath(path) else { throw Error.invalidPath }
            guard bytes.count <= Self.maximumResourceBytes else { throw Error.resourceTooLarge }
            total += bytes.count
            guard total <= Self.maximumTotalBytes else { throw Error.totalSizeExceeded }
        }
        self.contents = contents
    }

    /// The measured Iken constructor reads only bundled localization tables.
    /// Check central-directory sizes before inflating any selected entry.
    static func localization(from archive: ZipArchive) throws -> Self {
        let entries = archive.entries.filter {
            $0.name.hasPrefix("assets/i18n/") && $0.name.hasSuffix(".properties")
        }
        guard entries.count <= maximumCount else { throw Error.tooManyResources }
        var total: UInt64 = 0
        var names = Set<String>()
        for entry in entries {
            guard validPath(entry.name) else { throw Error.invalidPath }
            guard entry.uncompressedSize <= UInt64(maximumResourceBytes) else {
                throw Error.resourceTooLarge
            }
            total += entry.uncompressedSize
            guard total <= UInt64(maximumTotalBytes) else { throw Error.totalSizeExceeded }
            guard names.insert(entry.name).inserted else { throw Error.duplicatePath }
        }
        var contents: [String: [UInt8]] = [:]
        for entry in entries {
            contents[entry.name] = try archive.data(named: entry.name)
        }
        return try Self(contents: contents)
    }

    func bytes(named path: String) -> [UInt8]? {
        guard Self.validPath(path) else { return nil }
        // Java names compare exact code units, rather than Swift's Unicode
        // canonical equivalence. Never alias a differently spelled resource.
        return contents.first { $0.key.utf8.elementsEqual(path.utf8) }?.value
    }

    private static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1_024,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
