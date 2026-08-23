import Foundation
import MihonCompatKit

#if canImport(SQLite3)

public struct ExtensionInstallPreparation: Identifiable, Sendable {
    public let id: UUID
    public let packageName: String
    public let extensionName: String
    public let versionName: String
    public let signatureScheme: APKSigningIdentity.Scheme
    public let currentSignerFingerprints: [String]
    public let apkSHA256: String

    init(
        id: UUID,
        packageName: String,
        extensionName: String,
        versionName: String,
        signatureScheme: APKSigningIdentity.Scheme,
        currentSignerFingerprints: [String],
        apkSHA256: String
    ) {
        self.id = id
        self.packageName = packageName
        self.extensionName = extensionName
        self.versionName = versionName
        self.signatureScheme = signatureScheme
        self.currentSignerFingerprints = currentSignerFingerprints
        self.apkSHA256 = apkSHA256
    }
}

public enum ExtensionInstallOutcome: Sendable {
    case installed(ExtensionAdmission)
    case requiresUserTrust(ExtensionInstallPreparation)
}

public enum ExtensionInstallationError: Error, Equatable, LocalizedError {
    case invalidRepositoryMetadata
    case noDeclaredSources
    case storageUnavailable
    case pendingInstallExpired
    case pendingAPKChanged
    case signerWasNotPresented

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryMetadata:
            return "The repository entry does not match the downloaded extension."
        case .noDeclaredSources:
            return "The repository entry does not declare a usable source ID."
        case .storageUnavailable:
            return "Kami could not store the extension APK."
        case .pendingInstallExpired:
            return "The pending extension confirmation expired. Please install it again."
        case .pendingAPKChanged:
            return "The pending extension APK changed before confirmation."
        case .signerWasNotPresented:
            return "The selected signer was not presented by the verified APK."
        }
    }
}

/// Owns downloaded APK storage and the two-phase trust-on-first-install flow.
/// Repositories with a declared signer can complete immediately. Legacy stores
/// without one stage the already-verified bytes until the user explicitly
/// confirms a displayed current certificate fingerprint.
public actor ExtensionInstallationService {
    typealias APKDownloader = @Sendable (String) async throws -> [UInt8]

    private struct PendingInstall: Sendable {
        let preparation: ExtensionInstallPreparation
        let extensionEntry: ExtensionRepositoryIndex.Extension
        let repositoryURL: String
        let stagedURL: URL
    }

    private let store: LibraryStore
    private let admissionService: ExtensionAdmissionService
    private let rootDirectory: URL
    private let verifier: APKSignatureVerifier
    private let downloadAPK: APKDownloader
    private var pending: [UUID: PendingInstall] = [:]

    public init(
        store: LibraryStore,
        admissionService: ExtensionAdmissionService,
        rootDirectory: URL,
        client: ExtensionStoreClient
    ) {
        self.store = store
        self.admissionService = admissionService
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.verifier = APKSignatureVerifier()
        self.downloadAPK = { apkURL in
            try await client.download(apkURL: apkURL)
        }
    }

    init(
        store: LibraryStore,
        admissionService: ExtensionAdmissionService,
        rootDirectory: URL,
        verifier: APKSignatureVerifier = .init(),
        downloadAPK: @escaping APKDownloader
    ) {
        self.store = store
        self.admissionService = admissionService
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.verifier = verifier
        self.downloadAPK = downloadAPK
    }

    public func beginInstall(
        extension extensionEntry: ExtensionRepositoryIndex.Extension,
        repositoryURL: String,
        repositorySigningKey: String?
    ) async throws -> ExtensionInstallOutcome {
        let apkBytes = try await downloadAPK(extensionEntry.apkURL)
        return try await beginInstall(
            apkBytes: apkBytes,
            extension: extensionEntry,
            repositoryURL: repositoryURL,
            repositorySigningKey: repositorySigningKey
        )
    }

    func beginInstall(
        apkBytes: [UInt8],
        extension extensionEntry: ExtensionRepositoryIndex.Extension,
        repositoryURL: String,
        repositorySigningKey: String?
    ) async throws -> ExtensionInstallOutcome {
        let sourceIDs = extensionEntry.sources.map(\.id)
        guard !sourceIDs.isEmpty, sourceIDs.allSatisfy({ $0 > 0 }) else {
            throw ExtensionInstallationError.noDeclaredSources
        }

        // This preview is cryptographic and deliberately precedes both the
        // confirmation UI and all durable writes.
        let identity = try verifier.verify(apkBytes: apkBytes)
        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        guard manifest.packageName == extensionEntry.packageName,
              manifest.versionName == extensionEntry.versionName,
              manifest.versionCode == extensionEntry.versionCode else {
            throw ExtensionInstallationError.invalidRepositoryMetadata
        }

        let prior = try await store.installedExtensionTrust(
            packageName: extensionEntry.packageName
        )
        let normalizedRepositoryKey = repositorySigningKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Updates inherit the persisted trust root and are checked for signer
        // continuity by ExtensionAdmissionService; they never prompt merely
        // because a legacy repository still lacks signing-key metadata.
        if prior != nil || normalizedRepositoryKey?.isEmpty == false {
            let admission = try await finalize(
                apkBytes: apkBytes,
                extension: extensionEntry,
                repositoryURL: repositoryURL,
                repositorySigningKey: normalizedRepositoryKey,
                explicitUserTrustFingerprint: nil
            )
            return .installed(admission)
        }

        try ensureDirectories()
        let id = UUID()
        let stagedURL = stagingDirectory
            .appendingPathComponent("\(id.uuidString.lowercased()).apk")
        do {
            try Data(apkBytes).write(to: stagedURL, options: .atomic)
        } catch {
            throw ExtensionInstallationError.storageUnavailable
        }
        let preparation = ExtensionInstallPreparation(
            id: id,
            packageName: extensionEntry.packageName,
            extensionName: extensionEntry.name,
            versionName: extensionEntry.versionName,
            signatureScheme: identity.scheme,
            currentSignerFingerprints: identity.signers
                .map(\.currentFingerprint)
                .sorted(),
            apkSHA256: APKSignatureVerifier.apkSHA256(apkBytes)
        )
        pending[id] = PendingInstall(
            preparation: preparation,
            extensionEntry: extensionEntry,
            repositoryURL: repositoryURL,
            stagedURL: stagedURL
        )
        return .requiresUserTrust(preparation)
    }

    public func confirmUserTrust(
        _ preparation: ExtensionInstallPreparation,
        fingerprint: String
    ) async throws -> ExtensionAdmission {
        guard let item = pending.removeValue(forKey: preparation.id),
              item.preparation.packageName == preparation.packageName,
              item.preparation.apkSHA256 == preparation.apkSHA256 else {
            throw ExtensionInstallationError.pendingInstallExpired
        }
        defer { try? FileManager.default.removeItem(at: item.stagedURL) }

        let normalized = try APKSignatureVerifier.normalizeFingerprint(fingerprint)
        guard item.preparation.currentSignerFingerprints.contains(normalized) else {
            throw ExtensionInstallationError.signerWasNotPresented
        }
        let apkBytes = try Self.readStagedAPK(at: item.stagedURL)
        guard APKSignatureVerifier.apkSHA256(apkBytes) == item.preparation.apkSHA256 else {
            throw ExtensionInstallationError.pendingAPKChanged
        }
        return try await finalize(
            apkBytes: apkBytes,
            extension: item.extensionEntry,
            repositoryURL: item.repositoryURL,
            repositorySigningKey: nil,
            explicitUserTrustFingerprint: normalized
        )
    }

    public func cancel(_ preparation: ExtensionInstallPreparation) {
        guard let item = pending.removeValue(forKey: preparation.id) else { return }
        try? FileManager.default.removeItem(at: item.stagedURL)
    }

    private func finalize(
        apkBytes: [UInt8],
        extension extensionEntry: ExtensionRepositoryIndex.Extension,
        repositoryURL: String,
        repositorySigningKey: String?,
        explicitUserTrustFingerprint: String?
    ) async throws -> ExtensionAdmission {
        try ensureDirectories()
        let oldTrust = try await store.installedExtensionTrust(
            packageName: extensionEntry.packageName
        )
        let apkSHA256 = APKSignatureVerifier.apkSHA256(apkBytes)
        let finalURL = rootDirectory.appendingPathComponent("\(apkSHA256).apk")
        let replacesExistingPath = oldTrust?.apkPath == finalURL.path

        do {
            try Data(apkBytes).write(to: finalURL, options: .atomic)
        } catch {
            throw ExtensionInstallationError.storageUnavailable
        }

        do {
            let admission = try await admissionService.admit(
                apkBytes: apkBytes,
                extension: extensionEntry,
                apkPath: finalURL.path,
                repositoryURL: repositoryURL,
                repositorySigningKey: repositorySigningKey,
                explicitUserTrustFingerprint: explicitUserTrustFingerprint
            )
            if let oldPath = oldTrust?.apkPath, oldPath != finalURL.path {
                removeManagedAPK(path: oldPath)
            }
            return admission
        } catch {
            if !replacesExistingPath {
                removeManagedAPK(path: finalURL.path)
            }
            throw error
        }
    }

    private var stagingDirectory: URL {
        rootDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    private func ensureDirectories() throws {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ExtensionInstallationError.storageUnavailable
        }
    }

    private func removeManagedAPK(path: String) {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "apk",
              candidate.deletingLastPathComponent() == rootDirectory else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func readStagedAPK(at url: URL) throws -> [UInt8] {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize <= APKSignatureVerifier.maximumAPKSize,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        data.count == fileSize else {
            throw ExtensionInstallationError.pendingAPKChanged
        }
        return [UInt8](data)
    }
}

#endif
