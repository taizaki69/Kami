import Foundation
import MihonCompatKit

public enum ExtensionTrustSource: Equatable, Sendable {
    case repository(url: String)
    case user(fingerprint: String)

    var persistedValue: String {
        switch self {
        case let .repository(url): return "repository:\(url)"
        case let .user(fingerprint): return "user:\(fingerprint)"
        }
    }

    init?(persistedValue: String) {
        if persistedValue.hasPrefix("repository:") {
            self = .repository(url: String(persistedValue.dropFirst("repository:".count)))
        } else if persistedValue.hasPrefix("user:") {
            self = .user(fingerprint: String(persistedValue.dropFirst("user:".count)))
        } else {
            return nil
        }
    }
}

public enum ExtensionAdmissionError: Swift.Error, Equatable, CustomStringConvertible, LocalizedError {
    case untrustedSigner([String])
    case packageMismatch(expected: String, actual: String)
    case versionCodeMismatch(expected: Int64, actual: Int64?)
    case versionNameMismatch(expected: String, actual: String?)
    case downgrade(installed: Int64, candidate: Int64)
    case sameVersionContentMismatch
    case updateSignerMismatch
    case emptyAPKPath
    case extensionNotInstalled(String)
    case extensionDisabled(String)
    case persistedAPKUnavailable
    case persistedAPKTooLarge(limit: Int)
    case persistedAPKContentMismatch
    case persistedSignerMismatch
    case sourceNotDeclared(Int64)
    case sourceIDCollision(Int64)

    public var description: String {
        switch self {
        case let .untrustedSigner(fingerprints):
            return "extension signer is not trusted: \(fingerprints.joined(separator: ", "))"
        case let .packageMismatch(expected, actual):
            return "extension package mismatch: expected \(expected), got \(actual)"
        case let .versionCodeMismatch(expected, actual):
            return "extension version code mismatch: expected \(expected), got \(actual.map(String.init) ?? "missing")"
        case let .versionNameMismatch(expected, actual):
            return "extension version mismatch: expected \(expected), got \(actual ?? "missing")"
        case let .downgrade(installed, candidate):
            return "extension downgrade is blocked: installed \(installed), candidate \(candidate)"
        case .sameVersionContentMismatch:
            return "same extension version has different APK bytes"
        case .updateSignerMismatch:
            return "extension update does not continue the initially trusted signing identity"
        case .emptyAPKPath:
            return "persisted extension APK path is empty"
        case let .extensionNotInstalled(packageName):
            return "extension is not installed: \(packageName)"
        case let .extensionDisabled(packageName):
            return "extension is disabled: \(packageName)"
        case .persistedAPKUnavailable:
            return "the installed extension APK is unavailable"
        case let .persistedAPKTooLarge(limit):
            return "the installed extension APK exceeds the \(limit)-byte safety limit"
        case .persistedAPKContentMismatch:
            return "the installed extension APK no longer matches its admitted bytes"
        case .persistedSignerMismatch:
            return "the installed extension signer no longer matches persisted trust"
        case let .sourceNotDeclared(id):
            return "source \(id) was not declared by the admitted extension"
        case let .sourceIDCollision(id):
            return "source \(id) conflicts with a protected built-in source"
        }
    }

    public var errorDescription: String? { description }
}

/// Capability issued only after an APK's signer, package/version metadata,
/// update continuity, and persisted trust record have all been validated.
/// Its initializer is internal so app code cannot manufacture a downloaded
/// source admission without going through `ExtensionAdmissionService`.
public struct ExtensionAdmission: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let apkPath: String
    public let apkSHA256: String
    public let signingIdentity: APKSigningIdentity
    public let trustSource: ExtensionTrustSource
    public let sourceIDs: Set<Int64>

    init(
        packageName: String,
        versionName: String,
        versionCode: Int64,
        apkPath: String,
        apkSHA256: String,
        signingIdentity: APKSigningIdentity,
        trustSource: ExtensionTrustSource,
        sourceIDs: Set<Int64>
    ) {
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.apkPath = apkPath
        self.apkSHA256 = apkSHA256
        self.signingIdentity = signingIdentity
        self.trustSource = trustSource
        self.sourceIDs = sourceIDs
    }
}

public struct InstalledExtensionTrust: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let apkPath: String
    public let apkSHA256: String
    public let signatureScheme: APKSigningIdentity.Scheme
    public let currentSigners: [String]
    public let signerHistory: [String]
    public let trustSource: ExtensionTrustSource
    public let sourceIDs: Set<Int64>
    public let repositoryURL: String?
    public let installedAt: Int64
    public let enabled: Bool
}

public struct ExtensionRepositoryRecord: Equatable, Sendable, Identifiable {
    public var id: String { url }
    public let url: String
    public let name: String
    public let signingKey: String?
    public let addedAt: Int64
}

public enum ExtensionRepositoryRecordError: Error, Equatable, LocalizedError {
    case emptyURL
    case signingKeyChanged

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "The extension repository URL is empty."
        case .signingKeyChanged:
            return "The extension repository changed its declared signing key. Remove and re-trust it explicitly before using the new key."
        }
    }
}

#if canImport(SQLite3)

struct ExtensionAdmissionCandidate: Sendable {
    let packageName: String
    let versionName: String
    let versionCode: Int64
    let apkPath: String
    let apkSHA256: String
    let signingIdentity: APKSigningIdentity
    let presentedTrustSource: ExtensionTrustSource?
    let repositoryURL: String?
    let sourceIDs: Set<Int64>
}

/// Authenticates and persists extension installation/update eligibility before
/// any DEX analysis, VM construction, or downloaded-source registration.
public actor ExtensionAdmissionService {
    private let store: LibraryStore
    private let verifier: APKSignatureVerifier

    public init(store: LibraryStore, verifier: APKSignatureVerifier = .init()) {
        self.store = store
        self.verifier = verifier
    }

    public func admit(
        apkBytes: [UInt8],
        extension expected: ExtensionRepositoryIndex.Extension,
        apkPath: String,
        repositoryURL: String? = nil,
        repositorySigningKey: String? = nil,
        explicitUserTrustFingerprint: String? = nil
    ) async throws -> ExtensionAdmission {
        guard !apkPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionAdmissionError.emptyAPKPath
        }

        // Signature verification deliberately precedes all APK metadata and
        // DEX work. A fingerprint is unavailable if cryptographic verification
        // fails at any point.
        let identity = try verifier.verify(apkBytes: apkBytes)
        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        guard manifest.packageName == expected.packageName else {
            throw ExtensionAdmissionError.packageMismatch(
                expected: expected.packageName,
                actual: manifest.packageName
            )
        }
        guard manifest.versionCode == expected.versionCode else {
            throw ExtensionAdmissionError.versionCodeMismatch(
                expected: expected.versionCode,
                actual: manifest.versionCode
            )
        }
        guard manifest.versionName == expected.versionName else {
            throw ExtensionAdmissionError.versionNameMismatch(
                expected: expected.versionName,
                actual: manifest.versionName
            )
        }

        let presentedTrust: ExtensionTrustSource?
        if let userFingerprint = explicitUserTrustFingerprint {
            let normalized = try APKSignatureVerifier.normalizeFingerprint(userFingerprint)
            presentedTrust = identity.contains(fingerprint: normalized)
                ? .user(fingerprint: normalized)
                : nil
        } else if let signingKey = repositorySigningKey {
            let normalized = try APKSignatureVerifier.normalizeFingerprint(signingKey)
            presentedTrust = identity.contains(fingerprint: normalized)
                ? .repository(url: repositoryURL ?? "")
                : nil
        } else {
            presentedTrust = nil
        }

        let candidate = ExtensionAdmissionCandidate(
            packageName: expected.packageName,
            versionName: expected.versionName,
            versionCode: expected.versionCode,
            apkPath: apkPath,
            apkSHA256: APKSignatureVerifier.apkSHA256(apkBytes),
            signingIdentity: identity,
            presentedTrustSource: presentedTrust,
            repositoryURL: repositoryURL,
            sourceIDs: Set(expected.sources.map(\.id))
        )
        return try await store.commitExtensionAdmission(candidate)
    }

    /// Reissues an executable capability from persisted state only after the
    /// on-disk bytes have been bounded, rehashed, signature-verified, and
    /// matched back to the stored package/version/signer identity. The source
    /// factory repeats the byte check on the exact buffer it will execute.
    public func restore(packageName: String) async throws -> ExtensionAdmission {
        guard let installed = try await store.installedExtensionTrust(
            packageName: packageName
        ) else {
            throw ExtensionAdmissionError.extensionNotInstalled(packageName)
        }
        guard installed.enabled else {
            throw ExtensionAdmissionError.extensionDisabled(packageName)
        }

        let apkBytes = try Self.readPersistedAPK(path: installed.apkPath)
        guard APKSignatureVerifier.apkSHA256(apkBytes) == installed.apkSHA256 else {
            throw ExtensionAdmissionError.persistedAPKContentMismatch
        }

        let identity = try verifier.verify(apkBytes: apkBytes)
        let currentSigners = identity.signers.map(\.currentFingerprint).sorted()
        let signerHistory = Array(identity.allFingerprints).sorted()
        guard identity.scheme == installed.signatureScheme,
              currentSigners == installed.currentSigners.sorted(),
              signerHistory == installed.signerHistory.sorted() else {
            throw ExtensionAdmissionError.persistedSignerMismatch
        }

        if case let .user(fingerprint) = installed.trustSource,
           !identity.contains(fingerprint: fingerprint) {
            throw ExtensionAdmissionError.persistedSignerMismatch
        }

        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        guard manifest.packageName == installed.packageName else {
            throw ExtensionAdmissionError.packageMismatch(
                expected: installed.packageName,
                actual: manifest.packageName
            )
        }
        guard manifest.versionCode == installed.versionCode else {
            throw ExtensionAdmissionError.versionCodeMismatch(
                expected: installed.versionCode,
                actual: manifest.versionCode
            )
        }
        guard manifest.versionName == installed.versionName else {
            throw ExtensionAdmissionError.versionNameMismatch(
                expected: installed.versionName,
                actual: manifest.versionName
            )
        }

        return ExtensionAdmission(
            packageName: installed.packageName,
            versionName: installed.versionName,
            versionCode: installed.versionCode,
            apkPath: installed.apkPath,
            apkSHA256: installed.apkSHA256,
            signingIdentity: identity,
            trustSource: installed.trustSource,
            sourceIDs: installed.sourceIDs
        )
    }

    private static func readPersistedAPK(path: String) throws -> [UInt8] {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionAdmissionError.emptyAPKPath
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize else {
            throw ExtensionAdmissionError.persistedAPKUnavailable
        }
        guard fileSize <= APKSignatureVerifier.maximumAPKSize else {
            throw ExtensionAdmissionError.persistedAPKTooLarge(
                limit: APKSignatureVerifier.maximumAPKSize
            )
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == fileSize else {
            throw ExtensionAdmissionError.persistedAPKUnavailable
        }
        return [UInt8](data)
    }

    static func updatePreservesIdentity(
        existingCurrentSigners: [String],
        candidate: APKSigningIdentity
    ) -> Bool {
        let existing = Set(existingCurrentSigners)
        guard !existing.isEmpty else { return false }
        if existing.count == 1, let prior = existing.first {
            return candidate.signers.count == 1 &&
                candidate.signers[0].certificateHistory.contains(prior)
        }
        // Android certificate rotation applies to a single signer. For
        // multi-signed APKs, require the complete signer set to remain exact.
        return Set(candidate.signers.map(\.currentFingerprint)) == existing
    }
}

#endif
