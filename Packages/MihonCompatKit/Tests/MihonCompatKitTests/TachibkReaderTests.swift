import Foundation
import XCTest
@testable import MihonCompatKit

/// These wire fixtures are synthetic, hand-authored against the pinned Mihon
/// schema. They are not backups exported by the Android app. The static gzip
/// fixture was wrapped independently with Python's gzip.compress(..., mtime=0).
final class TachibkReaderTests: XCTestCase {
    private typealias Reader = TachibkReader

    private let rawFixture = Array(Data(base64Encoded: "Cg4IKhIKL21hbmdhL2FiYw==")!)
    private let gzipFixture = Array(Data(base64Encoded: "H4sIAAAAAAACA+Pi49AS4tLPTcxLT9RPTEoGAJoeqhoQAAAA")!)

    func testOmittedFavoriteDefaultsTrueAndExplicitFalseSurvives() throws {
        let backup = try Reader().decode(manga() + manga(source: 99, url: "/other", extra: [integer(100, 0)]))
        XCTAssertEqual(backup.manga.map(\.favorite), [true, false])
        let first = try XCTUnwrap(backup.manga.first)
        XCTAssertEqual(first.title, "")
        XCTAssertEqual(first.genre, [])
        XCTAssertEqual(first.status, 0)
        XCTAssertNil(first.artist)
        XCTAssertNil(first.thumbnailURL)
        XCTAssertEqual(first.dateAdded, 0)
        XCTAssertNil(first.favoriteModifiedAt)
        XCTAssertEqual(first.updateStrategy, .alwaysUpdate)
        XCTAssertFalse(first.initialized)
        XCTAssertEqual(first.chapters, [])
        XCTAssertEqual(first.history, [])
        XCTAssertEqual(backup.coverage.unsupportedOccurrences, 0)
    }

    func testSourceIDsRemainSignedFullWidthIntegers() throws {
        let high: Int64 = 9_007_199_254_740_999
        let backup = try Reader().decode(
            manga(source: high) + manga(source: Int64.min, url: "/negative")
                + bytes(101, integer(2, high)) + bytes(101, integer(2, Int64.min))
        )
        XCTAssertEqual(backup.manga.map(\.sourceId), [high, Int64.min])
        XCTAssertEqual(backup.sources.map(\.id), [high, Int64.min])
        XCTAssertEqual(backup.sources.map(\.name), ["", ""])
    }

    func testMetadataChapterAndHistoryKeepUpstreamUnitsAndLongs() throws {
        let chapter = bytes(16, fields([
            text(1, "/chapter/c"), text(2, ""), text(3, "Grupo"), integer(4, 1), integer(5, 1),
            integer(6, 4_294_967_300), integer(7, 1_791_100_000_123), integer(8, 1_700_000_000_987),
            fixedFloat(9, 7.5), integer(10, -4_294_967_301),
        ]))
        let history = bytes(104, fields([
            text(1, "/chapter/c"), integer(2, 1_791_123_456_789), integer(3, 123_456),
        ]))
        let backup = try Reader().decode(manga(extra: [
            text(3, "タイトル"), text(4, "Artist"), text(5, "Author"), text(6, "Descripción"),
            text(7, "Adventure"), text(7, "Comedy"), integer(8, 2), text(9, "https://example.invalid/cover"),
            integer(13, 1_700_123_456_789), integer(107, 1_700_123_456), integer(105, 1),
            integer(111, 1), chapter, history,
        ]))
        let m = try XCTUnwrap(backup.manga.first)
        XCTAssertEqual(m.title, "タイトル")
        XCTAssertEqual(m.artist, "Artist")
        XCTAssertEqual(m.author, "Author")
        XCTAssertEqual(m.descriptionText, "Descripción")
        XCTAssertEqual(m.genre, ["Adventure", "Comedy"])
        XCTAssertEqual(m.status, 2)
        XCTAssertEqual(m.thumbnailURL, "https://example.invalid/cover")
        XCTAssertEqual(m.dateAdded, 1_700_123_456_789)
        XCTAssertEqual(m.favoriteModifiedAt, 1_700_123_456)
        XCTAssertEqual(m.updateStrategy, .onlyFetchOnce)
        XCTAssertTrue(m.initialized)
        XCTAssertEqual(m.chapterCount, 1)
        let c = try XCTUnwrap(m.chapters.first)
        XCTAssertEqual(c.url, "/chapter/c")
        XCTAssertEqual(c.name, "")
        XCTAssertEqual(c.scanlator, "Grupo")
        XCTAssertTrue(c.read)
        XCTAssertTrue(c.bookmark)
        XCTAssertEqual(c.lastPageRead, 4_294_967_300)
        XCTAssertEqual(c.dateFetch, 1_791_100_000_123)
        XCTAssertEqual(c.dateUpload, 1_700_000_000_987)
        XCTAssertEqual(c.chapterNumber, 7.5)
        XCTAssertEqual(c.sourceOrder, -4_294_967_301)
        let h = try XCTUnwrap(m.history.first)
        XCTAssertEqual(h.url, c.url)
        XCTAssertEqual(h.lastRead, 1_791_123_456_789)
        XCTAssertEqual(h.readDuration, 123_456)
    }

    func testSyntheticGzipAndRawLibraryHaveTheSameDecodedData() throws {
        let raw = try Reader().decode(rawFixture)
        let gzip = try Reader().decode(gzipFixture)
        XCTAssertEqual(raw.compression, .rawProtobuf)
        XCTAssertEqual(gzip.compression, .gzip)
        XCTAssertEqual(raw.manga, gzip.manga)
        XCTAssertEqual(raw.categories, gzip.categories)
        XCTAssertEqual(raw.sources, gzip.sources)
        XCTAssertEqual(raw.coverage, gzip.coverage)
        XCTAssertEqual(gzip.manga.first?.url, "/manga/abc")
        XCTAssertEqual(gzip.manga.first?.sourceId, 42)
        XCTAssertEqual(gzip.manga.first?.favorite, true)
    }

    func testEmptyRawAndEmptyGzipMessagesAreEmptyBackups() throws {
        let raw = try Reader().decode([])
        // Python gzip.compress(b"", mtime=0): an independent empty gzip member.
        let emptyGzip = Array(Data(base64Encoded: "H4sIAAAAAAACAAMAAAAAAAAAAAA=")!)
        let gzip = try Reader().decode(emptyGzip)
        XCTAssertTrue(raw.manga.isEmpty)
        XCTAssertTrue(raw.categories.isEmpty)
        XCTAssertTrue(raw.sources.isEmpty)
        XCTAssertEqual(raw.coverage.unsupported, [])
        XCTAssertEqual(gzip.manga, raw.manga)
        XCTAssertEqual(gzip.coverage, raw.coverage)
        XCTAssertEqual(gzip.compression, .gzip)
    }

    func testCategoriesOnlyAndReorderedRootFieldsRetainOrderInsteadOfID() throws {
        let onlyDefault = try Reader().decode(bytes(2, text(1, "")))
        XCTAssertTrue(onlyDefault.manga.isEmpty)
        XCTAssertEqual(onlyDefault.categories.first?.name, "")
        XCTAssertEqual(onlyDefault.categories.first?.order, 0)
        XCTAssertEqual(onlyDefault.categories.first?.id, 0)
        XCTAssertEqual(onlyDefault.categories.first?.flags, 0)

        let order: Int64 = 4_294_967_302
        let input = fields([
            bytes(101, fields([text(1, "A source"), integer(2, 42)])),
            bytes(2, fields([text(1, "Reading"), integer(2, order), integer(3, 7), integer(100, 9)])),
            manga(extra: [integer(17, order)]),
        ])
        let decoded = try Reader().decode(input)
        XCTAssertEqual(decoded.categories.first?.order, order)
        XCTAssertEqual(decoded.categories.first?.id, 7)
        XCTAssertEqual(decoded.categories.first?.flags, 9)
        XCTAssertEqual(decoded.manga.first?.categories, [order])
        XCTAssertEqual(decoded.sources.first?.name, "A source")
    }

    func testExpandedPackedAndMixedCategoryReferencesKeepOccurrenceOrder() throws {
        let high: Int64 = 1_099_511_627_776
        let input = manga(extra: [
            integer(17, 1), bytes(17, varint(UInt64(high)) + varint(UInt64(bitPattern: -1))),
            text(3, "Between segments"), bytes(17, []), integer(17, 0), bytes(17, varint(2)),
        ])
        XCTAssertEqual(try Reader().decode(input).manga.first?.categories, [1, high, -1, 0, 2])
        assertError(input, .limitExceeded(.categoryReferences), policy: .init(maximumCategoryReferences: 4))
    }

    func testLastSingularOccurrenceWinsWithoutIgnoringEarlierInvalidFields() throws {
        let input = bytes(1, fields([
            integer(1, 12), integer(1, -7), text(2, "/old"), text(2, "/new"),
            text(3, "Old"), text(3, "New"), integer(100, 0), integer(100, 1),
            integer(105, 1), integer(105, 0), integer(111, 1), integer(111, 0),
        ])) + bytes(2, fields([text(1, "First"), text(1, "Last"), integer(2, 8), integer(2, 3)]))
            + bytes(101, fields([integer(2, 3), integer(2, -5)]))
        let backup = try Reader().decode(input)
        XCTAssertEqual(backup.manga.first?.sourceId, -7)
        XCTAssertEqual(backup.manga.first?.url, "/new")
        XCTAssertEqual(backup.manga.first?.title, "New")
        XCTAssertEqual(backup.manga.first?.favorite, true)
        XCTAssertEqual(backup.manga.first?.updateStrategy, .alwaysUpdate)
        XCTAssertEqual(backup.manga.first?.initialized, false)
        XCTAssertEqual(backup.categories.first?.name, "Last")
        XCTAssertEqual(backup.categories.first?.order, 3)
        XCTAssertEqual(backup.sources.first?.id, -5)
        assertError(manga(extra: [integer(3, 5), text(3, "Valid later")]),
                    .wrongWireType(scope: .manga, field: 3, wire: 0))
    }

    func testMalformedConsumedNestedMessagesCannotDisappearFromAValidBackup() {
        XCTAssertThrowsError(try Reader().decode(manga() + bytes(1, [0x12, 0x05, 0x01])))
        XCTAssertThrowsError(try Reader().decode(manga(extra: [bytes(16, [0x0a, 0x80])])))
        XCTAssertThrowsError(try Reader().decode(manga(extra: [bytes(104, [0x0a, 0x02, 0x01])])))
        assertError(manga(extra: [bytes(16, [])]), .missingRequiredField(scope: .chapter, field: 1))
        assertError(manga(extra: [bytes(104, [])]), .missingRequiredField(scope: .history, field: 1))
    }

    func testRequiredScalarsAndNonemptyURLsAreValidated() throws {
        assertError(bytes(1, text(2, "/m")), .missingRequiredField(scope: .manga, field: 1))
        assertError(bytes(1, integer(1, 0)), .missingRequiredField(scope: .manga, field: 2))
        assertError(manga(url: ""), .emptyIdentity(scope: .manga, field: 2))
        assertError(manga(extra: [bytes(16, text(1, "/c"))]),
                    .missingRequiredField(scope: .chapter, field: 2))
        assertError(manga(extra: [bytes(104, text(1, "/c"))]),
                    .missingRequiredField(scope: .history, field: 2))
        assertError(bytes(2, []), .missingRequiredField(scope: .category, field: 1))
        assertError(bytes(101, text(1, "Named")), .missingRequiredField(scope: .source, field: 2))
        let valid = try Reader().decode(manga(source: 0, extra: [
            bytes(16, fields([text(1, "/c"), text(2, "")])),
            bytes(104, fields([text(1, "/c"), integer(2, 0)])),
        ]))
        XCTAssertEqual(valid.manga.first?.sourceId, 0)
        XCTAssertEqual(valid.manga.first?.history.first?.lastRead, 0)
        XCTAssertEqual(valid.manga.first?.history.first?.readDuration, 0)
    }

    func testInvalidUTF8IsRejectedInEveryConsumedStringScope() {
        let invalid: [UInt8] = [0xc3, 0x28]
        assertError(bytes(1, fields([integer(1, 42), bytes(2, invalid)])),
                    .invalidUTF8(scope: .manga, field: 2))
        assertError(manga(extra: [bytes(4, invalid)]), .invalidUTF8(scope: .manga, field: 4))
        assertError(bytes(2, bytes(1, invalid)), .invalidUTF8(scope: .category, field: 1))
        assertError(bytes(101, fields([integer(2, 42), bytes(1, invalid)])),
                    .invalidUTF8(scope: .source, field: 1))
        assertError(manga(extra: [bytes(16, fields([bytes(1, invalid), text(2, "C")]))]),
                    .invalidUTF8(scope: .chapter, field: 1))
        assertError(manga(extra: [bytes(104, fields([bytes(1, invalid), integer(2, 0)]))]),
                    .invalidUTF8(scope: .history, field: 1))
    }

    func testWrongOuterWireTypesFailForSupportedAndOpaqueKnownFields() {
        assertError(integer(1, 0), .wrongWireType(scope: .root, field: 1, wire: 0))
        assertError(integer(104, 0), .wrongWireType(scope: .root, field: 104, wire: 0))
        assertError(integer(105, 0), .wrongWireType(scope: .root, field: 105, wire: 0))
        assertError(integer(106, 0), .wrongWireType(scope: .root, field: 106, wire: 0))
        assertError(bytes(2, integer(1, 0)), .wrongWireType(scope: .category, field: 1, wire: 0))
        assertError(bytes(101, text(2, "42")), .wrongWireType(scope: .source, field: 2, wire: 2))
        assertError(manga(extra: [bytes(100, [1])]), .wrongWireType(scope: .manga, field: 100, wire: 2))
        assertError(manga(extra: [integer(18, 0)]), .wrongWireType(scope: .manga, field: 18, wire: 0))
        assertError(manga(extra: [integer(112, 0)]), .wrongWireType(scope: .manga, field: 112, wire: 0))
        assertError(manga(extra: [bytes(16, fields([text(1, "/c"), text(2, "C"), integer(9, 2)]))]),
                    .wrongWireType(scope: .chapter, field: 9, wire: 0))
        assertError(manga(extra: [bytes(104, fields([text(1, "/c"), text(2, "date")]))]),
                    .wrongWireType(scope: .history, field: 2, wire: 2))
    }

    func testMalformedWireLengthsTagsAndOverflowVarintsAreCatchable() {
        let bad: [[UInt8]] = [
            [0], [0x0a], [0x0a, 0x80], [0x0a, 0xff, 0xff, 0xff, 0xff, 0x0f],
            varint(UInt64(1 << 29) << 3), [0x0b], [0x0c], [0x0e], [0x09, 1],
            [0x08] + Array(repeating: 0xff, count: 9) + [2],
            [0x08] + Array(repeating: 0x80, count: 10),
            manga(extra: [bytes(17, [0x80])]),
            manga(extra: [bytes(16, fields([text(1, "/c"), text(2, "C"), [0x4d, 0, 0, 0]]))]),
        ]
        for input in bad {
            XCTAssertThrowsError(try Reader().decode(input), "malformed fixture \(input)")
        }
    }

    func testEveryNonemptyTruncatedPrefixOfOneMangaFails() throws {
        let complete = manga(extra: [text(3, "A title"), chapter(), history()])
        XCTAssertEqual(try Reader().decode(complete).manga.count, 1)
        // Empty root is valid, but every nonempty incomplete enclosing LEN
        // message must fail, rather than importing an apparently smaller library.
        for length in 1..<complete.count {
            XCTAssertThrowsError(try Reader().decode(Array(complete.prefix(length))), "prefix \(length)")
        }
    }

    func testNonFiniteFloatsOutOfRangeInt32AndInvalidEnumsFail() {
        assertError(manga(extra: [integer(8, 2_147_483_648)]), .invalidInteger(scope: .manga, field: 8))
        assertError(manga(extra: [integer(100, 2)]), .invalidBoolean(scope: .manga, field: 100))
        assertError(manga(extra: [integer(105, 7)]), .invalidUpdateStrategy(7))
        for number in [Float.infinity, Float.nan, -Float.infinity] {
            assertError(manga(extra: [chapter(extra: [fixedFloat(9, number)])]),
                        .invalidFloat(scope: .chapter, field: 9))
        }
    }

    func testOpaqueCoverageIsScopedStableAndCannotBecomePreferencesOrTrust() throws {
        let sealedPreference = fields([text(1, "secret-key"), bytes(2, [0xff, 0x00])])
        let store = fields([text(1, "https://example.invalid/index"), text(2, "Store"), text(5, "untrusted")])
        let broken: [UInt8] = [0x00, 0x01] // non-compliant field 0 stays opaque
        let input = fields([
            bytes(104, sealedPreference), bytes(104, sealedPreference), bytes(105, [0xff]),
            bytes(106, store), bytes(100, broken), integer(500, 1),
            manga(extra: [
                bytes(18, [0xff]), integer(14, 1), integer(103, 2), integer(101, 3),
                bytes(102, broken), integer(106, 4), integer(109, 5),
                text(108, "Excluded"), text(110, "Private note"), bytes(112, [0xff]), integer(501, 1),
                chapter(extra: [bytes(13, [0xff]), integer(502, 1)]),
                history(extra: [integer(503, 1)]),
            ]),
            bytes(2, fields([text(1, "Category"), integer(504, 1)])),
            bytes(101, fields([integer(2, 42), integer(505, 1)])),
        ])
        let decoded = try Reader().decode(input)
        let coverage = decoded.coverage
        XCTAssertEqual(coverage.occurrences(of: .appPreferences, in: .root), 2)
        XCTAssertEqual(coverage.occurrences(of: .sourcePreferences, in: .root), 1)
        XCTAssertEqual(coverage.occurrences(of: .extensionStores, in: .root), 1)
        XCTAssertEqual(coverage.occurrences(of: .legacySources, in: .root), 1)
        XCTAssertEqual(coverage.occurrences(of: .tracking, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .readerSettings, in: .manga), 2)
        XCTAssertEqual(coverage.occurrences(of: .chapterSettings, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .legacyHistory, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .synchronizationMetadata, in: .manga), 2)
        XCTAssertEqual(coverage.occurrences(of: .excludedScanlators, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .notes, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .mangaMemo, in: .manga), 1)
        XCTAssertEqual(coverage.occurrences(of: .chapterMemo, in: .chapter), 1)
        for scope in Reader.Scope.allCases {
            XCTAssertEqual(coverage.occurrences(of: .unknownField, in: scope), 1)
        }
        let preferences = try XCTUnwrap(coverage.unsupported.first { $0.feature == .appPreferences })
        XCTAssertEqual(preferences.valueBytes, sealedPreference.count * 2)
        XCTAssertFalse(String(describing: coverage).contains("secret-key"))
        XCTAssertFalse(String(describing: coverage).contains("Private note"))
        let entries = try Reader().read(input)
        XCTAssertEqual(entries.count, 4) // manga, category, source, explicit report
        guard case let .coverage(projected)? = entries.last else { return XCTFail("missing coverage entry") }
        XCTAssertEqual(projected, coverage)
        let opaqueRoot = [bytes(104, sealedPreference), bytes(105, [0xff]), bytes(106, store)]
        XCTAssertEqual(try Reader().decode(fields(opaqueRoot)).coverage,
                       try Reader().decode(fields(opaqueRoot.reversed().map { $0 })).coverage)
    }

    func testUnknownFieldNumbersShareOneFiniteReportKeyPerScope() throws {
        let input = fields((200..<300).map { integer($0, Int64($0)) })
        let coverage = try Reader().decode(input).coverage
        XCTAssertEqual(coverage.unsupported.count, 1)
        XCTAssertEqual(coverage.occurrences(of: .unknownField, in: .root), 100)
    }

    func testValidRawProtobufWinsWhenUnsupportedCompressionMagicOverlaps() throws {
        // 78 01 is both a zlib header and root field15=1.
        let zlibLooking = [UInt8](arrayLiteral: 0x78, 0x01) + manga()
        XCTAssertEqual(try Reader().decode(zlibLooking).manga.count, 1)
        // 28 b5 2f fd starts with the zstd magic, but is also field5's
        // varint followed by field31 fixed32's tag (fd 01) and value.
        let zstdLooking: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd, 0x01, 0, 0, 0, 0]
        XCTAssertEqual(try Reader().decode(zstdLooking).coverage.unsupportedOccurrences, 2)
        assertError([0x28, 0xb5, 0x2f, 0xfd], .zstdNotSupported)
        // A header followed by a missing raw varint is not a valid message.
        assertError([0x78, 0x9c, 0x80], .zlibNotSupported)
        assertError(Array("{}".utf8), .legacyJSONNotSupported)
        assertError([0x28, 0xb5, 0x2f, 0xfd], .limitExceeded(.fields), policy: .init(maximumFields: 0))
    }

    func testInputAndRawOrGzipPayloadLimitsAreIndependent() throws {
        XCTAssertNoThrow(try Reader(policy: .init(maximumInputBytes: rawFixture.count,
                                                  maximumPayloadBytes: rawFixture.count)).decode(rawFixture))
        assertError(rawFixture, .limitExceeded(.inputBytes), policy: .init(maximumInputBytes: rawFixture.count - 1))
        assertError(rawFixture, .limitExceeded(.payloadBytes), policy: .init(maximumPayloadBytes: rawFixture.count - 1))
        assertError(gzipFixture, .limitExceeded(.inputBytes), policy: .init(maximumInputBytes: gzipFixture.count - 1))
        assertError(gzipFixture, .limitExceeded(.payloadBytes), policy: .init(maximumPayloadBytes: rawFixture.count - 1))
        XCTAssertThrowsError(try Reader().decode(gzipFixture + [0]))
        XCTAssertThrowsError(try Reader().decode(gzipFixture + gzipFixture))
    }

    func testEntityAndMembershipBudgetsAreCumulativeAcrossSiblings() {
        assertError(manga() + manga(), .limitExceeded(.manga), policy: .init(maximumManga: 1))
        assertError(bytes(2, text(1, "A")) + bytes(2, text(1, "B")),
                    .limitExceeded(.categories), policy: .init(maximumCategories: 1))
        assertError(bytes(101, integer(2, 1)) + bytes(101, integer(2, 2)),
                    .limitExceeded(.sources), policy: .init(maximumSources: 1))
        assertError(manga(extra: [chapter()]) + manga(extra: [chapter()]),
                    .limitExceeded(.chapters), policy: .init(maximumChapters: 1))
        assertError(manga(extra: [history()]) + manga(extra: [history()]),
                    .limitExceeded(.history), policy: .init(maximumHistory: 1))
        assertError(manga(extra: [integer(17, 1)]) + manga(extra: [integer(17, 2)]),
                    .limitExceeded(.categoryReferences), policy: .init(maximumCategoryReferences: 1))
    }

    func testFieldAndDepthBudgetsAreSharedWithKnownNestedMessages() throws {
        // Each minimal manga costs three fields including its root occurrence.
        assertError(manga() + manga(), .limitExceeded(.fields), policy: .init(maximumFields: 5))
        XCTAssertNoThrow(try Reader(policy: .init(maximumFields: 6)).decode(manga() + manga()))
        XCTAssertNoThrow(try Reader(policy: .init(maximumDepth: 2)).decode(manga()))
        assertError(manga(extra: [chapter()]), .limitExceeded(.depth), policy: .init(maximumDepth: 2))
        assertError(manga(extra: [history()]), .limitExceeded(.depth), policy: .init(maximumDepth: 2))
        assertError(bytes(2, text(1, "A")), .limitExceeded(.depth), policy: .init(maximumDepth: 1))
        assertError([], .limitExceeded(.depth), policy: .init(maximumDepth: 0))
        // No claim to validate nested preference contents or depth: they remain
        // one reported opaque field under the input/payload/field budgets.
        XCTAssertEqual(try Reader(policy: .init(maximumDepth: 1)).decode(bytes(104, [0xff])).coverage
            .occurrences(of: .appPreferences, in: .root), 1)
    }

    func testStringBudgetsUseUTF8BytesAndIncludeOverwrittenValues() {
        // URL is one byte and each title occurrence is two UTF-8 bytes.
        let duplicate = manga(url: "u", extra: [text(3, "é"), text(3, "é")])
        assertError(duplicate, .limitExceeded(.stringBytes), policy: .init(maximumStringBytes: 4))
        XCTAssertNoThrow(try Reader(policy: .init(maximumStringBytes: 5)).decode(duplicate))
        assertError(manga(extra: [text(3, "é")]), .limitExceeded(.stringLength),
                    policy: .init(maximumStringLengthBytes: 1))
        assertError(manga(extra: [text(6, "éé")]), .limitExceeded(.descriptionLength),
                    policy: .init(maximumDescriptionBytes: 3))
        assertError(manga(url: "é"), .limitExceeded(.urlLength), policy: .init(maximumURLBytes: 1))
        assertError(bytes(1, fields([integer(1, 42), text(2, "long"), text(2, "u")])),
                    .limitExceeded(.urlLength), policy: .init(maximumURLBytes: 1))
    }

    func testPolicyMayOnlyLowerCeilingsAndCannotContainNegativeLimits() {
        let invalid: [(Reader.Policy, Reader.Limit)] = [
            (.init(maximumInputBytes: 32 * 1024 * 1024 + 1), .inputBytes),
            (.init(maximumPayloadBytes: 64 * 1024 * 1024 + 1), .payloadBytes),
            (.init(maximumFields: 500_001), .fields), (.init(maximumManga: 10_001), .manga),
            (.init(maximumCategories: 1_001), .categories), (.init(maximumSources: 10_001), .sources),
            (.init(maximumChapters: 100_001), .chapters), (.init(maximumHistory: 100_001), .history),
            (.init(maximumCategoryReferences: 100_001), .categoryReferences),
            (.init(maximumStringBytes: 32 * 1024 * 1024 + 1), .stringBytes),
            (.init(maximumStringLengthBytes: 256 * 1024 + 1), .stringLength),
            (.init(maximumURLBytes: 4 * 1024 + 1), .urlLength),
            (.init(maximumDescriptionBytes: 256 * 1024 + 1), .descriptionLength),
            (.init(maximumDepth: 9), .depth), (.init(maximumSources: -1), .sources),
        ]
        for (policy, limit) in invalid { assertError([], .invalidPolicy(limit), policy: policy) }
        XCTAssertNoThrow(try Reader(policy: .init(maximumManga: 0, maximumCategories: 0,
                                                maximumSources: 0, maximumChapters: 0,
                                                maximumHistory: 0)).decode([]))
    }

    func testCancellationIsObservedBeforeAnyDecodeWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Reader().decode([])
        }
        do {
            _ = try await task.value
            XCTFail("cancelled decode completed")
        } catch is CancellationError {
            // Expected: neither format fallback nor policy checking hides it.
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    private func assertError(_ bytes: [UInt8], _ expected: Reader.Error, policy: Reader.Policy = .default,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Reader(policy: policy).decode(bytes), file: file, line: line) {
            XCTAssertEqual($0 as? Reader.Error, expected, file: file, line: line)
        }
    }

    private func manga(source: Int64 = 42, url: String = "/m", extra: [[UInt8]] = []) -> [UInt8] {
        bytes(1, fields([integer(1, source), text(2, url)] + extra))
    }

    private func chapter(extra: [[UInt8]] = []) -> [UInt8] {
        bytes(16, fields([text(1, "/c"), text(2, "C")] + extra))
    }

    private func history(extra: [[UInt8]] = []) -> [UInt8] {
        bytes(104, fields([text(1, "/c"), integer(2, 0)] + extra))
    }

    private func fields(_ values: [[UInt8]]) -> [UInt8] { values.flatMap { $0 } }

    private func bytes(_ field: Int, _ value: [UInt8]) -> [UInt8] {
        varint(UInt64(field) << 3 | 2) + varint(UInt64(value.count)) + value
    }

    private func text(_ field: Int, _ value: String) -> [UInt8] { bytes(field, Array(value.utf8)) }

    private func integer(_ field: Int, _ value: Int64) -> [UInt8] {
        varint(UInt64(field) << 3) + varint(UInt64(bitPattern: value))
    }

    private func fixedFloat(_ field: Int, _ value: Float) -> [UInt8] {
        varint(UInt64(field) << 3 | 5) + (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var n = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(n & 0x7f)
            n >>= 7
            if n != 0 { byte |= 0x80 }
            result.append(byte)
        } while n != 0
        return result
    }
}
