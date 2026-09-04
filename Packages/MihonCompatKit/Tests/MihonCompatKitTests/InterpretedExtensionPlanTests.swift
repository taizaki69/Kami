import Foundation
import XCTest
@testable import MihonCompatKit

final class InterpretedExtensionPlanTests: XCTestCase {
    func testCurrentLib16ProfilesProduceDeterministicStructuralPlans() throws {
        let cases: [(
            fixture: String,
            package: String,
            version: String,
            code: Int64,
            wrapper: String
        )] = [
            (
                "batcave",
                "eu.kanade.tachiyomi.extension.en.batcave",
                "1.6.9",
                9,
                "Lu0;"
            ),
            (
                "kawiimanga",
                "eu.kanade.tachiyomi.extension.ar.kawiimanga",
                "1.6.1",
                1,
                "Leu/kanade/tachiyomi/extension/ar/kawiimanga/ExtensionGenerated;"
            ),
            (
                "mangamelon",
                "eu.kanade.tachiyomi.extension.en.mangamelon",
                "1.6.1",
                1,
                "Lb0;"
            ),
            (
                "baozimanhua",
                "eu.kanade.tachiyomi.extension.zh.baozimanhua",
                "1.6.29",
                29,
                "Lv;"
            ),
            (
                "tuttoanimemanga",
                "eu.kanade.tachiyomi.extension.it.tuttoanimemanga",
                "1.6.10",
                10,
                "Leu/kanade/tachiyomi/extension/it/tuttoanimemanga/ExtensionGenerated;"
            ),
            (
                "mangasoriginesfr",
                "eu.kanade.tachiyomi.extension.fr.mangasoriginesfr",
                "1.6.58",
                58,
                "Lw;"
            ),
            (
                "komikcast",
                "eu.kanade.tachiyomi.extension.id.komikcast",
                "1.6.83",
                83,
                "Leu/kanade/tachiyomi/extension/id/komikcast/ExtensionGenerated;"
            ),
        ]
        let inspector = InterpretedExtensionPlanInspector()

        for item in cases {
            let bytes = try corpusAPK(item.fixture)
            let first = try inspector.inspect(apkBytes: bytes)
            let second = try inspector.inspect(apkBytes: bytes)
            XCTAssertEqual(first, second, item.fixture)
            XCTAssertTrue(first.isStructuralCandidate, item.fixture)
            XCTAssertEqual(first.blockers, [], item.fixture)
            XCTAssertEqual(first.dexEntryNames, ["classes.dex"], item.fixture)
            XCTAssertEqual(first.nativeLibraryCount, 0, item.fixture)

            let plan = try XCTUnwrap(first.plan, item.fixture)
            XCTAssertEqual(plan.packageName, item.package, item.fixture)
            XCTAssertEqual(plan.versionName, item.version, item.fixture)
            XCTAssertEqual(plan.versionCode, item.code, item.fixture)
            XCTAssertEqual(plan.extensionLibVersion, "1.6", item.fixture)
            XCTAssertEqual(plan.dexEntryName, "classes.dex", item.fixture)
            XCTAssertEqual(
                plan.entryClassDescriptor,
                "L\(item.package.replacingOccurrences(of: ".", with: "/"))/ExtensionGenerated;",
                item.fixture
            )
            XCTAssertEqual(plan.sourceAPIWrapperDescriptor, item.wrapper, item.fixture)
        }
    }

    func testLegacyLib14CorpusIsReportedNotGuessed() throws {
        let inspector = InterpretedExtensionPlanInspector()
        for fixture in ["akuma", "mangadex"] {
            let inspection = try inspector.inspect(apkBytes: corpusAPK(fixture))
            XCTAssertFalse(inspection.isStructuralCandidate, fixture)
            XCTAssertNil(inspection.plan, fixture)
            XCTAssertTrue(
                inspection.blockers.contains(.unsupportedLibraryVersion("1.4")),
                fixture
            )
            XCTAssertEqual(inspection.dexEntryNames, ["classes.dex"], fixture)
        }
    }

    func testMalformedAPKDoesNotBecomeACompatibilityReport() {
        XCTAssertThrowsError(
            try InterpretedExtensionPlanInspector().inspect(apkBytes: [0, 1, 2, 3])
        )
    }

    private func corpusAPK(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }
}
