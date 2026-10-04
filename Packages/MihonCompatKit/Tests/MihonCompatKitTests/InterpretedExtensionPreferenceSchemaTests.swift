import Foundation
import XCTest
import MihonCompatKit

final class InterpretedExtensionPreferenceSchemaTests: XCTestCase {
    private static let package = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let hash = "d45b6d44760cb0465cc7be317d6d1b899c778bb9d7c02d03fb6c2c141dfa137e"
    private static let signer = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private static let sourceID: Int64 = 6_351_052_922_295_965_587
    private typealias FieldID = InterpretedExtensionPreferenceSchema.FieldID
    private typealias Value = InterpretedExtensionPreferenceSchema.Value

    private func schema() throws -> InterpretedExtensionPreferenceSchema {
        try XCTUnwrap(InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: Self.package, versionName: "1.6.6", versionCode: 6
        ))
    }

    func testCatalogPublishesExactCompiledIdentityWithoutAnAPKOrSource() throws {
        let identity = try XCTUnwrap(InterpretedExtensionProfileCatalog.identity(
            packageName: Self.package, versionName: "1.6.6", versionCode: 6
        ))
        XCTAssertEqual(identity.profileIdentifier, "foolslide-1.6.6")
        XCTAssertEqual(identity.packageName, Self.package)
        XCTAssertEqual(identity.versionName, "1.6.6")
        XCTAssertEqual(identity.versionCode, 6)
        XCTAssertEqual(identity.apkSHA256, Self.hash)
        XCTAssertEqual(identity.signerFingerprint, Self.signer)
        XCTAssertEqual(identity.sourceIDs, [Self.sourceID])
        XCTAssertEqual(try schema().identity, identity)
        XCTAssertEqual(InterpretedExtensionProfileCatalog.expectedSourceIDs(
            packageName: Self.package, versionName: "1.6.6", versionCode: 6
        ), identity.sourceIDs)

        for (package, version, code) in [
            (Self.package, "1.6.6", Int64(7)),
            (Self.package, "1.6.7", Int64(6)),
            (Self.package + ".other", "1.6.6", Int64(6)),
            (Self.package.uppercased(), "1.6.6", Int64(6)),
        ] {
            XCTAssertNil(InterpretedExtensionProfileCatalog.identity(
                packageName: package, versionName: version, versionCode: code
            ))
            XCTAssertNil(InterpretedExtensionProfileCatalog.preferenceSchema(
                packageName: package, versionName: version, versionCode: code
            ))
        }
    }

    func testBaoziIdentityDoesNotGrantProductEditablePreferences() throws {
        let package = "eu.kanade.tachiyomi.extension.zh.baozimanhua"
        let identity = try XCTUnwrap(InterpretedExtensionProfileCatalog.identity(
            packageName: package, versionName: "1.6.29", versionCode: 29
        ))
        XCTAssertEqual(identity.apkSHA256,
                       "7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec")
        XCTAssertEqual(identity.signerFingerprint, Self.signer)
        XCTAssertEqual(identity.sourceIDs, [5_724_751_873_601_868_259])
        XCTAssertNil(InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: package, versionName: "1.6.29", versionCode: 29
        ))
    }

    func testProductSchemaHasOnlyMeasuredFieldsAndExcludesBookkeeping() throws {
        let schema = try schema()
        XCTAssertEqual(schema.revision, 1)
        XCTAssertEqual(schema.fields.map(\.id), [.baseURL, .adult])
        XCTAssertEqual(schema.fields[0].kind,
                       .httpsBaseURL(maximumUTF8Bytes: 4_096, requiredToSave: true))
        XCTAssertEqual(schema.fields[1].kind, .boolean(defaultValue: true))
        XCTAssertEqual(schema.defaultUserValues, [.adult: .boolean(true)])
        XCTAssertEqual(Set(FieldID.allCases), [.baseURL, .adult])
        for key in ["defaultBaseUrl", "BAOZI_BANNER", "QUICK_PAGES", "unexpected"] {
            XCTAssertNil(FieldID(rawValue: key))
        }
    }

    func testResolvingDefaultsKeepsUserSnapshotSeparateFromBookkeeping() throws {
        let schema = try schema()
        let url = "https://foolslide.example"
        let resolved = try schema.validateUserValues([.baseURL: .string(url)])
        XCTAssertEqual(resolved.profileIdentity, schema.identity)
        XCTAssertEqual(resolved.schemaRevision, schema.revision)
        XCTAssertEqual(resolved.baseURL, url)
        XCTAssertTrue(resolved.adult)
        XCTAssertEqual(resolved.userValues, [.baseURL: .string(url), .adult: .boolean(true)])
        XCTAssertEqual(resolved.runtimePreferences.strings, [
            "overrideBaseUrl": url,
            "defaultBaseUrl": "https://127.0.0.1",
        ])
        XCTAssertEqual(resolved.runtimePreferences.booleans, ["adult": true])
        XCTAssertEqual(try schema.validateUserValues(resolved.userValues), resolved)
    }

    func testValidatedFalseValueAndDeploymentURLSpellingArePreserved() throws {
        let schema = try schema()
        for url in [
            "https://foolslide.example:8443/reader",
            "https://foolslide.example/reader/%E6%BC%AB%E7%94%BB",
            "HTTPS://FoolSlide.example/Reader",
        ] {
            let resolved = try schema.validateUserValues([
                .baseURL: .string(url), .adult: .boolean(false),
            ])
            XCTAssertEqual(resolved.baseURL, url)
            XCTAssertFalse(resolved.adult)
            XCTAssertEqual(resolved.userValues[.baseURL], .string(url))
            XCTAssertEqual(resolved.runtimePreferences.strings["overrideBaseUrl"], url)
            XCTAssertEqual(resolved.runtimePreferences.booleans["adult"], false)
        }
    }

    func testIncompleteDraftCannotBeSavedAndPlaceholderIsNotConfiguration() throws {
        let schema = try schema()
        let drafts: [[FieldID: Value]] = [[:], schema.defaultUserValues, [.baseURL: .string("")]]
        for values in drafts {
            XCTAssertThrowsError(try schema.validateUserValues(values)) {
                XCTAssertEqual($0 as? InterpretedExtensionPreferenceError,
                               .missingRequiredValue(.baseURL))
            }
        }
        XCTAssertThrowsError(try schema.validateUserValues([
            .baseURL: .string("https://127.0.0.1"),
        ])) {
            XCTAssertEqual($0 as? InterpretedExtensionPreferenceError, .invalidHTTPSBaseURL)
        }
    }

    func testSchemaRejectsWrongScalarTypesWithoutEchoingTheirValues() throws {
        let schema = try schema()
        XCTAssertThrowsError(try schema.validateUserValues([.baseURL: .boolean(true)])) {
            XCTAssertEqual($0 as? InterpretedExtensionPreferenceError, .wrongType(.baseURL))
        }
        let secret = "private-preference-value"
        XCTAssertThrowsError(try schema.validateUserValues([
            .baseURL: .string("https://foolslide.example"), .adult: .string(secret),
        ])) {
            XCTAssertEqual($0 as? InterpretedExtensionPreferenceError, .wrongType(.adult))
            XCTAssertFalse($0.localizedDescription.contains(secret))
            XCTAssertFalse(String(describing: $0).contains(secret))
        }
    }

    func testMalformedURLComponentsAreRejectedWithoutNormalizationOrDisclosure() throws {
        let schema = try schema()
        for url in [
            "http://foolslide.example", "//foolslide.example", "https://", "https:///reader",
            "https://user:private-password@foolslide.example",
            "https://user@foolslide.example", "https://foolslide.example?private-query=value",
            "https://foolslide.example#private-fragment", "https://foolslide.example/",
            "https://foolslide.example/reader%2F", "https://foolslide.example\\reader",
            " https://foolslide.example", "https://foolslide.example ",
            "https://foolslide.example/\nreader", "https://foolslide.example/\u{00}reader",
        ] {
            XCTAssertThrowsError(try schema.validateUserValues([.baseURL: .string(url)])) {
                XCTAssertEqual($0 as? InterpretedExtensionPreferenceError, .invalidHTTPSBaseURL)
                XCTAssertFalse($0.localizedDescription.contains(url))
                XCTAssertFalse(String(describing: $0).contains(url))
                for secret in ["private-password", "private-query", "private-fragment"] {
                    XCTAssertFalse($0.localizedDescription.contains(secret))
                }
            }
        }
    }

    func testURLBudgetIsMeasuredInUTF8BytesBeforeCreatingRuntimeValues() throws {
        let schema = try schema()
        let prefix = "https://foolslide.example/"
        let boundary = prefix + String(repeating: "a", count: 4_096 - prefix.utf8.count)
        XCTAssertEqual(try schema.validateUserValues([.baseURL: .string(boundary)]).baseURL,
                       boundary)
        for url in [boundary + "a", prefix + String(repeating: "界", count: 1_400)] {
            XCTAssertGreaterThan(url.utf8.count, 4_096)
            XCTAssertThrowsError(try schema.validateUserValues([.baseURL: .string(url)])) {
                XCTAssertEqual($0 as? InterpretedExtensionPreferenceError, .invalidHTTPSBaseURL)
            }
        }
    }
}
