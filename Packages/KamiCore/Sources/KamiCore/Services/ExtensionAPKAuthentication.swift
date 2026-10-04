import Foundation
import MihonCompatKit

/// Shared bounded file read. A size obtained before opening the file is only
/// a fast rejection; every read also has a hard byte limit.
enum ExtensionAPKFileReader {
    enum ReadError: Error {
        case unavailable
        case tooLarge(limit: Int)
    }

    static func read(path: String, maximumBytes: Int = APKSignatureVerifier.maximumAPKSize) throws -> [UInt8] {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              maximumBytes > 0, maximumBytes < Int.max else {
            throw ReadError.unavailable
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let expectedSize = values.fileSize, expectedSize >= 0 else {
            throw ReadError.unavailable
        }
        guard expectedSize <= maximumBytes else {
            throw ReadError.tooLarge(limit: maximumBytes)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.unavailable
        }
        defer { try? handle.close() }
        var data = Data(capacity: min(expectedSize, 65_536))
        do {
            while true {
                let count = min(65_536, maximumBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= maximumBytes else {
                    throw ReadError.tooLarge(limit: maximumBytes)
                }
            }
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.unavailable
        }
        guard data.count == expectedSize else { throw ReadError.unavailable }
        return [UInt8](data)
    }
}

/// Authentication does not issue an executable admission. Configuration can
/// use this check while an installation remains disabled.
enum ExtensionAPKAuthentication {
    static func authenticate(
        installed: InstalledExtensionTrust,
        verifier: APKSignatureVerifier
    ) throws -> APKSigningIdentity {
        let bytes: [UInt8]
        do {
            bytes = try ExtensionAPKFileReader.read(path: installed.apkPath)
        } catch ExtensionAPKFileReader.ReadError.tooLarge(let limit) {
            throw ExtensionAdmissionError.persistedAPKTooLarge(limit: limit)
        } catch {
            throw ExtensionAdmissionError.persistedAPKUnavailable
        }
        guard APKSignatureVerifier.apkSHA256(bytes) == installed.apkSHA256 else {
            throw ExtensionAdmissionError.persistedAPKContentMismatch
        }
        let identity = try verifier.verify(apkBytes: bytes)
        guard identity.scheme == installed.signatureScheme,
              identity.signers.map(\.currentFingerprint).sorted() == installed.currentSigners.sorted(),
              Array(identity.allFingerprints).sorted() == installed.signerHistory.sorted() else {
            throw ExtensionAdmissionError.persistedSignerMismatch
        }
        if case let .user(fingerprint) = installed.trustSource,
           !identity.contains(fingerprint: fingerprint) {
            throw ExtensionAdmissionError.persistedSignerMismatch
        }
        let manifest = try ExtensionManifest(apkBytes: bytes)
        guard manifest.packageName == installed.packageName else {
            throw ExtensionAdmissionError.packageMismatch(expected: installed.packageName, actual: manifest.packageName)
        }
        guard manifest.versionCode == installed.versionCode else {
            throw ExtensionAdmissionError.versionCodeMismatch(expected: installed.versionCode, actual: manifest.versionCode)
        }
        guard manifest.versionName == installed.versionName else {
            throw ExtensionAdmissionError.versionNameMismatch(expected: installed.versionName, actual: manifest.versionName)
        }
        return identity
    }
}
