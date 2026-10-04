import Foundation
import MihonCompatKit

public enum ExtensionPreferencesError: Error, Equatable, Sendable, LocalizedError {
    case extensionNotInstalled
    case unsupportedProfile
    case authenticationFailed
    case staleInstallation
    case staleConfiguration
    case deploymentInUse
    case configurationRequired
    case invalidStoredConfiguration
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .extensionNotInstalled: return "The extension is no longer installed."
        case .unsupportedProfile: return "This extension has no measured settings contract."
        case .authenticationFailed: return "The installed extension could not be authenticated."
        case .staleInstallation: return "The installation changed. Open its settings again."
        case .staleConfiguration: return "The settings changed. Open them again before saving."
        case .deploymentInUse: return "The source URL cannot change while manga from this source are stored."
        case .configurationRequired: return "Configure a source URL before enabling this extension."
        case .invalidStoredConfiguration: return "The saved extension settings are invalid."
        case .storageUnavailable: return "The extension settings could not be stored."
        }
    }
}

/// An authenticated form snapshot, never an executable extension capability.
/// App code may edit values, but cannot manufacture the identity/CAS token.
public struct ExtensionConfigurationSnapshot: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let enabled: Bool
    public let schema: InterpretedExtensionPreferenceSchema
    public let userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value]
    public let identityFingerprint: String
    public let revision: Int64
    let installed: InstalledExtensionTrust

    init(
        installed: InstalledExtensionTrust,
        schema: InterpretedExtensionPreferenceSchema,
        userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value],
        identityFingerprint: String,
        revision: Int64
    ) {
        self.packageName = installed.packageName
        self.versionName = installed.versionName
        self.versionCode = installed.versionCode
        self.enabled = installed.enabled
        self.schema = schema
        self.userValues = userValues
        self.identityFingerprint = identityFingerprint
        self.revision = revision
        self.installed = installed
    }
}

/// Values captured for a factory construction and a final database freshness
/// check before publication. This does not replace the executable admission.
public struct ExtensionExecutionConfiguration: Sendable {
    public let runtimePreferences: InterpretedExtensionPreferences?
    public let snapshot: ExtensionConfigurationSnapshot?
    let installed: InstalledExtensionTrust

    init(
        installed: InstalledExtensionTrust,
        runtimePreferences: InterpretedExtensionPreferences?,
        snapshot: ExtensionConfigurationSnapshot?
    ) {
        self.installed = installed
        self.runtimePreferences = runtimePreferences
        self.snapshot = snapshot
    }
}

public struct SourceMangaUpdate: Sendable {
    public let manga: Manga
    public let chapters: [Chapter]
}

public enum SourceUpdatePersistenceError: Error, Equatable, Sendable, LocalizedError {
    case configurationRequired
    case sourceIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case .configurationRequired: return "The source configuration changed. Open this manga again."
        case .sourceIdentityMismatch: return "The manga does not belong to this source."
        }
    }
}

enum ExtensionPreferenceBinding {
    private struct Identity: Encodable {
        let domain = "kami.extension-preferences.v1"
        let packageName: String
        let versionName: String
        let versionCode: Int64
        let apkSHA256: String
        let signatureScheme: String
        let currentSigners: [String]
        let signerHistory: [String]
        let sourceIDs: [Int64]
    }

    static func fingerprint(_ installed: InstalledExtensionTrust) throws -> String {
        let identity = Identity(
            packageName: installed.packageName,
            versionName: installed.versionName,
            versionCode: installed.versionCode,
            apkSHA256: installed.apkSHA256,
            signatureScheme: installed.signatureScheme.rawValue,
            currentSigners: installed.currentSigners.sorted(),
            signerHistory: installed.signerHistory.sorted(),
            sourceIDs: installed.sourceIDs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return APKSignatureVerifier.apkSHA256([UInt8](try encoder.encode(identity)))
    }
}

/// Only user-editable typed values are stored; trust, cookies, transport
/// policy and the runtime's defaultBaseUrl bookkeeping never enter this JSON.
struct StoredExtensionPreferenceValues: Codable {
    static let maximumBytes = 16_384
    let strings: [String: String]
    let booleans: [String: Bool]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(_ values: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value]) {
        var strings: [String: String] = [:]
        var booleans: [String: Bool] = [:]
        for (key, value) in values {
            switch value {
            case let .string(value): strings[key.rawValue] = value
            case let .boolean(value): booleans[key.rawValue] = value
            }
        }
        self.strings = strings
        self.booleans = booleans
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["strings", "booleans"] else {
            throw ExtensionPreferencesError.invalidStoredConfiguration
        }
        strings = try container.decode([String: String].self, forKey: Key(stringValue: "strings")!)
        booleans = try container.decode([String: Bool].self, forKey: Key(stringValue: "booleans")!)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(strings, forKey: Key(stringValue: "strings")!)
        try container.encode(booleans, forKey: Key(stringValue: "booleans")!)
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw ExtensionPreferencesError.invalidStoredConfiguration
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(
        _ text: String,
        schema: InterpretedExtensionPreferenceSchema
    ) throws -> ResolvedExtensionPreferences {
        do {
            guard text.utf8.count <= maximumBytes else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            let payload = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
            // Re-enter the validating scalar initializer, then the exact
            // product schema; Codable alone must never bypass either gate.
            let bounded = try InterpretedExtensionPreferences(strings: payload.strings, booleans: payload.booleans)
            var values: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value] = [:]
            for (rawKey, value) in bounded.strings {
                guard let key = InterpretedExtensionPreferenceSchema.FieldID(rawValue: rawKey) else {
                    throw ExtensionPreferencesError.invalidStoredConfiguration
                }
                values[key] = .string(value)
            }
            for (rawKey, value) in bounded.booleans {
                guard let key = InterpretedExtensionPreferenceSchema.FieldID(rawValue: rawKey) else {
                    throw ExtensionPreferencesError.invalidStoredConfiguration
                }
                values[key] = .boolean(value)
            }
            let resolved = try schema.validateUserValues(values)
            // Stored documents are complete resolved snapshots. Defaults are
            // appropriate for a new draft, never for damaged saved values.
            guard resolved.userValues == values else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            return resolved
        } catch {
            throw ExtensionPreferencesError.invalidStoredConfiguration
        }
    }
}
