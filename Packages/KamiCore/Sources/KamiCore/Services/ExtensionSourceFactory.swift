import Foundation
import MihonCompatKit

/// Failures while turning a persisted admission capability into the exact
/// source instances backed by its on-disk APK. Messages deliberately omit the
/// filesystem path and extension-controlled metadata.
public enum ExtensionSourceFactoryError: Error, Equatable, LocalizedError {
    case apkUnavailable
    case apkTooLarge(limit: Int)
    case apkContentMismatch
    case signerIdentityMismatch
    case manifestIdentityMismatch
    case sourceIdentityMismatch
    case unsupportedProfile(packageName: String, versionName: String)

    public var errorDescription: String? {
        switch self {
        case .apkUnavailable:
            return "The admitted extension APK is unavailable."
        case let .apkTooLarge(limit):
            return "The admitted extension APK exceeds the \(limit)-byte safety limit."
        case .apkContentMismatch:
            return "The admitted extension APK bytes changed before source construction."
        case .signerIdentityMismatch:
            return "The admitted extension signer changed before source construction."
        case .manifestIdentityMismatch:
            return "The admitted extension manifest changed before source construction."
        case .sourceIdentityMismatch:
            return "The admitted extension source identities do not match its measured profile."
        case let .unsupportedProfile(packageName, versionName):
            return "Kami does not yet have a measured runtime profile for \(packageName) \(versionName)."
        }
    }
}

/// The only factory that consumes a downloaded-extension admission. It reads
/// the file once into a bounded immutable buffer, rehashes and re-verifies that
/// exact buffer, then passes those same bytes to a measured interpreter profile.
public struct ExtensionSourceFactory: Sendable {
    private let verifier: APKSignatureVerifier

    public init(verifier: APKSignatureVerifier = .init()) {
        self.verifier = verifier
    }

    public func makeSources(
        admission: ExtensionAdmission,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> [any KamiSource] {
        let apkBytes = try authenticatedBytes(admission: admission)
        try validateExpectedSourceIDs(admission: admission)
        let sources = try InterpretedExtensionProfileCatalog.makeSources(
            packageName: admission.packageName,
            versionName: admission.versionName,
            versionCode: admission.versionCode,
            apkBytes: apkBytes,
            transportPolicy: transportPolicy,
            preferences: preferences
        )
        return try validate(sources: sources, admission: admission)
    }

    /// Deterministic source-scoped transport seam for integration tests.
    func makeSources(
        admission: ExtensionAdmission,
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> [any KamiSource] {
        let apkBytes = try authenticatedBytes(admission: admission)
        try validateExpectedSourceIDs(admission: admission)
        let sources = try InterpretedExtensionProfileCatalog.makeSources(
            packageName: admission.packageName,
            versionName: admission.versionName,
            versionCode: admission.versionCode,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences
        )
        return try validate(sources: sources, admission: admission)
    }

    private func authenticatedBytes(admission: ExtensionAdmission) throws -> [UInt8] {
        let apkBytes = try Self.readAPK(path: admission.apkPath)
        guard APKSignatureVerifier.apkSHA256(apkBytes) == admission.apkSHA256 else {
            throw ExtensionSourceFactoryError.apkContentMismatch
        }

        let identity = try verifier.verify(apkBytes: apkBytes)
        guard identity == admission.signingIdentity else {
            throw ExtensionSourceFactoryError.signerIdentityMismatch
        }
        if case let .user(fingerprint) = admission.trustSource,
           !identity.contains(fingerprint: fingerprint) {
            throw ExtensionSourceFactoryError.signerIdentityMismatch
        }

        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        guard manifest.packageName == admission.packageName,
              manifest.versionName == admission.versionName,
              manifest.versionCode == admission.versionCode else {
            throw ExtensionSourceFactoryError.manifestIdentityMismatch
        }
        return apkBytes
    }

    private func validate(
        sources: [any KamiSource],
        admission: ExtensionAdmission
    ) throws -> [any KamiSource] {
        guard !sources.isEmpty else {
            throw ExtensionSourceFactoryError.unsupportedProfile(
                packageName: admission.packageName,
                versionName: admission.versionName
            )
        }
        let sourceIDs = Set(sources.map(\.id))
        guard sourceIDs.count == sources.count,
              sourceIDs == admission.sourceIDs else {
            throw ExtensionSourceFactoryError.sourceIdentityMismatch
        }
        return sources
    }

    private func validateExpectedSourceIDs(admission: ExtensionAdmission) throws {
        guard let expected = InterpretedExtensionProfileCatalog.expectedSourceIDs(
            packageName: admission.packageName,
            versionName: admission.versionName,
            versionCode: admission.versionCode
        ) else {
            throw ExtensionSourceFactoryError.unsupportedProfile(
                packageName: admission.packageName,
                versionName: admission.versionName
            )
        }
        guard admission.sourceIDs == expected else {
            throw ExtensionSourceFactoryError.sourceIdentityMismatch
        }
    }

    private static func readAPK(path: String) throws -> [UInt8] {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionSourceFactoryError.apkUnavailable
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize else {
            throw ExtensionSourceFactoryError.apkUnavailable
        }
        guard fileSize <= APKSignatureVerifier.maximumAPKSize else {
            throw ExtensionSourceFactoryError.apkTooLarge(
                limit: APKSignatureVerifier.maximumAPKSize
            )
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == fileSize else {
            throw ExtensionSourceFactoryError.apkUnavailable
        }
        return [UInt8](data)
    }
}
