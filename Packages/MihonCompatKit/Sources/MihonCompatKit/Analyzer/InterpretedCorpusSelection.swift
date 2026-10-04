import Foundation

/// Selects fixtures by their locked evidence role. This is a static-audit input
/// helper; the manifest and its hashes grant no signing trust or execution.
public enum InterpretedCorpusSelection {
    public enum Role: String, Decodable, Sendable {
        case execution
        case measurement
        case conformance
    }

    public enum Error: Swift.Error, Equatable {
        case invalidManifest
        case invalidArtifact
        case duplicatePath
        case emptySelection
        case unsafePath
        case invalidAPKSize
        case apkDigestMismatch
    }

    public struct Input: Sendable {
        private let root: URL
        private let path: String
        private let sha256: String

        fileprivate init(root: URL, path: String, sha256: String) {
            self.root = root
            self.path = path
            self.sha256 = sha256
        }

        /// Reads one immutable bounded buffer and verifies the same bytes that
        /// the audit will inspect. A replaced file cannot silently update a lock.
        public func loadAPKBytes() throws -> [UInt8] {
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { throw Error.unsafePath }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= APKSignatureVerifier.maximumAPKSize else {
                throw Error.invalidAPKSize
            }
            let bytes = [UInt8](try InterpretedCorpusSelection.boundedData(
                at: url,
                maximumBytes: APKSignatureVerifier.maximumAPKSize,
                oversizedError: .invalidAPKSize
            ))
            guard bytes.count == size else { throw Error.invalidAPKSize }
            guard APKSignatureVerifier.apkSHA256(bytes) == sha256 else {
                throw Error.apkDigestMismatch
            }
            return bytes
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let artifacts: [Artifact]
    }

    private struct Artifact: Decodable {
        let path: String
        let role: Role
        let sha256: String
    }

    public static func inputs(at directory: URL, role: Role) throws -> [Input] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = root.appendingPathComponent("manifest.json").resolvingSymlinksInPath()
        guard manifestURL.path.hasPrefix(root.path + "/") else { throw Error.unsafePath }
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= 256 * 1024 else { throw Error.invalidManifest }
        let bytes = try boundedData(
            at: manifestURL, maximumBytes: 256 * 1024, oversizedError: .invalidManifest
        )
        guard bytes.count == size else { throw Error.invalidManifest }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        } catch {
            throw Error.invalidManifest
        }
        guard manifest.schemaVersion == 2,
              (1...512).contains(manifest.artifacts.count) else { throw Error.invalidManifest }

        var paths = Set<String>()
        for artifact in manifest.artifacts {
            let path = artifact.path
            guard !path.isEmpty, path.utf8.count <= 1_024,
                  !path.hasPrefix("/"), !path.contains("\\"),
                  !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
                  path.hasSuffix(".apk"),
                  path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw Error.unsafePath
            }
            guard artifact.sha256.utf8.count == 64,
                  artifact.sha256.utf8.allSatisfy({
                      (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                  }) else { throw Error.invalidArtifact }
            guard paths.insert(path).inserted else { throw Error.duplicatePath }
        }

        let selected = manifest.artifacts.filter { $0.role == role }.sorted { $0.path < $1.path }
        guard !selected.isEmpty else { throw Error.emptySelection }
        return selected.map { Input(root: root, path: $0.path, sha256: $0.sha256) }
    }

    /// The file may grow after its metadata was checked. Read at most limit+1
    /// bytes so rejection itself cannot allocate an unbounded buffer.
    private static func boundedData(
        at url: URL,
        maximumBytes: Int,
        oversizedError: Error
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximumBytes {
            let remaining = maximumBytes + 1 - result.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)),
                  !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= maximumBytes else { throw oversizedError }
        return result
    }
}
