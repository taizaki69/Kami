import Foundation
import MihonCompatKit

#if canImport(SQLite3)

/// Authenticates installed bytes before opening or changing their measured
/// product settings. A disabled installation can be configured, but no method
/// here issues an executable admission or registers a source.
public actor ExtensionPreferencesService {
    private let store: LibraryStore
    private let verifier: APKSignatureVerifier

    public init(store: LibraryStore, verifier: APKSignatureVerifier = .init()) {
        self.store = store
        self.verifier = verifier
    }

    public func configuration(packageName: String) async throws -> ExtensionConfigurationSnapshot {
        let installed = try await installed(packageName: packageName)
        let schema = try authenticatedSchema(installed: installed)
        do {
            return try await store.extensionConfigurationSnapshot(installed: installed, schema: schema)
        } catch {
            throw Self.storageError(error)
        }
    }

    /// Reauthenticates at save time, then checks installation and document
    /// revisions inside one store transaction. Enablement is never changed.
    public func saveConfiguration(
        snapshot: ExtensionConfigurationSnapshot,
        userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value]
    ) async throws -> ExtensionConfigurationSnapshot {
        let current = try await installed(packageName: snapshot.packageName)
        guard current == snapshot.installed else { throw ExtensionPreferencesError.staleInstallation }
        let schema = try authenticatedSchema(installed: current)
        guard schema == snapshot.schema else { throw ExtensionPreferencesError.staleInstallation }
        let resolved = try schema.validateUserValues(userValues)
        do {
            return try await store.saveExtensionConfiguration(snapshot: snapshot, resolved: resolved)
        } catch {
            throw Self.storageError(error)
        }
    }

    /// Captures preferences for the exact admission that the factory will
    /// independently reauthenticate. Profiles without editable product fields
    /// retain their existing factory defaults, including Baozi banner=0.
    public func loadForExecution(admission: ExtensionAdmission) async throws -> ExtensionExecutionConfiguration {
        let installed = try await installed(packageName: admission.packageName)
        guard installed.enabled, Self.matches(installed: installed, admission: admission) else {
            throw ExtensionPreferencesError.staleInstallation
        }
        guard let identity = InterpretedExtensionProfileCatalog.identity(
            packageName: installed.packageName, versionName: installed.versionName, versionCode: installed.versionCode
        ) else { throw ExtensionPreferencesError.unsupportedProfile }
        try Self.validateMeasuredIdentity(installed: installed, identity: identity)
        let snapshot: ExtensionConfigurationSnapshot?
        let runtimePreferences: InterpretedExtensionPreferences?
        if let schema = InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: installed.packageName, versionName: installed.versionName, versionCode: installed.versionCode
        ) {
            try Self.validateMeasuredIdentity(installed: installed, identity: schema.identity)
            do {
                let stored = try await store.extensionConfigurationSnapshot(installed: installed, schema: schema)
                guard stored.revision > 0 else { throw ExtensionPreferencesError.configurationRequired }
                runtimePreferences = try schema.validateUserValues(stored.userValues).runtimePreferences
                snapshot = stored
            } catch {
                throw Self.storageError(error)
            }
        } else {
            snapshot = nil
            runtimePreferences = nil
        }
        return ExtensionExecutionConfiguration(
            installed: installed, runtimePreferences: runtimePreferences, snapshot: snapshot
        )
    }

    /// Call after detached factory construction and before registry
    /// publication. This verifies DB freshness; it does not authenticate a
    /// replacement file or grant an admission by itself.
    public func verifyCurrentExecution(_ configuration: ExtensionExecutionConfiguration) async throws {
        do {
            try await store.verifyExtensionExecutionConfiguration(configuration)
        } catch {
            throw Self.storageError(error)
        }
    }

    private func installed(packageName: String) async throws -> InstalledExtensionTrust {
        do {
            guard let installed = try await store.installedExtensionTrust(packageName: packageName) else {
                throw ExtensionPreferencesError.extensionNotInstalled
            }
            return installed
        } catch {
            throw Self.storageError(error)
        }
    }

    private func authenticatedSchema(installed: InstalledExtensionTrust) throws -> InterpretedExtensionPreferenceSchema {
        do {
            _ = try ExtensionAPKAuthentication.authenticate(installed: installed, verifier: verifier)
        } catch {
            throw ExtensionPreferencesError.authenticationFailed
        }
        guard let schema = InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: installed.packageName, versionName: installed.versionName, versionCode: installed.versionCode
        ) else { throw ExtensionPreferencesError.unsupportedProfile }
        try Self.validateMeasuredIdentity(installed: installed, identity: schema.identity)
        return schema
    }

    private static func validateMeasuredIdentity(
        installed: InstalledExtensionTrust,
        identity: InterpretedExtensionProfileIdentity
    ) throws {
        guard installed.packageName == identity.packageName,
              installed.versionName == identity.versionName,
              installed.versionCode == identity.versionCode,
              installed.apkSHA256 == identity.apkSHA256,
              installed.currentSigners == [identity.signerFingerprint],
              installed.signerHistory.contains(identity.signerFingerprint),
              installed.sourceIDs == identity.sourceIDs else {
            throw ExtensionPreferencesError.authenticationFailed
        }
    }

    private static func matches(installed: InstalledExtensionTrust, admission: ExtensionAdmission) -> Bool {
        installed.packageName == admission.packageName
            && installed.versionName == admission.versionName
            && installed.versionCode == admission.versionCode
            && installed.apkPath == admission.apkPath
            && installed.apkSHA256 == admission.apkSHA256
            && installed.signatureScheme == admission.signingIdentity.scheme
            && installed.currentSigners.sorted() == admission.signingIdentity.signers.map(\.currentFingerprint).sorted()
            && installed.signerHistory.sorted() == Array(admission.signingIdentity.allFingerprints).sorted()
            && installed.trustSource == admission.trustSource
            && installed.sourceIDs == admission.sourceIDs
    }

    private static func storageError(_ error: Error) -> Error {
        if let error = error as? ExtensionPreferencesError { return error }
        if let error = error as? InterpretedExtensionPreferenceError { return error }
        // Do not expose SQLite messages, user values, file paths, repository
        // metadata or signing-parser diagnostics through the settings UI.
        return ExtensionPreferencesError.storageUnavailable
    }
}

#endif
