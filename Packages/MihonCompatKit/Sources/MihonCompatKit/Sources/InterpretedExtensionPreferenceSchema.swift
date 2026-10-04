import Foundation

/// Compiled identity of one measured artifact. This describes a profile;
/// callers must still authenticate installed bytes before source execution.
public struct InterpretedExtensionProfileIdentity: Sendable, Equatable {
    public let profileIdentifier: String
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let apkSHA256: String
    public let signerFingerprint: String
    public let sourceIDs: Set<Int64>
}

/// Product-editable fields of an exact measured profile. Validation creates
/// scalar values only; it never constructs a source or performs network I/O.
public struct InterpretedExtensionPreferenceSchema: Sendable, Equatable {
    public enum FieldID: String, Sendable, CaseIterable, Hashable {
        case baseURL = "overrideBaseUrl"
        case adult
    }

    public enum Value: Sendable, Equatable {
        case string(String)
        case boolean(Bool)
    }

    public enum Kind: Sendable, Equatable {
        case httpsBaseURL(maximumUTF8Bytes: Int, requiredToSave: Bool)
        case boolean(defaultValue: Bool)
    }

    public struct Field: Sendable, Equatable {
        public let id: FieldID
        public let kind: Kind
    }

    public let identity: InterpretedExtensionProfileIdentity
    public let revision: Int
    public let fields: [Field]

    /// A new editor starts with a blank URL and the measured adult default.
    /// An incomplete editor draft cannot be resolved for persistence.
    public var defaultUserValues: [FieldID: Value] {
        [.adult: .boolean(true)]
    }

    init(foolSlideIdentity identity: InterpretedExtensionProfileIdentity) {
        self.identity = identity
        revision = 1
        fields = [
            Field(id: .baseURL, kind: .httpsBaseURL(
                maximumUTF8Bytes: FoolSlidePreferenceRules.maximumURLBytes,
                requiredToSave: true
            )),
            Field(id: .adult, kind: .boolean(defaultValue: true)),
        ]
    }

    /// Rejects unsupported value types, missing configuration and invalid
    /// URLs before producing the exact runtime values. URL spelling is kept
    /// unchanged, and bookkeeping is excluded from the returned user values.
    public func validateUserValues(
        _ values: [FieldID: Value]
    ) throws -> ResolvedExtensionPreferences {
        guard let suppliedURL = values[.baseURL] else {
            throw InterpretedExtensionPreferenceError.missingRequiredValue(.baseURL)
        }
        guard case let .string(baseURL) = suppliedURL else {
            throw InterpretedExtensionPreferenceError.wrongType(.baseURL)
        }
        guard !baseURL.isEmpty else {
            throw InterpretedExtensionPreferenceError.missingRequiredValue(.baseURL)
        }
        guard baseURL != FoolSlidePreferenceRules.defaultBaseURL,
              FoolSlidePreferenceRules.validDeploymentURL(baseURL) else {
            throw InterpretedExtensionPreferenceError.invalidHTTPSBaseURL
        }

        let adult: Bool
        if let suppliedAdult = values[.adult] {
            guard case let .boolean(value) = suppliedAdult else {
                throw InterpretedExtensionPreferenceError.wrongType(.adult)
            }
            adult = value
        } else {
            adult = true
        }

        let preferences = try InterpretedExtensionPreferences(
            strings: [FieldID.baseURL.rawValue: baseURL],
            booleans: [FieldID.adult.rawValue: adult]
        )
        let runtimePreferences = try FoolSlidePreferenceRules.normalizedRuntimePreferences(
            preferences
        )
        return ResolvedExtensionPreferences(
            profileIdentity: identity,
            schemaRevision: revision,
            userValues: [.baseURL: .string(baseURL), .adult: .boolean(adult)],
            runtimePreferences: runtimePreferences,
            baseURL: baseURL,
            adult: adult
        )
    }
}

/// Only a measured schema issues resolved product values. Keeping these
/// immutable binds the persisted snapshot to the values used by the factory.
public struct ResolvedExtensionPreferences: Sendable, Equatable {
    public let profileIdentity: InterpretedExtensionProfileIdentity
    public let schemaRevision: Int
    public let userValues: [InterpretedExtensionPreferenceSchema.FieldID:
                            InterpretedExtensionPreferenceSchema.Value]
    public let runtimePreferences: InterpretedExtensionPreferences
    public let baseURL: String
    public let adult: Bool
}

/// Product validation failures deliberately exclude URLs, arbitrary keys,
/// filesystem paths and underlying parser or transport error text.
public enum InterpretedExtensionPreferenceError: Error, Sendable, Equatable, LocalizedError {
    case missingRequiredValue(InterpretedExtensionPreferenceSchema.FieldID)
    case wrongType(InterpretedExtensionPreferenceSchema.FieldID)
    case invalidHTTPSBaseURL

    public var errorDescription: String? {
        switch self {
        case .missingRequiredValue:
            return "Configure the source URL before saving its preferences."
        case .wrongType:
            return "The source preference has an unsupported value type."
        case .invalidHTTPSBaseURL:
            return "Enter a configured HTTPS source URL without credentials, a query, a fragment or a trailing slash."
        }
    }
}

/// Shared raw FoolSlide rules. The product schema is narrower: it requires a
/// configured URL and never accepts the DEX's bookkeeping key as user input.
enum FoolSlidePreferenceRules {
    static let maximumURLBytes = 4_096
    static let defaultBaseURL = "https://127.0.0.1"

    static func validates(_ preferences: InterpretedExtensionPreferences) -> Bool {
        let otherStrings = preferences.strings.keys.filter {
            $0 != "overrideBaseUrl" && $0 != "defaultBaseUrl"
        }
        guard otherStrings.isEmpty,
              Set(preferences.booleans.keys).isSubset(of: ["adult"]) else { return false }
        if let overrideURL = preferences.strings["overrideBaseUrl"],
           !validDeploymentURL(overrideURL) { return false }
        if let defaultURL = preferences.strings["defaultBaseUrl"],
           defaultURL != defaultBaseURL { return false }
        return true
    }

    /// Validate explicit bookkeeping before supplying an omitted sentinel.
    /// The real APK would otherwise discard an override-only configuration.
    static func normalizedRuntimePreferences(
        _ preferences: InterpretedExtensionPreferences
    ) throws -> InterpretedExtensionPreferences {
        guard validates(preferences) else {
            throw PinnedInterpretedSourceError.invalidPreferences(profile: "foolslide-1.6.6")
        }
        guard preferences.strings["overrideBaseUrl"] != nil,
              preferences.strings["defaultBaseUrl"] == nil else { return preferences }
        var strings = preferences.strings
        strings["defaultBaseUrl"] = defaultBaseURL
        return try InterpretedExtensionPreferences(strings: strings, booleans: preferences.booleans)
    }

    static func validDeploymentURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumURLBytes,
              !value.hasSuffix("/"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
                      || $0 == "\\"
              }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.hasSuffix("/") else { return false }
        // This is the transport's pure encoder validation, not execution of
        // a transport or creation of a source-scoped HTTP client.
        return (try? CompatHTTPTransportPolicy(allowsInsecureHTTP: false).validate(
            request: CompatHTTPRequest(url: value)
        )) != nil
    }
}
