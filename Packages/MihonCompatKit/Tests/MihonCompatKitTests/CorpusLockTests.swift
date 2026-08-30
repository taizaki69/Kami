import Foundation
import XCTest
@testable import MihonCompatKit

final class CorpusLockTests: XCTestCase {
    private struct Lock: Decodable {
        let schemaVersion: Int
        let locked: String
        let upstream: Upstream
        let selection: Selection
        let artifacts: [Artifact]
    }

    private struct Upstream: Decodable {
        let catalogRepository: String
        let catalogBranch: String
        let catalogRevision: String
        let sourceRepository: String
        let sourceRevision: String
    }

    private struct Selection: Decodable {
        let currentLib16ArtifactCount: Int
        let executionArtifactCount: Int
        let measurementArtifactCount: Int
        let conformanceArtifactCount: Int
        let measurementPolicy: String
    }

    private struct Artifact: Decodable {
        let name: String
        let path: String
        let role: String
        let package: String?
        let version: String?
        let versionCode: Int64?
        let extensionLib: String?
        let sourceCount: Int?
        let contentWarning: String?
        let behaviorFamily: String?
        let sourceRevision: String?
        let license: String?
        let url: String
        let sha256: String
    }

    private struct Baseline: Decodable {
        let formatVersion: Int
        let artifacts: [BaselineArtifact]
        let aggregate: BaselineAggregate
    }

    private struct BaselineArtifact: Decodable, Equatable {
        let identity: String
        let structuralCandidate: Bool
        let planBlockers: [String]
        let dexCount: Int
        let codeMethodCount: Int
        let instructionCount: Int
        let uniqueUnregisteredExternalMethodCount: Int
        let omittedExternalInvocationCount: Int
        let unsupportedOpcodes: [String]
    }

    private struct BaselineAggregate: Decodable, Equatable {
        let extensionCount: Int
        let structuralCandidateCount: Int
        let planBlockers: [BaselineBlocker]
        let uniqueUnregisteredExternalMethodCount: Int
        let omittedExternalInvocationCount: Int
        let unsupportedOpcodeCount: Int
        let topLimit: Int
        let topUnregisteredExternalInvocations: [BaselineMethod]
    }

    private struct BaselineBlocker: Decodable, Equatable {
        let summary: String
        let extensionCount: Int
    }

    private struct BaselineMethod: Decodable, Equatable {
        let surface: String
        let extensionCount: Int
        let invocationCount: Int
    }

    func testCorpusLockHasBoundedSeparatedRolesAndMatchesFetcher() throws {
        let lock = try loadLock()
        XCTAssertEqual(lock.schemaVersion, 2)
        XCTAssertEqual(lock.locked, "2026-08-29")
        XCTAssertEqual(lock.upstream.catalogRepository, "https://github.com/keiyoushi/extensions")
        XCTAssertEqual(lock.upstream.catalogBranch, "repo")
        XCTAssertEqual(
            lock.upstream.sourceRepository,
            "https://github.com/keiyoushi/extensions-source"
        )
        XCTAssertTrue(lock.upstream.catalogRevision.allSatisfy(\.isHexDigit))
        XCTAssertTrue(lock.upstream.sourceRevision.allSatisfy(\.isHexDigit))
        XCTAssertEqual(lock.upstream.catalogRevision.count, 40)
        XCTAssertEqual(lock.upstream.sourceRevision.count, 40)
        XCTAssertEqual(lock.artifacts.count, 27)
        XCTAssertEqual(lock.selection.executionArtifactCount, 6)
        XCTAssertEqual(lock.selection.measurementArtifactCount, 15)
        XCTAssertEqual(lock.selection.conformanceArtifactCount, 6)
        XCTAssertEqual(
            lock.selection.currentLib16ArtifactCount,
            lock.artifacts.filter { $0.package != nil && $0.extensionLib == "1.6" }.count
        )
        XCTAssertTrue(lock.selection.measurementPolicy.contains("never grants signer trust"))

        XCTAssertEqual(Set(lock.artifacts.map(\.name)).count, lock.artifacts.count)
        XCTAssertEqual(Set(lock.artifacts.map(\.path)).count, lock.artifacts.count)
        XCTAssertEqual(
            Set(lock.artifacts.compactMap(\.package)).count,
            lock.artifacts.compactMap(\.package).count
        )

        let byRole = Dictionary(grouping: lock.artifacts, by: \.role)
        XCTAssertEqual(byRole["execution"]?.count, 6)
        XCTAssertEqual(byRole["measurement"]?.count, 15)
        XCTAssertEqual(byRole["conformance"]?.count, 6)
        XCTAssertEqual(Set(byRole.keys), ["execution", "measurement", "conformance"])

        XCTAssertEqual(Set(byRole["execution", default: []].map(\.name)), [
            "akuma", "mangadex", "batcave", "kawiimanga", "mangamelon",
            "baozimanhua",
        ])
        XCTAssertEqual(Set(byRole["measurement", default: []].map(\.name)), [
            "doctruyen3q", "eternalmangas", "foolslidecustomizable", "hayalistic",
            "komga", "komikcast", "mangapandaonl", "mangaplus", "mangasoriginesfr",
            "nhentaixxx", "pixivcomic", "readmanga", "sssscanlator",
            "tuttoanimemanga", "xcomic",
        ])

        let fetcher = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/fetch_corpus.sh"),
            encoding: .utf8
        )
        let aospRevision = "184702d9d18877edf9e5296c4e191cf0aa2b5fbb"
        let expectedRealRows = Set(lock.artifacts
            .filter { $0.role == "execution" || $0.role == "measurement" }
            .map {
                "\(String($0.path.dropLast(4)))|\($0.url)|\($0.sha256)"
            })
        let actualRealRows = try fetchTable(named: "LOCKED_REAL_APKS", from: fetcher)
        XCTAssertEqual(actualRealRows.count, expectedRealRows.count)
        XCTAssertEqual(Set(actualRealRows), expectedRealRows)

        var expectedAOSPRows = Set<String>()
        for artifact in byRole["conformance", default: []] {
            expectedAOSPRows.insert(
                "\(String(artifact.path.dropLast(4)))|\(artifact.url)|\(artifact.sha256)"
            )
        }
        let actualAOSPRows = try fetchTable(named: "LOCKED_AOSP_APKS", from: fetcher)
        XCTAssertEqual(actualAOSPRows.count, expectedAOSPRows.count)
        XCTAssertEqual(Set(actualAOSPRows), expectedAOSPRows)

        let lowercaseHex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        for artifact in lock.artifacts {
            XCTAssertTrue(artifact.path.hasSuffix(".apk"), artifact.name)
            XCTAssertFalse(artifact.path.hasPrefix("/"), artifact.name)
            XCTAssertFalse(artifact.path.contains("\\"), artifact.name)
            XCTAssertFalse(
                artifact.path.split(separator: "/").contains { $0 == "." || $0 == ".." },
                artifact.name
            )
            let hashRange = NSRange(artifact.sha256.startIndex..., in: artifact.sha256)
            XCTAssertNotNil(lowercaseHex.firstMatch(in: artifact.sha256, range: hashRange), artifact.name)
            let sourceURL = try XCTUnwrap(URL(string: artifact.url), artifact.name)
            XCTAssertEqual(sourceURL.scheme, "https", artifact.name)
            XCTAssertNotNil(sourceURL.host, artifact.name)

            switch artifact.role {
            case "execution":
                XCTAssertFalse(artifact.path.contains("/"), artifact.name)
                XCTAssertEqual(sourceURL.host, "github.com", artifact.name)
                XCTAssertTrue(
                    sourceURL.path.hasPrefix("/keiyoushi/extensions/releases/download/"),
                    artifact.name
                )
                XCTAssertTrue(["safe", "mixed", "nsfw"].contains(artifact.contentWarning), artifact.name)
            case "measurement":
                XCTAssertTrue(artifact.path.hasPrefix("measurement/"), artifact.name)
                XCTAssertEqual(artifact.extensionLib, "1.6", artifact.name)
                XCTAssertEqual(sourceURL.host, "github.com", artifact.name)
                XCTAssertTrue(
                    sourceURL.path.hasPrefix("/keiyoushi/extensions/releases/download/"),
                    artifact.name
                )
                XCTAssertNotNil(artifact.behaviorFamily, artifact.name)
                XCTAssertGreaterThan(artifact.sourceCount ?? 0, 0, artifact.name)
                XCTAssertTrue(["safe", "mixed", "nsfw"].contains(artifact.contentWarning), artifact.name)
            case "conformance":
                XCTAssertNil(artifact.package, artifact.name)
                XCTAssertEqual(artifact.path, "\(artifact.name).apk", artifact.name)
                XCTAssertEqual(
                    artifact.sourceRevision,
                    "platform/tools/apksig@\(aospRevision)",
                    artifact.name
                )
                XCTAssertEqual(artifact.license, "Apache-2.0", artifact.name)
                XCTAssertEqual(sourceURL.host, "android.googlesource.com", artifact.name)
                XCTAssertEqual(sourceURL.query, "format=TEXT", artifact.name)
                XCTAssertEqual(
                    artifact.url,
                    "https://android.googlesource.com/platform/tools/apksig/+/\(aospRevision)" +
                        "/src/test/resources/com/android/apksig/\(sourceURL.lastPathComponent)?format=TEXT",
                    artifact.name
                )
            default:
                XCTFail("unexpected corpus role \(artifact.role)")
            }
        }

        for artifact in byRole["conformance", default: []] {
            let fileURL = corpusRoot.appendingPathComponent(artifact.path)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            XCTAssertTrue(exists, artifact.name)
            guard exists else { continue }
            let bytes = [UInt8](try Data(contentsOf: fileURL, options: .mappedIfSafe))
            XCTAssertEqual(APKSignatureVerifier.apkSHA256(bytes), artifact.sha256, artifact.name)
        }
    }

    func testDownloadedCorpusMatchesHashesManifestsAndReleaseSignatures() throws {
        let lock = try loadLock()
        let downloadedArtifacts = lock.artifacts.filter { $0.role != "conformance" }
        let downloadedPresent = downloadedArtifacts.filter { artifact in
            FileManager.default.fileExists(
                atPath: corpusRoot.appendingPathComponent(artifact.path).path
            )
        }
        guard !downloadedPresent.isEmpty else {
            throw XCTSkip("measurement corpus absent — run scripts/fetch_corpus.sh")
        }
        let missingArtifacts = lock.artifacts.filter { artifact in
            !FileManager.default.fileExists(
                atPath: corpusRoot.appendingPathComponent(artifact.path).path
            )
        }.map(\.path).sorted()
        XCTAssertTrue(
            missingArtifacts.isEmpty,
            "partial corpus; missing: \(missingArtifacts.joined(separator: ", "))"
        )
        guard missingArtifacts.isEmpty else { return }

        let verifier = APKSignatureVerifier()
        for artifact in lock.artifacts {
            let url = corpusRoot.appendingPathComponent(artifact.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), artifact.name)
            let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
            XCTAssertLessThanOrEqual(bytes.count, APKSignatureVerifier.maximumAPKSize, artifact.name)
            XCTAssertEqual(APKSignatureVerifier.apkSHA256(bytes), artifact.sha256, artifact.name)

            guard artifact.role != "conformance" else { continue }
            let manifest = try ExtensionManifest(apkBytes: bytes)
            XCTAssertTrue(manifest.declaresExtensionFeature, artifact.name)
            XCTAssertEqual(manifest.packageName, artifact.package, artifact.name)
            XCTAssertEqual(manifest.versionName, artifact.version, artifact.name)
            XCTAssertEqual(manifest.versionCode, artifact.versionCode, artifact.name)
            XCTAssertEqual(manifest.extensionLibVersion, artifact.extensionLib, artifact.name)

            if artifact.role == "measurement" {
                XCTAssertNoThrow(try verifier.verify(apkBytes: bytes), artifact.name)
            }
        }
    }

    func testMeasurementCorpusMatchesDeterministicStaticBaseline() throws {
        let lock = try loadLock()
        let measurement = lock.artifacts.filter { $0.role == "measurement" }
        let present = measurement.filter { artifact in
            FileManager.default.fileExists(
                atPath: corpusRoot.appendingPathComponent(artifact.path).path
            )
        }
        guard !present.isEmpty else {
            throw XCTSkip("measurement corpus absent — run scripts/fetch_corpus.sh")
        }
        let missing = measurement.filter { artifact in
            !FileManager.default.fileExists(
                atPath: corpusRoot.appendingPathComponent(artifact.path).path
            )
        }.map(\.path).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "partial measurement corpus; missing: \(missing.joined(separator: ", "))"
        )
        guard missing.isEmpty else { return }
        let expected = try JSONDecoder().decode(
            Baseline.self,
            from: Data(contentsOf: corpusRoot.appendingPathComponent("measurement-baseline.json"))
        )
        XCTAssertEqual(expected.formatVersion, 1)

        let auditor = InterpretedCompatibilityAudit()
        let reports = try measurement.map { artifact in
            let bytes = [UInt8](try Data(
                contentsOf: corpusRoot.appendingPathComponent(artifact.path),
                options: .mappedIfSafe
            ))
            return try auditor.analyze(apkBytes: bytes)
        }
        let actualArtifacts = reports.map { report in
            BaselineArtifact(
                identity: report.identity,
                structuralCandidate: report.planStatus.isStructuralCandidate,
                planBlockers: report.planStatus.blockers.map(\.summary),
                dexCount: report.dexCount,
                codeMethodCount: report.codeMethodCount,
                instructionCount: report.instructionCount,
                uniqueUnregisteredExternalMethodCount: report.unregisteredExternalInvocations.count,
                omittedExternalInvocationCount: report.omittedExternalInvocationCount,
                unsupportedOpcodes: report.unsupportedOpcodes.map {
                    String(format: "0x%02x", $0.opcode)
                }
            )
        }.sorted { $0.identity < $1.identity }
        XCTAssertEqual(actualArtifacts, expected.artifacts)

        let aggregate = InterpretedCompatibilityAudit.aggregate(reports)
        XCTAssertEqual(expected.aggregate.topLimit, 5)
        XCTAssertEqual(
            aggregate,
            InterpretedCompatibilityAudit.aggregate(Array(reports.reversed()))
        )
        let actualAggregate = BaselineAggregate(
            extensionCount: aggregate.extensionCount,
            structuralCandidateCount: aggregate.structuralCandidateCount,
            planBlockers: aggregate.planBlockers.map {
                BaselineBlocker(
                    summary: $0.blocker.summary,
                    extensionCount: $0.extensionCount
                )
            },
            uniqueUnregisteredExternalMethodCount: aggregate.unregisteredExternalInvocations.count,
            omittedExternalInvocationCount: aggregate.omittedExternalInvocationCount,
            unsupportedOpcodeCount: aggregate.unsupportedOpcodes.count,
            topLimit: expected.aggregate.topLimit,
            topUnregisteredExternalInvocations: aggregate.unregisteredExternalInvocations
                .prefix(expected.aggregate.topLimit)
                .map {
                    BaselineMethod(
                        surface: $0.surface.summary,
                        extensionCount: $0.extensionCount,
                        invocationCount: $0.invocationCount
                    )
                }
        )
        XCTAssertEqual(actualAggregate, expected.aggregate)
    }

    private func fetchTable(named marker: String, from script: String) throws -> [String] {
        let normalized = script.replacingOccurrences(of: "\r\n", with: "\n")
        let opening = try XCTUnwrap(
            normalized.range(of: "done <<'\(marker)'\n"),
            "missing \(marker) opening delimiter"
        )
        let remainder = normalized[opening.upperBound...]
        let closing = try XCTUnwrap(
            remainder.range(of: "\n\(marker)"),
            "missing \(marker) closing delimiter"
        )
        return remainder[..<closing.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func loadLock() throws -> Lock {
        try JSONDecoder().decode(
            Lock.self,
            from: Data(contentsOf: corpusRoot.appendingPathComponent("manifest.json"))
        )
    }

    private var corpusRoot: URL {
        repositoryRoot.appendingPathComponent("Tests/corpus", isDirectory: true)
    }

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}
