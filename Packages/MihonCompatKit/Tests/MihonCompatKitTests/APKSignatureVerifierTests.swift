import Foundation
import XCTest
@testable import MihonCompatKit

final class APKSignatureVerifierTests: XCTestCase {
    private let keiyoushiFingerprint =
        "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private let aospFirstFingerprint =
        "fb5dbd3c669af9fc236c6991e6387b7f11ff0590997f22d0f5c74ff40e04fca8"
    private let aospSecondFingerprint =
        "681b0e56a796350c08647352a4db800cc44b2adc8f4c72fa350bd05d4d50264d"

    private func corpus(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/MihonCompatKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/MihonCompatKit
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    func testKeiyoushiCorpusMatchesRepositoryFingerprintAfterV2Verification() throws {
        let verifier = APKSignatureVerifier()
        for name in [
            "akuma", "mangadex", "batcave", "kawiimanga", "mangamelon",
            "baozimanhua", "tuttoanimemanga",
        ] {
            let identity = try verifier.verify(apkBytes: corpus(name))
            XCTAssertEqual(identity.scheme, .v2, name)
            XCTAssertEqual(identity.signers.count, 1, name)
            XCTAssertEqual(identity.signers[0].currentFingerprint, keiyoushiFingerprint, name)
            XCTAssertEqual(identity.signers[0].certificateHistory, [keiyoushiFingerprint], name)
            XCTAssertTrue(identity.contains(fingerprint: keiyoushiFingerprint), name)
        }
    }

    func testV2RejectsContentTamperingAndInvalidSignerSignature() throws {
        let verifier = APKSignatureVerifier()
        var tampered = try corpus("batcave")
        tampered[100] ^= 0x01
        XCTAssertThrowsError(try verifier.verify(apkBytes: tampered)) {
            XCTAssertEqual($0 as? APKSignatureVerificationError, .contentDigestMismatch)
        }

        XCTAssertThrowsError(try verifier.verify(
            apkBytes: corpus("aosp-v2-invalid-signature")
        )) {
            XCTAssertEqual($0 as? APKSignatureVerificationError, .signatureInvalid)
        }
    }

    func testV3VerifiesProofOfRotationOldestToCurrent() throws {
        let verifier = APKSignatureVerifier()
        let original = try verifier.verify(apkBytes: corpus("aosp-v3-original"))
        XCTAssertEqual(original.scheme, .v3)
        XCTAssertEqual(original.signers[0].certificateHistory, [aospFirstFingerprint])

        let identity = try verifier.verify(
            apkBytes: corpus("aosp-v3-lineage")
        )
        XCTAssertEqual(identity.scheme, .v3)
        XCTAssertEqual(identity.signers.count, 1)
        XCTAssertEqual(
            identity.signers[0].certificateHistory,
            [aospFirstFingerprint, aospSecondFingerprint]
        )
        XCTAssertEqual(identity.signers[0].currentFingerprint, aospSecondFingerprint)
        XCTAssertTrue(identity.contains(fingerprint: aospFirstFingerprint))
        XCTAssertTrue(identity.contains(fingerprint: aospSecondFingerprint))
    }

    func testV1FallbackAuthenticatesCMSAndEveryPayloadEntry() throws {
        let identity = try APKSignatureVerifier().verify(apkBytes: corpus("aosp-v1"))
        XCTAssertEqual(identity.scheme, .v1)
        XCTAssertEqual(identity.signers.map(\.currentFingerprint), [aospFirstFingerprint])

        var tampered = try corpus("aosp-v1")
        // This fixture begins with an uncompressed local entry. Changing its
        // payload leaves the ZIP structure readable but invalidates the JAR
        // manifest digest (or its CRC before trust can be returned).
        tampered[64] ^= 0x01
        XCTAssertThrowsError(try APKSignatureVerifier().verify(apkBytes: tampered))
    }

    func testUnsignedAPKAndMalformedFingerprintsAreRejected() throws {
        XCTAssertThrowsError(try APKSignatureVerifier().verify(
            apkBytes: corpus("aosp-unsigned")
        )) {
            XCTAssertEqual($0 as? APKSignatureVerificationError, .unsigned)
        }
        XCTAssertEqual(
            try APKSignatureVerifier.normalizeFingerprint(
                "9A:DD:65:5A:78:E9:6C:4E:C7:A5:3E:F8:9D:CC:B5:57:" +
                "CB:5D:76:74:89:FA:C5:E7:85:D6:71:A5:A7:5D:4D:A2"
            ),
            keiyoushiFingerprint
        )
        XCTAssertThrowsError(try APKSignatureVerifier.normalizeFingerprint("not-a-key"))
    }

    func testV2StrippingProtectionCannotBeBypassed() throws {
        XCTAssertThrowsError(try APKSignatureVerifier().verify(
            apkBytes: corpus("aosp-v3-stripped")
        )) {
            XCTAssertEqual($0 as? APKSignatureVerificationError, .strippedScheme(3))
        }
    }
}
