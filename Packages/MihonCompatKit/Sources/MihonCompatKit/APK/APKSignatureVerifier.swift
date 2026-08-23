import Crypto
import _CryptoExtras
import Foundation

/// A cryptographically verified Android APK signing identity. Fingerprints
/// use Mihon's exact representation: lowercase hexadecimal SHA-256 over the
/// DER-encoded X.509 signing certificate (`Signature.toByteArray()` on
/// Android).
public struct APKSigningIdentity: Equatable, Sendable {
    public enum Scheme: String, Equatable, Sendable {
        case v1
        case v2
        case v3
        case v31
    }

    public struct Signer: Equatable, Sendable {
        /// Current certificate for this signer.
        public let currentFingerprint: String
        /// Oldest-to-current certificate history. For a non-rotated signer
        /// this contains only `currentFingerprint`.
        public let certificateHistory: [String]

        init(currentFingerprint: String, certificateHistory: [String]) {
            self.currentFingerprint = currentFingerprint
            self.certificateHistory = certificateHistory
        }
    }

    public let scheme: Scheme
    public let signers: [Signer]

    public var allFingerprints: Set<String> {
        Set(signers.flatMap(\.certificateHistory))
    }

    public func contains(fingerprint: String) -> Bool {
        guard let normalized = try? APKSignatureVerifier.normalizeFingerprint(fingerprint) else {
            return false
        }
        return allFingerprints.contains(normalized)
    }

    init(scheme: Scheme, signers: [Signer]) {
        self.scheme = scheme
        self.signers = signers
    }
}

public enum APKSignatureVerificationError: Swift.Error, Equatable, CustomStringConvertible {
    case apkTooLarge(limit: Int)
    case unsigned
    case malformed(String)
    case unsupported(String)
    case signatureInvalid
    case contentDigestMismatch
    case certificatePublicKeyMismatch
    case strippedScheme(Int)
    case invalidFingerprint(String)

    public var description: String {
        switch self {
        case let .apkTooLarge(limit):
            return "APK exceeds the \(limit)-byte signature-verification limit"
        case .unsigned:
            return "APK has no supported signing identity"
        case let .malformed(reason):
            return "malformed APK signature data: \(reason)"
        case let .unsupported(reason):
            return "unsupported APK signature: \(reason)"
        case .signatureInvalid:
            return "APK signer signature did not verify"
        case .contentDigestMismatch:
            return "APK content digest does not match its signed digest"
        case .certificatePublicKeyMismatch:
            return "APK signer public key does not match its certificate"
        case let .strippedScheme(id):
            return String(format: "APK references stripped signing scheme 0x%08x", id)
        case let .invalidFingerprint(value):
            return "invalid signer fingerprint: \(value)"
        }
    }
}

/// Bounded verifier for Android APK Signature Schemes v2/v3/v3.1 and a
/// conservative JAR-signing (v1) fallback. No certificate fingerprint is
/// returned until the signer signature and the APK's signed content digest
/// have both verified.
public struct APKSignatureVerifier {
    public static let maximumAPKSize = 128 * 1024 * 1024

    private static let v2BlockID: UInt32 = 0x7109_871a
    private static let v3BlockID: UInt32 = 0xf053_68c0
    private static let v31BlockID: UInt32 = 0x1b93_ad61
    private static let strippingProtectionAttributeID: UInt32 = 0xbeef_f00d
    private static let proofOfRotationAttributeID: UInt32 = 0x3ba0_6f8c
    fileprivate static let signingBlockMagic = Array("APK Sig Block 42".utf8)
    fileprivate static let maximumSigningBlockSize = 16 * 1024 * 1024
    private static let maximumSigners = 32
    fileprivate static let maximumRecords = 64
    private static let maximumCertificates = 64

    public init() {}

    public static func apkSHA256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizeFingerprint(_ value: String) throws -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) ||
                  (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
              }) else {
            throw APKSignatureVerificationError.invalidFingerprint(value)
        }
        return normalized
    }

    public func verify(apkBytes bytes: [UInt8]) throws -> APKSigningIdentity {
        guard bytes.count <= Self.maximumAPKSize else {
            throw APKSignatureVerificationError.apkTooLarge(limit: Self.maximumAPKSize)
        }
        let layout = try APKLayout(bytes: bytes)

        if let block = layout.schemeBlocks[Self.v31BlockID] {
            return try verifyModernScheme(
                bytes: bytes,
                layout: layout,
                block: block,
                scheme: .v31
            )
        }
        if let block = layout.schemeBlocks[Self.v3BlockID] {
            return try verifyModernScheme(
                bytes: bytes,
                layout: layout,
                block: block,
                scheme: .v3
            )
        }
        if let block = layout.schemeBlocks[Self.v2BlockID] {
            return try verifyModernScheme(
                bytes: bytes,
                layout: layout,
                block: block,
                scheme: .v2
            )
        }
        return try verifyV1(bytes: bytes, layout: layout)
    }

    // MARK: - APK Signature Schemes v2/v3

    private func verifyModernScheme(
        bytes: [UInt8],
        layout: APKLayout,
        block: Range<Int>,
        scheme: APKSigningIdentity.Scheme
    ) throws -> APKSigningIdentity {
        var outer = LittleEndianReader(bytes, range: block)
        let signersRange = try outer.lengthPrefixed32("signers")
        try outer.requireEnd("signing scheme block")

        var signersReader = LittleEndianReader(bytes, range: signersRange)
        var signers: [APKSigningIdentity.Signer] = []
        var expectations: [ContentDigestKind: [UInt8]] = [:]
        while !signersReader.isAtEnd {
            guard signers.count < Self.maximumSigners else {
                throw APKSignatureVerificationError.malformed("too many APK signers")
            }
            let signerRange = try signersReader.lengthPrefixed32("signer")
            let parsed: ParsedSigner
            if scheme == .v2 {
                parsed = try parseV2Signer(
                    bytes: bytes,
                    range: signerRange,
                    availableSchemes: Set(layout.schemeBlocks.keys)
                )
            } else {
                parsed = try parseV3Signer(bytes: bytes, range: signerRange)
            }
            if let prior = expectations[parsed.digestKind], prior != parsed.expectedDigest {
                throw APKSignatureVerificationError.malformed(
                    "signers disagree on the APK content digest"
                )
            }
            expectations[parsed.digestKind] = parsed.expectedDigest
            signers.append(parsed.signer)
        }
        guard !signers.isEmpty else {
            throw APKSignatureVerificationError.malformed("signing block contains no signers")
        }

        for (kind, expected) in expectations {
            let actual = try contentDigest(bytes: bytes, layout: layout, kind: kind)
            guard constantTimeEqual(actual, expected) else {
                throw APKSignatureVerificationError.contentDigestMismatch
            }
        }
        return APKSigningIdentity(scheme: scheme, signers: signers)
    }

    private func parseV2Signer(
        bytes: [UInt8],
        range: Range<Int>,
        availableSchemes: Set<UInt32>
    ) throws -> ParsedSigner {
        var signer = LittleEndianReader(bytes, range: range)
        let signedData = try signer.lengthPrefixed32("v2 signed data")
        let signaturesRange = try signer.lengthPrefixed32("v2 signatures")
        let publicKeyRange = try signer.lengthPrefixed32("v2 public key")
        try signer.requireEnd("v2 signer")

        let signatures = try parseAlgorithmRecords(
            bytes: bytes,
            range: signaturesRange,
            label: "v2 signatures"
        )
        let selected = try selectAlgorithm(from: signatures)
        let publicKey = Array(bytes[publicKeyRange])
        guard try verifySignature(
            algorithm: selected.algorithm,
            signature: selected.value,
            message: Array(bytes[signedData]),
            publicKey: publicKey
        ) else {
            throw APKSignatureVerificationError.signatureInvalid
        }

        var data = LittleEndianReader(bytes, range: signedData)
        let digestsRange = try data.lengthPrefixed32("v2 digests")
        let certificatesRange = try data.lengthPrefixed32("v2 certificates")
        let attributesRange = try data.lengthPrefixed32("v2 attributes")
        // Current apksig emits one signed, empty reserved field after the
        // original v2 tuple. Android's verifier ignores trailing signed-data;
        // accept only that exact bounded extension rather than arbitrary data.
        if data.remaining == 4 {
            guard try data.u32("v2 reserved field") == 0 else {
                throw APKSignatureVerificationError.malformed("nonempty v2 reserved field")
            }
        }
        try data.requireEnd("v2 signed data")

        let certificates = try parseCertificates(bytes: bytes, range: certificatesRange)
        guard let certificate = certificates.first else {
            throw APKSignatureVerificationError.malformed("v2 signer has no certificate")
        }
        guard certificate.subjectPublicKeyInfo == publicKey else {
            throw APKSignatureVerificationError.certificatePublicKeyMismatch
        }

        let digests = try parseAlgorithmRecords(
            bytes: bytes,
            range: digestsRange,
            label: "v2 digests"
        )
        try requireMatchingAlgorithmLists(signatures, digests)
        guard let expected = digests.first(where: { $0.id == selected.id })?.value else {
            throw APKSignatureVerificationError.malformed("selected v2 digest is absent")
        }
        try validateDigestLength(expected, kind: selected.algorithm.contentDigest)
        try checkV2Attributes(
            bytes: bytes,
            range: attributesRange,
            availableSchemes: availableSchemes
        )

        let fingerprint = certificateFingerprint(certificate.der)
        return ParsedSigner(
            signer: .init(currentFingerprint: fingerprint, certificateHistory: [fingerprint]),
            digestKind: selected.algorithm.contentDigest,
            expectedDigest: expected
        )
    }

    private func parseV3Signer(bytes: [UInt8], range: Range<Int>) throws -> ParsedSigner {
        var signer = LittleEndianReader(bytes, range: range)
        let signedData = try signer.lengthPrefixed32("v3 signed data")
        let minSDK = try signer.u32("v3 minimum SDK")
        let maxSDK = try signer.u32("v3 maximum SDK")
        guard minSDK <= maxSDK else {
            throw APKSignatureVerificationError.malformed("v3 SDK range is inverted")
        }
        let signaturesRange = try signer.lengthPrefixed32("v3 signatures")
        let publicKeyRange = try signer.lengthPrefixed32("v3 public key")
        try signer.requireEnd("v3 signer")

        let signatures = try parseAlgorithmRecords(
            bytes: bytes,
            range: signaturesRange,
            label: "v3 signatures"
        )
        let selected = try selectAlgorithm(from: signatures)
        let publicKey = Array(bytes[publicKeyRange])
        guard try verifySignature(
            algorithm: selected.algorithm,
            signature: selected.value,
            message: Array(bytes[signedData]),
            publicKey: publicKey
        ) else {
            throw APKSignatureVerificationError.signatureInvalid
        }

        var data = LittleEndianReader(bytes, range: signedData)
        let digestsRange = try data.lengthPrefixed32("v3 digests")
        let certificatesRange = try data.lengthPrefixed32("v3 certificates")
        let signedMinSDK = try data.u32("signed v3 minimum SDK")
        let signedMaxSDK = try data.u32("signed v3 maximum SDK")
        guard minSDK == signedMinSDK, maxSDK == signedMaxSDK else {
            throw APKSignatureVerificationError.malformed(
                "v3 signed and unsigned SDK ranges differ"
            )
        }
        let attributesRange = try data.lengthPrefixed32("v3 attributes")
        try data.requireEnd("v3 signed data")

        let certificates = try parseCertificates(bytes: bytes, range: certificatesRange)
        guard let certificate = certificates.first else {
            throw APKSignatureVerificationError.malformed("v3 signer has no certificate")
        }
        guard certificate.subjectPublicKeyInfo == publicKey else {
            throw APKSignatureVerificationError.certificatePublicKeyMismatch
        }

        let digests = try parseAlgorithmRecords(
            bytes: bytes,
            range: digestsRange,
            label: "v3 digests"
        )
        try requireMatchingAlgorithmLists(signatures, digests)
        guard let expected = digests.first(where: { $0.id == selected.id })?.value else {
            throw APKSignatureVerificationError.malformed("selected v3 digest is absent")
        }
        try validateDigestLength(expected, kind: selected.algorithm.contentDigest)

        var history = [certificateFingerprint(certificate.der)]
        var attributes = LittleEndianReader(bytes, range: attributesRange)
        var attributeCount = 0
        while !attributes.isAtEnd {
            attributeCount += 1
            guard attributeCount <= Self.maximumRecords else {
                throw APKSignatureVerificationError.malformed("too many v3 attributes")
            }
            let attributeRange = try attributes.lengthPrefixed32("v3 attribute")
            var attribute = LittleEndianReader(bytes, range: attributeRange)
            let id = try attribute.u32("v3 attribute ID")
            let value = attribute.remainingRange
            if id == Self.proofOfRotationAttributeID {
                history = try parseAndVerifyLineage(
                    bytes: bytes,
                    range: value,
                    currentCertificate: certificate.der
                )
            }
        }

        let current = certificateFingerprint(certificate.der)
        guard history.last == current else {
            throw APKSignatureVerificationError.malformed(
                "v3 rotation history does not end at the current signer"
            )
        }
        return ParsedSigner(
            signer: .init(currentFingerprint: current, certificateHistory: history),
            digestKind: selected.algorithm.contentDigest,
            expectedDigest: expected
        )
    }

    private func checkV2Attributes(
        bytes: [UInt8],
        range: Range<Int>,
        availableSchemes: Set<UInt32>
    ) throws {
        var attributes = LittleEndianReader(bytes, range: range)
        var count = 0
        while !attributes.isAtEnd {
            count += 1
            guard count <= Self.maximumRecords else {
                throw APKSignatureVerificationError.malformed("too many v2 attributes")
            }
            let attributeRange = try attributes.lengthPrefixed32("v2 attribute")
            var attribute = LittleEndianReader(bytes, range: attributeRange)
            let id = try attribute.u32("v2 attribute ID")
            if id == Self.strippingProtectionAttributeID {
                let referenced = try attribute.u32("referenced signing scheme")
                try attribute.requireEnd("v2 stripping-protection attribute")
                // The attribute stores Android's scheme version (3), not the
                // signing-block pair ID.
                if referenced == 3,
                   !availableSchemes.contains(Self.v3BlockID),
                   !availableSchemes.contains(Self.v31BlockID) {
                    throw APKSignatureVerificationError.strippedScheme(Int(referenced))
                }
            }
        }
    }

    private func parseAndVerifyLineage(
        bytes: [UInt8],
        range: Range<Int>,
        currentCertificate: [UInt8]
    ) throws -> [String] {
        var lineage = LittleEndianReader(bytes, range: range)
        guard try lineage.u32("lineage version") == 1 else {
            throw APKSignatureVerificationError.malformed("unknown v3 lineage version")
        }

        var certificates: [ParsedCertificate] = []
        var priorNextAlgorithmID: UInt32 = 0
        var fingerprints = Set<String>()
        while !lineage.isAtEnd {
            guard certificates.count < Self.maximumCertificates else {
                throw APKSignatureVerificationError.malformed("too many rotation certificates")
            }
            let nodeRange = try lineage.lengthPrefixed32("rotation node")
            var node = LittleEndianReader(bytes, range: nodeRange)
            let signedDataRange = try node.lengthPrefixed32("rotation signed data")
            _ = try node.u32("rotation flags")
            let nextAlgorithmID = try node.u32("rotation next algorithm")
            let signatureRange = try node.lengthPrefixed32("rotation signature")
            try node.requireEnd("rotation node")

            var signedData = LittleEndianReader(bytes, range: signedDataRange)
            let certificateRange = try signedData.lengthPrefixed32("rotation certificate")
            let parentAlgorithmID = try signedData.u32("rotation parent algorithm")
            try signedData.requireEnd("rotation signed data")

            let certificateDER = Array(bytes[certificateRange])
            let certificate = try parseCertificate(certificateDER)
            let fingerprint = certificateFingerprint(certificateDER)
            guard fingerprints.insert(fingerprint).inserted else {
                throw APKSignatureVerificationError.malformed(
                    "duplicate certificate in v3 rotation history"
                )
            }

            if let prior = certificates.last {
                guard parentAlgorithmID == priorNextAlgorithmID,
                      let algorithm = APKSignatureAlgorithm(rawValue: parentAlgorithmID) else {
                    throw APKSignatureVerificationError.malformed(
                        "rotation signature algorithms do not link"
                    )
                }
                guard try verifySignature(
                    algorithm: algorithm,
                    signature: Array(bytes[signatureRange]),
                    message: Array(bytes[signedDataRange]),
                    publicKey: prior.subjectPublicKeyInfo
                ) else {
                    throw APKSignatureVerificationError.signatureInvalid
                }
            } else {
                guard parentAlgorithmID == 0, signatureRange.isEmpty else {
                    throw APKSignatureVerificationError.malformed(
                        "first rotation certificate has a parent signature"
                    )
                }
            }
            certificates.append(certificate)
            priorNextAlgorithmID = nextAlgorithmID
        }

        guard !certificates.isEmpty,
              certificates.last?.der == currentCertificate else {
            throw APKSignatureVerificationError.malformed(
                "rotation history does not contain the current certificate last"
            )
        }
        return certificates.map { certificateFingerprint($0.der) }
    }

    private func parseAlgorithmRecords(
        bytes: [UInt8],
        range: Range<Int>,
        label: String
    ) throws -> [AlgorithmRecord] {
        var reader = LittleEndianReader(bytes, range: range)
        var result: [AlgorithmRecord] = []
        var algorithmIDs = Set<UInt32>()
        while !reader.isAtEnd {
            guard result.count < Self.maximumRecords else {
                throw APKSignatureVerificationError.malformed("too many \(label)")
            }
            let recordRange = try reader.lengthPrefixed32(label)
            var record = LittleEndianReader(bytes, range: recordRange)
            let id = try record.u32("\(label) algorithm")
            guard algorithmIDs.insert(id).inserted else {
                throw APKSignatureVerificationError.malformed(
                    "duplicate algorithm in \(label)"
                )
            }
            let valueRange = try record.lengthPrefixed32("\(label) value")
            try record.requireEnd(label)
            result.append(AlgorithmRecord(id: id, value: Array(bytes[valueRange])))
        }
        guard !result.isEmpty else {
            throw APKSignatureVerificationError.malformed("\(label) are empty")
        }
        return result
    }

    private func selectAlgorithm(from records: [AlgorithmRecord]) throws -> SelectedAlgorithm {
        let supported = records.compactMap { record -> SelectedAlgorithm? in
            guard let algorithm = APKSignatureAlgorithm(rawValue: record.id),
                  algorithm.isSupported else { return nil }
            return SelectedAlgorithm(id: record.id, value: record.value, algorithm: algorithm)
        }
        guard let best = supported.max(by: {
            $0.algorithm.contentDigest.strength < $1.algorithm.contentDigest.strength
        }) else {
            throw APKSignatureVerificationError.unsupported(
                "no supported RSA or ECDSA signature algorithm"
            )
        }
        return best
    }

    private func requireMatchingAlgorithmLists(
        _ signatures: [AlgorithmRecord],
        _ digests: [AlgorithmRecord]
    ) throws {
        guard signatures.map(\.id) == digests.map(\.id) else {
            throw APKSignatureVerificationError.malformed(
                "signature and digest algorithm lists differ"
            )
        }
    }

    private func validateDigestLength(_ digest: [UInt8], kind: ContentDigestKind) throws {
        guard digest.count == kind.byteCount else {
            throw APKSignatureVerificationError.malformed("wrong APK content-digest length")
        }
    }

    private func parseCertificates(
        bytes: [UInt8],
        range: Range<Int>
    ) throws -> [ParsedCertificate] {
        var reader = LittleEndianReader(bytes, range: range)
        var result: [ParsedCertificate] = []
        while !reader.isAtEnd {
            guard result.count < Self.maximumCertificates else {
                throw APKSignatureVerificationError.malformed("too many certificates")
            }
            let certificateRange = try reader.lengthPrefixed32("certificate")
            result.append(try parseCertificate(Array(bytes[certificateRange])))
        }
        return result
    }

    private func contentDigest(
        bytes: [UInt8],
        layout: APKLayout,
        kind: ContentDigestKind
    ) throws -> [UInt8] {
        guard let signingBlockStart = layout.signingBlockStart else {
            throw APKSignatureVerificationError.malformed("modern scheme has no signing block")
        }
        var eocd = Array(bytes[layout.eocdOffset..<bytes.count])
        guard signingBlockStart <= Int(UInt32.max) else {
            throw APKSignatureVerificationError.unsupported("ZIP64 APK signing")
        }
        writeLE32(UInt32(signingBlockStart), into: &eocd, at: 16)

        var chunkDigests: [[UInt8]] = []
        let sourceSections = [
            0..<signingBlockStart,
            layout.centralDirectoryOffset..<layout.eocdOffset,
        ]
        for section in sourceSections {
            var start = section.lowerBound
            while start < section.upperBound {
                let end = min(section.upperBound, start + 1_048_576)
                var input = [UInt8(0xa5)]
                input.append(contentsOf: littleEndianBytes(UInt32(end - start)))
                input.append(contentsOf: bytes[start..<end])
                chunkDigests.append(hash(input, kind: kind.hashKind))
                start = end
            }
        }
        var eocdStart = 0
        while eocdStart < eocd.count {
            let end = min(eocd.count, eocdStart + 1_048_576)
            var input = [UInt8(0xa5)]
            input.append(contentsOf: littleEndianBytes(UInt32(end - eocdStart)))
            input.append(contentsOf: eocd[eocdStart..<end])
            chunkDigests.append(hash(input, kind: kind.hashKind))
            eocdStart = end
        }
        guard chunkDigests.count <= Int(UInt32.max) else {
            throw APKSignatureVerificationError.malformed("too many APK digest chunks")
        }
        var finalInput = [UInt8(0x5a)]
        finalInput.append(contentsOf: littleEndianBytes(UInt32(chunkDigests.count)))
        for digest in chunkDigests { finalInput.append(contentsOf: digest) }
        return hash(finalInput, kind: kind.hashKind)
    }

    // MARK: - JAR signing (v1)

    private func verifyV1(bytes: [UInt8], layout: APKLayout) throws -> APKSigningIdentity {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(bytes)
        } catch {
            throw APKSignatureVerificationError.malformed("invalid ZIP container")
        }
        var names = Set<String>()
        for entry in archive.entries where !names.insert(entry.name).inserted {
            throw APKSignatureVerificationError.malformed("duplicate ZIP entry \(entry.name)")
        }

        guard let manifestEntry = archive.entries.first(where: {
            $0.name.uppercased() == "META-INF/MANIFEST.MF"
        }) else {
            throw APKSignatureVerificationError.unsigned
        }
        let manifestBytes = try archive.data(for: manifestEntry)
        let manifest = try ManifestSections(bytes: manifestBytes)

        let signatureFiles = archive.entries.filter { $0.name.uppercased().hasSuffix(".SF") }
        guard !signatureFiles.isEmpty else {
            throw APKSignatureVerificationError.unsigned
        }

        try verifyManifestEntries(
            archive: archive,
            manifest: manifest,
            manifestBytes: manifestBytes
        )

        var signerFingerprints: [String] = []
        for sfEntry in signatureFiles {
            let sfBytes = try archive.data(for: sfEntry)
            let sf = try ManifestSections(bytes: sfBytes)
            try verifySignatureFile(
                sf,
                bytes: sfBytes,
                manifestBytes: manifestBytes,
                availableSchemes: Set(layout.schemeBlocks.keys)
            )

            let prefix = String(sfEntry.name.dropLast(3))
            guard let blockEntry = archive.entries.first(where: {
                let upper = $0.name.uppercased()
                let expectedPrefix = prefix.uppercased()
                return upper == expectedPrefix + ".RSA" ||
                    upper == expectedPrefix + ".EC" ||
                    upper == expectedPrefix + ".DSA"
            }) else {
                throw APKSignatureVerificationError.malformed(
                    "v1 signature file has no signature block"
                )
            }
            let cms = try archive.data(for: blockEntry)
            signerFingerprints.append(contentsOf: try verifyCMS(cms, content: sfBytes))
        }
        let unique = Array(Set(signerFingerprints)).sorted()
        guard !unique.isEmpty else { throw APKSignatureVerificationError.signatureInvalid }
        return APKSigningIdentity(
            scheme: .v1,
            signers: unique.map {
                .init(currentFingerprint: $0, certificateHistory: [$0])
            }
        )
    }

    private func verifySignatureFile(
        _ sf: ManifestSections,
        bytes sfBytes: [UInt8],
        manifestBytes: [UInt8],
        availableSchemes: Set<UInt32>
    ) throws {
        let main = sf.main
        if let declared = main["x-android-apk-signed"] {
            let schemes = Set(declared.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            })
            if schemes.contains(2), !availableSchemes.contains(Self.v2BlockID) {
                throw APKSignatureVerificationError.strippedScheme(2)
            }
            if schemes.contains(3),
               !availableSchemes.contains(Self.v3BlockID),
               !availableSchemes.contains(Self.v31BlockID) {
                throw APKSignatureVerificationError.strippedScheme(3)
            }
        }

        let candidates: [(String, HashKind)] = [
            ("sha-512-digest-manifest", .sha512),
            ("sha-384-digest-manifest", .sha384),
            ("sha-256-digest-manifest", .sha256),
        ]
        guard let candidate = candidates.first(where: { main[$0.0] != nil }),
              let encoded = main[candidate.0],
              let expected = Data(base64Encoded: encoded) else {
            throw APKSignatureVerificationError.unsupported(
                "v1 signature file lacks a SHA-256-or-stronger manifest digest"
            )
        }
        guard constantTimeEqual(hash(manifestBytes, kind: candidate.1), [UInt8](expected)) else {
            throw APKSignatureVerificationError.contentDigestMismatch
        }
        _ = sfBytes // The CMS signature authenticates these exact bytes below.
    }

    private func verifyManifestEntries(
        archive: ZipArchive,
        manifest: ManifestSections,
        manifestBytes: [UInt8]
    ) throws {
        _ = manifestBytes
        for entry in archive.entries {
            guard !entry.name.hasSuffix("/"), !isV1SignatureMetadata(entry.name) else { continue }
            guard let attributes = manifest.named[entry.name] else {
                throw APKSignatureVerificationError.contentDigestMismatch
            }
            let candidates: [(String, HashKind)] = [
                ("sha-512-digest", .sha512),
                ("sha-384-digest", .sha384),
                ("sha-256-digest", .sha256),
            ]
            guard let candidate = candidates.first(where: { attributes[$0.0] != nil }),
                  let encoded = attributes[candidate.0],
                  let expected = Data(base64Encoded: encoded) else {
                throw APKSignatureVerificationError.unsupported(
                    "v1 manifest entry \(entry.name) lacks a SHA-256-or-stronger digest"
                )
            }
            let payload = try archive.data(for: entry)
            guard constantTimeEqual(hash(payload, kind: candidate.1), [UInt8](expected)) else {
                throw APKSignatureVerificationError.contentDigestMismatch
            }
        }
    }

    private func isV1SignatureMetadata(_ name: String) -> Bool {
        let upper = name.uppercased()
        guard upper.hasPrefix("META-INF/") else { return false }
        let leaf = String(upper.dropFirst("META-INF/".count))
        return leaf == "MANIFEST.MF" || leaf.hasSuffix(".SF") ||
            leaf.hasSuffix(".RSA") || leaf.hasSuffix(".DSA") ||
            leaf.hasSuffix(".EC") || leaf.hasPrefix("SIG-")
    }

    // MARK: - CMS / DER

    private func verifyCMS(_ cms: [UInt8], content: [UInt8]) throws -> [String] {
        let root = try DERParser.single(cms)
        guard root.tag == 0x30 else {
            throw APKSignatureVerificationError.malformed("CMS ContentInfo is not a sequence")
        }
        let contentInfo = try DERParser.children(of: root, in: cms)
        guard contentInfo.count == 2,
              try DERParser.oid(contentInfo[0], in: cms) == "1.2.840.113549.1.7.2",
              contentInfo[1].tag == 0xa0 else {
            throw APKSignatureVerificationError.malformed("CMS is not SignedData")
        }
        let explicit = try DERParser.children(of: contentInfo[1], in: cms)
        guard explicit.count == 1, explicit[0].tag == 0x30 else {
            throw APKSignatureVerificationError.malformed("CMS SignedData wrapper is malformed")
        }
        let signedData = try DERParser.children(of: explicit[0], in: cms)
        guard signedData.count >= 4 else {
            throw APKSignatureVerificationError.malformed("CMS SignedData is truncated")
        }

        var index = 3 // version, digestAlgorithms, encapContentInfo
        var certificates: [ParsedCertificate] = []
        if index < signedData.count, signedData[index].tag == 0xa0 {
            for node in try DERParser.children(of: signedData[index], in: cms) where node.tag == 0x30 {
                certificates.append(try parseCertificate(Array(cms[node.encodedRange])))
                guard certificates.count <= Self.maximumCertificates else {
                    throw APKSignatureVerificationError.malformed("too many CMS certificates")
                }
            }
            index += 1
        }
        if index < signedData.count, signedData[index].tag == 0xa1 { index += 1 }
        guard !certificates.isEmpty,
              index < signedData.count,
              signedData[index].tag == 0x31 else {
            throw APKSignatureVerificationError.malformed("CMS signer information is absent")
        }
        let signerInfos = try DERParser.children(of: signedData[index], in: cms)
        guard !signerInfos.isEmpty, signerInfos.count <= Self.maximumSigners else {
            throw APKSignatureVerificationError.malformed("invalid CMS signer count")
        }

        var fingerprints: [String] = []
        for signerInfo in signerInfos {
            let fields = try DERParser.children(of: signerInfo, in: cms)
            guard fields.count >= 5, fields[0].tag == 0x02 else {
                throw APKSignatureVerificationError.malformed("CMS SignerInfo is truncated")
            }
            let digestOID = try algorithmOID(fields[2], bytes: cms)
            guard let digestKind = HashKind(oid: digestOID), digestKind.isStrong else {
                throw APKSignatureVerificationError.unsupported("weak CMS digest \(digestOID)")
            }

            var fieldIndex = 3
            var signedMessage = content
            if fields[fieldIndex].tag == 0xa0 {
                try verifyCMSSignedAttributes(
                    fields[fieldIndex],
                    bytes: cms,
                    content: content,
                    digestKind: digestKind
                )
                signedMessage = Array(cms[fields[fieldIndex].encodedRange])
                signedMessage[0] = 0x31 // IMPLICIT [0] becomes DER SET OF for signing.
                fieldIndex += 1
            }
            guard fieldIndex + 1 < fields.count,
                  fields[fieldIndex + 1].tag == 0x04 else {
                throw APKSignatureVerificationError.malformed("CMS signature is absent")
            }
            let signatureOID = try algorithmOID(fields[fieldIndex], bytes: cms)
            let signature = Array(cms[fields[fieldIndex + 1].contentRange])
            let keyKind = try CMSKeyKind(signatureOID: signatureOID)

            var matching: [ParsedCertificate] = []
            for certificate in certificates where (try? verifyDetachedSignature(
                keyKind: keyKind,
                digestKind: digestKind,
                signature: signature,
                message: signedMessage,
                publicKey: certificate.subjectPublicKeyInfo
            )) == true {
                matching.append(certificate)
            }
            guard matching.count == 1, let certificate = matching.first else {
                throw APKSignatureVerificationError.signatureInvalid
            }
            fingerprints.append(certificateFingerprint(certificate.der))
        }
        return fingerprints
    }

    private func verifyCMSSignedAttributes(
        _ node: DERNode,
        bytes: [UInt8],
        content: [UInt8],
        digestKind: HashKind
    ) throws {
        let attributes = try DERParser.children(of: node, in: bytes)
        var contentTypeOK = false
        var messageDigestOK = false
        for attribute in attributes {
            let fields = try DERParser.children(of: attribute, in: bytes)
            guard fields.count == 2, fields[1].tag == 0x31 else {
                throw APKSignatureVerificationError.malformed("CMS signed attribute is malformed")
            }
            let oid = try DERParser.oid(fields[0], in: bytes)
            let values = try DERParser.children(of: fields[1], in: bytes)
            if oid == "1.2.840.113549.1.9.3" {
                if values.count == 1 {
                    contentTypeOK = try DERParser.oid(values[0], in: bytes) ==
                        "1.2.840.113549.1.7.1"
                }
            } else if oid == "1.2.840.113549.1.9.4" {
                guard values.count == 1, values[0].tag == 0x04 else {
                    throw APKSignatureVerificationError.malformed("CMS messageDigest is malformed")
                }
                messageDigestOK = constantTimeEqual(
                    Array(bytes[values[0].contentRange]),
                    hash(content, kind: digestKind)
                )
            }
        }
        guard contentTypeOK, messageDigestOK else {
            throw APKSignatureVerificationError.contentDigestMismatch
        }
    }

    private func algorithmOID(_ node: DERNode, bytes: [UInt8]) throws -> String {
        guard node.tag == 0x30 else {
            throw APKSignatureVerificationError.malformed("algorithm identifier is not a sequence")
        }
        let children = try DERParser.children(of: node, in: bytes)
        guard let first = children.first else {
            throw APKSignatureVerificationError.malformed("empty algorithm identifier")
        }
        return try DERParser.oid(first, in: bytes)
    }

    // MARK: - Cryptographic helpers

    private func verifySignature(
        algorithm: APKSignatureAlgorithm,
        signature: [UInt8],
        message: [UInt8],
        publicKey: [UInt8]
    ) throws -> Bool {
        switch algorithm {
        case .rsaPSSSHA256:
            return try verifyRSA(
                signature: signature, message: message, publicKey: publicKey,
                digest: .sha256, padding: .PSS
            )
        case .rsaPSSSHA512:
            return try verifyRSA(
                signature: signature, message: message, publicKey: publicKey,
                digest: .sha512, padding: .PSS
            )
        case .rsaPKCS1SHA256:
            return try verifyRSA(
                signature: signature, message: message, publicKey: publicKey,
                digest: .sha256, padding: .insecurePKCS1v1_5
            )
        case .rsaPKCS1SHA512:
            return try verifyRSA(
                signature: signature, message: message, publicKey: publicKey,
                digest: .sha512, padding: .insecurePKCS1v1_5
            )
        case .ecdsaSHA256:
            return try verifyECDSA(
                signature: signature, message: message, publicKey: publicKey, digest: .sha256
            )
        case .ecdsaSHA512:
            return try verifyECDSA(
                signature: signature, message: message, publicKey: publicKey, digest: .sha512
            )
        default:
            throw APKSignatureVerificationError.unsupported(
                String(format: "signature algorithm 0x%04x", algorithm.rawValue)
            )
        }
    }

    private func verifyDetachedSignature(
        keyKind: CMSKeyKind,
        digestKind: HashKind,
        signature: [UInt8],
        message: [UInt8],
        publicKey: [UInt8]
    ) throws -> Bool {
        switch keyKind {
        case .rsa:
            return try verifyRSA(
                signature: signature,
                message: message,
                publicKey: publicKey,
                digest: digestKind,
                padding: .insecurePKCS1v1_5,
                allowLegacyKey: true
            )
        case .ecdsa:
            return try verifyECDSA(
                signature: signature,
                message: message,
                publicKey: publicKey,
                digest: digestKind
            )
        }
    }

    private func verifyRSA(
        signature: [UInt8],
        message: [UInt8],
        publicKey: [UInt8],
        digest: HashKind,
        padding: _RSA.Signing.Padding,
        allowLegacyKey: Bool = false
    ) throws -> Bool {
        let key = allowLegacyKey
            ? try _RSA.Signing.PublicKey(unsafeDERRepresentation: Data(publicKey))
            : try _RSA.Signing.PublicKey(derRepresentation: Data(publicKey))
        let signature = _RSA.Signing.RSASignature(rawRepresentation: Data(signature))
        let data = Data(message)
        switch digest {
        case .sha256:
            return key.isValidSignature(signature, for: SHA256.hash(data: data), padding: padding)
        case .sha384:
            return key.isValidSignature(signature, for: SHA384.hash(data: data), padding: padding)
        case .sha512:
            return key.isValidSignature(signature, for: SHA512.hash(data: data), padding: padding)
        case .sha1:
            return key.isValidSignature(
                signature, for: Insecure.SHA1.hash(data: data), padding: padding
            )
        }
    }

    private func verifyECDSA(
        signature: [UInt8],
        message: [UInt8],
        publicKey: [UInt8],
        digest: HashKind
    ) throws -> Bool {
        let data = Data(message)
        let keyData = Data(publicKey)
        let signatureData = Data(signature)

        if let key = try? P256.Signing.PublicKey(derRepresentation: keyData),
           let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) {
            switch digest {
            case .sha256: return key.isValidSignature(signature, for: SHA256.hash(data: data))
            case .sha384: return key.isValidSignature(signature, for: SHA384.hash(data: data))
            case .sha512: return key.isValidSignature(signature, for: SHA512.hash(data: data))
            case .sha1: return key.isValidSignature(signature, for: Insecure.SHA1.hash(data: data))
            }
        }
        if let key = try? P384.Signing.PublicKey(derRepresentation: keyData),
           let signature = try? P384.Signing.ECDSASignature(derRepresentation: signatureData) {
            switch digest {
            case .sha256: return key.isValidSignature(signature, for: SHA256.hash(data: data))
            case .sha384: return key.isValidSignature(signature, for: SHA384.hash(data: data))
            case .sha512: return key.isValidSignature(signature, for: SHA512.hash(data: data))
            case .sha1: return key.isValidSignature(signature, for: Insecure.SHA1.hash(data: data))
            }
        }
        if let key = try? P521.Signing.PublicKey(derRepresentation: keyData),
           let signature = try? P521.Signing.ECDSASignature(derRepresentation: signatureData) {
            switch digest {
            case .sha256: return key.isValidSignature(signature, for: SHA256.hash(data: data))
            case .sha384: return key.isValidSignature(signature, for: SHA384.hash(data: data))
            case .sha512: return key.isValidSignature(signature, for: SHA512.hash(data: data))
            case .sha1: return key.isValidSignature(signature, for: Insecure.SHA1.hash(data: data))
            }
        }
        return false
    }
}

// MARK: - Internal wire models

private struct ParsedSigner {
    let signer: APKSigningIdentity.Signer
    let digestKind: ContentDigestKind
    let expectedDigest: [UInt8]
}

private struct AlgorithmRecord {
    let id: UInt32
    let value: [UInt8]
}

private struct SelectedAlgorithm {
    let id: UInt32
    let value: [UInt8]
    let algorithm: APKSignatureAlgorithm
}

private enum ContentDigestKind: Hashable {
    case chunkedSHA256
    case chunkedSHA512
    case veritySHA256

    var hashKind: HashKind {
        switch self {
        case .chunkedSHA256, .veritySHA256: return .sha256
        case .chunkedSHA512: return .sha512
        }
    }

    var byteCount: Int {
        switch self {
        case .chunkedSHA256: return 32
        case .chunkedSHA512: return 64
        case .veritySHA256: return 40
        }
    }

    var strength: Int {
        switch self {
        case .chunkedSHA256: return 1
        case .veritySHA256: return 2
        case .chunkedSHA512: return 3
        }
    }
}

private enum APKSignatureAlgorithm: UInt32 {
    case rsaPSSSHA256 = 0x0101
    case rsaPSSSHA512 = 0x0102
    case rsaPKCS1SHA256 = 0x0103
    case rsaPKCS1SHA512 = 0x0104
    case ecdsaSHA256 = 0x0201
    case ecdsaSHA512 = 0x0202
    case dsaSHA256 = 0x0301
    case verityRSASHA256 = 0x0421
    case verityECDSASHA256 = 0x0423
    case verityDSASHA256 = 0x0425

    var contentDigest: ContentDigestKind {
        switch self {
        case .rsaPSSSHA512, .rsaPKCS1SHA512, .ecdsaSHA512:
            return .chunkedSHA512
        case .verityRSASHA256, .verityECDSASHA256, .verityDSASHA256:
            return .veritySHA256
        default:
            return .chunkedSHA256
        }
    }

    var isSupported: Bool {
        switch self {
        case .rsaPSSSHA256, .rsaPSSSHA512, .rsaPKCS1SHA256,
             .rsaPKCS1SHA512, .ecdsaSHA256, .ecdsaSHA512:
            return true
        default:
            return false
        }
    }
}

private enum HashKind {
    case sha1
    case sha256
    case sha384
    case sha512

    init?(oid: String) {
        switch oid {
        case "1.3.14.3.2.26": self = .sha1
        case "2.16.840.1.101.3.4.2.1": self = .sha256
        case "2.16.840.1.101.3.4.2.2": self = .sha384
        case "2.16.840.1.101.3.4.2.3": self = .sha512
        default: return nil
        }
    }

    var isStrong: Bool { self != .sha1 }
}

private enum CMSKeyKind {
    case rsa
    case ecdsa

    init(signatureOID: String) throws {
        switch signatureOID {
        case "1.2.840.113549.1.1.1", // rsaEncryption
             "1.2.840.113549.1.1.11", // sha256WithRSAEncryption
             "1.2.840.113549.1.1.12", // sha384WithRSAEncryption
             "1.2.840.113549.1.1.13": // sha512WithRSAEncryption
            self = .rsa
        case "1.2.840.10045.4.3.2", "1.2.840.10045.4.3.3", "1.2.840.10045.4.3.4":
            self = .ecdsa
        default:
            throw APKSignatureVerificationError.unsupported(
                "CMS signature algorithm \(signatureOID)"
            )
        }
    }
}

private struct APKLayout {
    let eocdOffset: Int
    let centralDirectoryOffset: Int
    let signingBlockStart: Int?
    let schemeBlocks: [UInt32: Range<Int>]

    init(bytes: [UInt8]) throws {
        guard let eocd = Self.locateEOCD(bytes) else {
            throw APKSignatureVerificationError.malformed("ZIP end record not found")
        }
        guard readLE16(bytes, at: eocd + 4) == 0,
              readLE16(bytes, at: eocd + 6) == 0,
              readLE16(bytes, at: eocd + 8) == readLE16(bytes, at: eocd + 10) else {
            throw APKSignatureVerificationError.unsupported("multi-disk ZIP")
        }
        let directorySize = Int(readLE32(bytes, at: eocd + 12))
        let directoryOffset32 = readLE32(bytes, at: eocd + 16)
        guard directoryOffset32 != UInt32.max else {
            throw APKSignatureVerificationError.unsupported("ZIP64 APK signing")
        }
        let directoryOffset = Int(directoryOffset32)
        guard directoryOffset >= 0,
              directorySize >= 0,
              directoryOffset <= eocd,
              directorySize == eocd - directoryOffset else {
            throw APKSignatureVerificationError.malformed("central-directory bounds are invalid")
        }
        self.eocdOffset = eocd
        self.centralDirectoryOffset = directoryOffset

        guard directoryOffset >= 24,
              Array(bytes[(directoryOffset - 16)..<directoryOffset]) ==
                APKSignatureVerifier.signingBlockMagic else {
            self.signingBlockStart = nil
            self.schemeBlocks = [:]
            return
        }
        let trailingSize = readLE64(bytes, at: directoryOffset - 24)
        guard trailingSize >= 24,
              trailingSize <= UInt64(APKSignatureVerifier.maximumSigningBlockSize),
              trailingSize <= UInt64(directoryOffset - 8) else {
            throw APKSignatureVerificationError.malformed("APK Signing Block size is invalid")
        }
        let start = directoryOffset - Int(trailingSize) - 8
        guard start >= 0,
              readLE64(bytes, at: start) == trailingSize else {
            throw APKSignatureVerificationError.malformed("APK Signing Block sizes differ")
        }

        var reader = LittleEndianReader(bytes, range: (start + 8)..<(directoryOffset - 24))
        var blocks: [UInt32: Range<Int>] = [:]
        var pairCount = 0
        while !reader.isAtEnd {
            pairCount += 1
            guard pairCount <= APKSignatureVerifier.maximumRecords else {
                throw APKSignatureVerificationError.malformed("too many signing-block pairs")
            }
            let length = try reader.u64("signing-block pair length")
            guard length >= 4, length <= UInt64(Int.max), Int(length) <= reader.remaining else {
                throw APKSignatureVerificationError.malformed("signing-block pair is out of bounds")
            }
            let pairEnd = reader.offset + Int(length)
            let id = try reader.u32("signing-block pair ID")
            let isKnownScheme = id == 0x7109_871a || id == 0xf053_68c0 || id == 0x1b93_ad61
            guard blocks[id] == nil || !isKnownScheme else {
                throw APKSignatureVerificationError.malformed("duplicate signing-block pair")
            }
            if blocks[id] == nil { blocks[id] = reader.offset..<pairEnd }
            try reader.seek(pairEnd, "signing-block pair")
        }
        self.signingBlockStart = start
        self.schemeBlocks = blocks
    }

    private static func locateEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lower = max(0, bytes.count - 65_557)
        var offset = bytes.count - 22
        while offset >= lower {
            if readLE32(bytes, at: offset) == 0x0605_4b50 {
                let commentLength = Int(readLE16(bytes, at: offset + 20))
                if offset + 22 + commentLength == bytes.count { return offset }
            }
            offset -= 1
        }
        return nil
    }
}

private struct LittleEndianReader {
    let bytes: [UInt8]
    private let end: Int
    private(set) var offset: Int

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = range.upperBound
    }

    var remaining: Int { end - offset }
    var isAtEnd: Bool { offset == end }
    var remainingRange: Range<Int> { offset..<end }

    mutating func seek(_ target: Int, _ label: String) throws {
        guard target >= offset, target <= end else {
            throw APKSignatureVerificationError.malformed("\(label) exceeds its container")
        }
        offset = target
    }

    mutating func u32(_ label: String) throws -> UInt32 {
        guard remaining >= 4 else {
            throw APKSignatureVerificationError.malformed("\(label) is truncated")
        }
        defer { offset += 4 }
        return readLE32(bytes, at: offset)
    }

    mutating func u64(_ label: String) throws -> UInt64 {
        guard remaining >= 8 else {
            throw APKSignatureVerificationError.malformed("\(label) is truncated")
        }
        defer { offset += 8 }
        return readLE64(bytes, at: offset)
    }

    mutating func lengthPrefixed32(_ label: String) throws -> Range<Int> {
        let length = try u32("\(label) length")
        guard UInt64(length) <= UInt64(Int.max), Int(length) <= remaining else {
            throw APKSignatureVerificationError.malformed("\(label) is out of bounds")
        }
        let range = offset..<(offset + Int(length))
        offset = range.upperBound
        return range
    }

    func requireEnd(_ label: String) throws {
        guard isAtEnd else {
            throw APKSignatureVerificationError.malformed("\(label) has trailing bytes")
        }
    }
}

private struct ParsedCertificate {
    let der: [UInt8]
    let subjectPublicKeyInfo: [UInt8]
}

private struct DERNode {
    let tag: UInt8
    let encodedRange: Range<Int>
    let contentRange: Range<Int>
}

private enum DERParser {
    static func single(_ bytes: [UInt8]) throws -> DERNode {
        var offset = 0
        let node = try read(bytes, offset: &offset, end: bytes.count)
        guard offset == bytes.count else {
            throw APKSignatureVerificationError.malformed("DER has trailing bytes")
        }
        return node
    }

    static func children(of node: DERNode, in bytes: [UInt8]) throws -> [DERNode] {
        guard node.tag & 0x20 != 0 else {
            throw APKSignatureVerificationError.malformed("primitive DER node has children")
        }
        var offset = node.contentRange.lowerBound
        var result: [DERNode] = []
        while offset < node.contentRange.upperBound {
            guard result.count < 256 else {
                throw APKSignatureVerificationError.malformed("too many DER children")
            }
            result.append(try read(bytes, offset: &offset, end: node.contentRange.upperBound))
        }
        guard offset == node.contentRange.upperBound else {
            throw APKSignatureVerificationError.malformed("DER child overruns parent")
        }
        return result
    }

    static func oid(_ node: DERNode, in bytes: [UInt8]) throws -> String {
        guard node.tag == 0x06 else {
            throw APKSignatureVerificationError.malformed("expected DER object identifier")
        }
        let value = Array(bytes[node.contentRange])
        guard let first = value.first else {
            throw APKSignatureVerificationError.malformed("empty DER object identifier")
        }
        var components = [Int(first) / 40, Int(first) % 40]
        var accumulator: UInt64 = 0
        var inComponent = false
        for byte in value.dropFirst() {
            inComponent = true
            guard accumulator <= (UInt64.max >> 7) else {
                throw APKSignatureVerificationError.malformed("DER OID component overflows")
            }
            accumulator = (accumulator << 7) | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 {
                guard accumulator <= UInt64(Int.max) else {
                    throw APKSignatureVerificationError.malformed("DER OID component is too large")
                }
                components.append(Int(accumulator))
                accumulator = 0
                inComponent = false
            }
        }
        guard !inComponent else {
            throw APKSignatureVerificationError.malformed("truncated DER object identifier")
        }
        return components.map(String.init).joined(separator: ".")
    }

    private static func read(
        _ bytes: [UInt8],
        offset: inout Int,
        end: Int
    ) throws -> DERNode {
        let start = offset
        guard offset < end else {
            throw APKSignatureVerificationError.malformed("DER node is truncated")
        }
        let tag = bytes[offset]
        offset += 1
        guard tag & 0x1f != 0x1f, offset < end else {
            throw APKSignatureVerificationError.malformed("unsupported DER tag")
        }
        let firstLength = bytes[offset]
        offset += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7f)
            guard count > 0, count <= 4, count <= end - offset,
                  bytes[offset] != 0 else {
                throw APKSignatureVerificationError.malformed("invalid DER length")
            }
            var value = 0
            for _ in 0..<count {
                guard value <= (Int.max >> 8) else {
                    throw APKSignatureVerificationError.malformed("DER length overflows")
                }
                value = (value << 8) | Int(bytes[offset])
                offset += 1
            }
            guard value >= 128 else {
                throw APKSignatureVerificationError.malformed("non-minimal DER length")
            }
            length = value
        }
        guard length <= end - offset else {
            throw APKSignatureVerificationError.malformed("DER content is truncated")
        }
        let content = offset..<(offset + length)
        offset = content.upperBound
        return DERNode(tag: tag, encodedRange: start..<offset, contentRange: content)
    }
}

private func parseCertificate(_ bytes: [UInt8]) throws -> ParsedCertificate {
    let certificate = try DERParser.single(bytes)
    guard certificate.tag == 0x30 else {
        throw APKSignatureVerificationError.malformed("certificate is not a DER sequence")
    }
    let certificateFields = try DERParser.children(of: certificate, in: bytes)
    guard certificateFields.count == 3, certificateFields[0].tag == 0x30 else {
        throw APKSignatureVerificationError.malformed("X.509 certificate is truncated")
    }
    let tbsFields = try DERParser.children(of: certificateFields[0], in: bytes)
    let hasVersion = tbsFields.first?.tag == 0xa0
    let spkiIndex = hasVersion ? 6 : 5
    guard spkiIndex < tbsFields.count, tbsFields[spkiIndex].tag == 0x30 else {
        throw APKSignatureVerificationError.malformed("certificate public key is absent")
    }
    return ParsedCertificate(
        der: bytes,
        subjectPublicKeyInfo: Array(bytes[tbsFields[spkiIndex].encodedRange])
    )
}

private struct ManifestSections {
    let main: [String: String]
    let named: [String: [String: String]]

    init(bytes: [UInt8]) throws {
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var sections: [[String: String]] = []
        var current: [String: String] = [:]
        var lastKey: String?

        func appendSection() {
            if !current.isEmpty { sections.append(current) }
            current = [:]
            lastKey = nil
        }

        for rawLine in lines {
            let line = String(rawLine)
            if line.isEmpty {
                appendSection()
                continue
            }
            if line.first == " " {
                guard let key = lastKey else { throw APKSignatureVerificationError.malformed(
                    "manifest continuation has no attribute"
                ) }
                current[key, default: ""] += String(line.dropFirst())
                continue
            }
            guard let separator = line.firstIndex(of: ":"),
                  line.index(after: separator) < line.endIndex,
                  line[line.index(after: separator)] == " " else {
                throw APKSignatureVerificationError.malformed("invalid manifest attribute")
            }
            let key = String(line[..<separator]).lowercased()
            let valueStart = line.index(separator, offsetBy: 2)
            guard current[key] == nil else {
                throw APKSignatureVerificationError.malformed("duplicate manifest attribute")
            }
            current[key] = String(line[valueStart...])
            lastKey = key
        }
        appendSection()
        guard let first = sections.first else {
            throw APKSignatureVerificationError.malformed("empty manifest")
        }
        var named: [String: [String: String]] = [:]
        for section in sections.dropFirst() {
            guard let name = section["name"], named[name] == nil else {
                throw APKSignatureVerificationError.malformed("invalid manifest name section")
            }
            named[name] = section
        }
        self.main = first
        self.named = named
    }
}

private func hash(_ bytes: [UInt8], kind: HashKind) -> [UInt8] {
    let data = Data(bytes)
    switch kind {
    case .sha1: return Array(Insecure.SHA1.hash(data: data))
    case .sha256: return Array(SHA256.hash(data: data))
    case .sha384: return Array(SHA384.hash(data: data))
    case .sha512: return Array(SHA512.hash(data: data))
    }
}

private func certificateFingerprint(_ certificate: [UInt8]) -> String {
    SHA256.hash(data: Data(certificate)).map { String(format: "%02x", $0) }.joined()
}

private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
}

private func littleEndianBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
    ]
}

private func writeLE32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    let encoded = littleEndianBytes(value)
    for index in 0..<4 { bytes[offset + index] = encoded[index] }
}

private func readLE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) |
        UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 |
        UInt32(bytes[offset + 3]) << 24
}

private func readLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    UInt64(readLE32(bytes, at: offset)) | UInt64(readLE32(bytes, at: offset + 4)) << 32
}
