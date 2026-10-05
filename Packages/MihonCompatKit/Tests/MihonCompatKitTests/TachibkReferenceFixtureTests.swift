import Foundation
import XCTest
@testable import MihonCompatKit

/// These files were emitted and decoded by kotlinx.serialization, independently
/// of the Swift reader. They are reference-serializer data, not Android exports.
final class TachibkReferenceFixtureTests: XCTestCase {
    func testReferenceProducerAndRecipesMatchTheirProvenanceLocks() throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let producer = manifest.producer
        XCTAssertEqual(producer.kotlinVersion, "2.4.20")
        XCTAssertEqual(producer.serializationVersion, "1.11.0")
        _ = try checkedBytes(producer.sourcePath, producer.sourceSHA256, file: #filePath, line: #line)
        _ = try checkedBytes(producer.recipePath, producer.recipeSHA256, file: #filePath, line: #line)
        _ = try checkedBytes(producer.verificationPath, producer.verificationSHA256, file: #filePath, line: #line)
    }

    func testKotlinDefaultOmissionMetadataAndReadingState() throws {
        let backup = try checkFixture("kotlin-defaults")
        let first = try XCTUnwrap(backup.manga.first)
        let second = try XCTUnwrap(backup.manga.dropFirst().first)
        let chapter = try XCTUnwrap(first.chapters.first)
        let laterChapter = try XCTUnwrap(first.chapters.dropFirst().first)
        let laterHistory = try XCTUnwrap(first.history.dropFirst().first)
        XCTAssertTrue(first.favorite) // Kotlin omits the declared true default.
        XCTAssertFalse(second.favorite)
        XCTAssertEqual(first.sourceId, 9_007_199_254_740_993)
        XCTAssertEqual(second.sourceId, Int64.max)
        XCTAssertEqual(first.categories, [7, 4_294_967_301])
        XCTAssertEqual(backup.categories.map(\.id), [101, 202])
        XCTAssertEqual(laterChapter.lastPageRead, 4_294_967_311)
        XCTAssertEqual(laterChapter.sourceOrder, 4_294_967_305)
        XCTAssertEqual(chapter.chapterNumber, 2.25)
        XCTAssertEqual(laterHistory.readDuration, 5_000_000_001)
        XCTAssertEqual(first.dateAdded, 1_770_000_012_345)
        XCTAssertEqual(first.favoriteModifiedAt, 1_760_000_123)
        XCTAssertEqual(first.updateStrategy, .onlyFetchOnce)
        XCTAssertTrue(first.initialized)
    }

    func testKotlinCategoriesOnlyDoNotRequireLeadingManga() throws {
        let backup = try checkFixture("kotlin-categories-only")
        XCTAssertTrue(backup.manga.isEmpty)
        XCTAssertEqual(backup.categories.count, 2)
        XCTAssertEqual(backup.categories.map(\.order), [7, 4_294_967_301])
    }

    func testKotlinSourcesOnlyPreserveFullSignedIdentity() throws {
        let backup = try checkFixture("kotlin-sources-only")
        XCTAssertTrue(backup.manga.isEmpty)
        XCTAssertEqual(backup.sources.map(\.id), [9_007_199_254_740_993, Int64.max])
    }

    func testKotlinNegativeLongUsesSignedVarintWithoutTruncation() throws {
        let backup = try checkFixture("kotlin-negative-source")
        XCTAssertEqual(backup.manga.first?.sourceId, Int64.min)
        XCTAssertEqual(backup.sources.first?.id, Int64.min)
        XCTAssertEqual(backup.manga.first?.favoriteModifiedAt, 0)
    }

    func testKotlinEmptyRootIsAValidEmptyBackup() throws {
        let backup = try checkFixture("kotlin-empty-root")
        XCTAssertTrue(backup.manga.isEmpty)
        XCTAssertTrue(backup.categories.isEmpty)
        XCTAssertTrue(backup.sources.isEmpty)
    }

    func testKotlinMangaDexImportFixtureRetainsProducerPathsAndDefaults() throws {
        let backup = try checkFixture("kotlin-mangadex-import")
        XCTAssertEqual(backup.manga.first?.sourceId, 2_499_283_573_021_220_255)
        XCTAssertEqual(backup.manga.first?.url, "/manga/11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(backup.manga.first?.chapters.count, 2)
        XCTAssertEqual(backup.manga.first?.favorite, true)
    }

    @discardableResult
    private func checkFixture(_ name: String, file: StaticString = #filePath,
                              line: UInt = #line) throws -> TachibkReader.DecodedBackup {
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.formatVersion, 1, file: file, line: line)
        XCTAssertEqual(Set(manifest.fixtures.map(\.name)), [
            "kotlin-defaults", "kotlin-categories-only", "kotlin-sources-only",
            "kotlin-negative-source", "kotlin-empty-root", "kotlin-mangadex-import",
        ], file: file, line: line)
        XCTAssertEqual(manifest.fixtures.count, 6, file: file, line: line)
        let fixture = try XCTUnwrap(manifest.fixtures.first { $0.name == name }, file: file, line: line)
        let raw = try checkedBytes(fixture.rawPath, fixture.rawSHA256, file: file, line: line)
        let gzip = try checkedBytes(fixture.gzipPath, fixture.gzipSHA256, file: file, line: line)
        let json = try checkedBytes(fixture.expectedJSONPath, fixture.expectedJSONSHA256, file: file, line: line)
        let expected = try JSONDecoder().decode(GoldenBackup.self, from: Data(json))
        let reader = TachibkReader()
        let fromRaw = try reader.decode(raw)
        let fromGzip = try reader.decode(gzip)
        XCTAssertEqual(fromRaw.compression, .rawProtobuf, file: file, line: line)
        XCTAssertEqual(fromGzip.compression, .gzip, file: file, line: line)
        for decoded in [fromRaw, fromGzip] {
            XCTAssertEqual(decoded.manga, expected.manga.map(\.value), name, file: file, line: line)
            XCTAssertEqual(decoded.categories, expected.categories.map(\.value), name, file: file, line: line)
            XCTAssertEqual(decoded.sources, expected.sources.map(\.value), name, file: file, line: line)
            XCTAssertTrue(decoded.coverage.unsupported.isEmpty, name, file: file, line: line)
        }
        return fromRaw
    }

    private func checkedBytes(_ path: String, _ sha256: String, file: StaticString,
                              line: UInt) throws -> [UInt8] {
        let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent(path)))
        XCTAssertEqual(APKSignatureVerifier.apkSHA256(bytes), sha256, path, file: file, line: line)
        return bytes
    }

    private var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Tests/backups", isDirectory: true)
    }

    private struct Manifest: Decodable {
        let formatVersion: Int
        let producer: Producer
        let fixtures: [Fixture]
        struct Producer: Decodable {
            let sourcePath, sourceSHA256, recipePath, recipeSHA256: String
            let verificationPath, verificationSHA256, kotlinVersion, serializationVersion: String
        }
        struct Fixture: Decodable {
            let name, rawPath, rawSHA256, gzipPath, gzipSHA256: String
            let expectedJSONPath, expectedJSONSHA256: String
        }
    }

    // JSONDecoder decodes the producer's integer tokens directly as Int64.
    // Passing through JSONSerialization/Double would lose source-ID precision.
    private struct GoldenBackup: Decodable {
        let manga: [Manga]
        let categories: [Category]
        let sources: [Source]

        struct Manga: Decodable {
            let sourceId: Int64
            let url, title: String
            let artist, author, description, thumbnailUrl: String?
            let genres: [String]
            let status: Int
            let dateAdded: Int64
            let chapters: [Chapter]
            let categoryOrders: [Int64]
            let favorite: Bool
            let history: [History]
            let updateStrategy: Strategy
            let favoriteModifiedAt: Int64?
            let initialized: Bool

            enum Strategy: String, Decodable {
                case always = "ALWAYS_UPDATE", once = "ONLY_FETCH_ONCE"
            }

            var value: TachibkReader.BackupManga {
                .init(url: url, title: title, artist: artist, author: author,
                      descriptionText: description, genre: genres, status: status,
                      sourceId: sourceId, favorite: favorite, thumbnailURL: thumbnailUrl,
                      dateAdded: dateAdded, favoriteModifiedAt: favoriteModifiedAt,
                      updateStrategy: updateStrategy == .always ? .alwaysUpdate : .onlyFetchOnce,
                      initialized: initialized, categories: categoryOrders,
                      chapters: chapters.map(\.value), history: history.map(\.value))
            }
        }

        struct Category: Decodable {
            let name: String
            let order, id, flags: Int64
            var value: TachibkReader.BackupCategory {
                .init(name: name, order: order, id: id, flags: flags)
            }
        }

        struct Source: Decodable {
            let name: String
            let sourceId: Int64
            var value: TachibkReader.BackupSource { .init(id: sourceId, name: name) }
        }

        struct Chapter: Decodable {
            let url, name: String
            let scanlator: String?
            let read, bookmark: Bool
            let lastPageRead, dateFetch, dateUpload, sourceOrder: Int64
            let chapterNumber: Float
            var value: TachibkReader.BackupChapter {
                .init(url: url, name: name, scanlator: scanlator, read: read,
                      bookmark: bookmark, lastPageRead: lastPageRead, dateFetch: dateFetch,
                      dateUpload: dateUpload, chapterNumber: chapterNumber, sourceOrder: sourceOrder)
            }
        }

        struct History: Decodable {
            let url: String
            let lastRead, readDuration: Int64
            var value: TachibkReader.BackupHistory {
                .init(url: url, lastRead: lastRead, readDuration: readDuration)
            }
        }
    }
}
