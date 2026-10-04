import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

/// Synthetic native-format fixtures, not evidence of Mihon or app-wide restore.
final class LibraryBackupCodecTests: XCTestCase {
    private typealias Document = LibraryBackupDocument
    private let exportID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    private let codec = LibraryBackupCodec()

    private func document(sources: [Document.Source] = [.init(sourceID: 1, name: "Source")],
                          categories: [Document.Category] = [], manga: [Document.Manga] = []) -> Document {
        .init(exportID: exportID, exportedAt: 0, sources: sources, categories: categories, manga: manga)
    }

    private func fullDocument() -> Document {
        let first = Document.Manga(
            sourceID: .min, url: "/manga/A", title: "Title", altTitles: ["Second", "First"],
            thumbnailURL: "https://images.example.test/cover", author: "Author", artist: "Artist",
            descriptionText: "A description\nwith a second line", genres: ["Drama", "Action"],
            status: .onHiatus, inLibrary: true, dateAdded: 9_007_199_254_740_993,
            dateUpdated: .max, lastFetched: 17, updateStrategy: .onlyFetchOnce, initialized: true,
            categoryKeys: ["a", "b"],
            chapters: [
                .init(sourceOrder: .min, url: "/a", name: "Hidden", scanlator: "Group",
                      number: -1, dateUpload: 9_007_199_254_740_995, dateFetch: .max,
                      read: true, bookmark: true, lastPageRead: .max, isCurrent: false),
                .init(sourceOrder: .max, url: "/b", name: "Current", number: 1.2345678901234567),
            ],
            history: [
                .init(chapterURL: "/a", lastRead: .max, readDuration: 9_007_199_254_740_997),
                .init(chapterURL: "/b"),
            ], discoveryBaseline: .init(establishedAt: 0),
            knownChapters: [.init(url: "/a", firstSeen: .max, detectedAt: 0),
                            .init(url: "/gone", firstSeen: 0)])
        return .init(exportID: exportID, exportedAt: .max,
                     sources: [.init(sourceID: .min, name: "", language: "en", packageHint: "descriptive.hint"),
                               .init(sourceID: .max, name: "Other")],
                     categories: [.init(key: "a", name: "Empty allowed", sortOrder: .min, flags: .min),
                                  .init(key: "b", name: "Reading", sortOrder: .max, flags: .max)],
                     manga: [first, .init(sourceID: .max, url: "/not-library", lastFetched: .max)])
    }

    private func assertError<T>(_ expected: LibraryBackupError, _ operation: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? LibraryBackupError, expected, file: file, line: line)
        }
    }

    private func changedJSON(_ input: Document? = nil,
                             change: (inout [String: Any]) -> Void) throws -> Data {
        let bytes = try codec.encode(input ?? fullDocument())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func changeFirstManga(_ object: inout [String: Any],
                                  change: (inout [String: Any]) -> Void) {
        var rows = object["manga"] as! [[String: Any]]
        change(&rows[0])
        object["manga"] = rows
    }

    private func preflight(_ text: String, policy: LibraryBackupPolicy = .default) throws {
        var parser = try LibraryBackupJSONPreflight(data: Data(text.utf8), policy: policy)
        try parser.run()
    }

    func testEmptyArchiveHasIndependentCanonicalEnvelope() throws {
        let empty = document(sources: [])
        let expected = #"{"categories":[],"exportID":"12345678-1234-5678-9ABC-123456789ABC","exportedAt":"0","format":"kami.library","manga":[],"scope":"allStoredDomainRows","sources":[],"version":1}"#
        XCTAssertEqual(try codec.encode(empty), Data(expected.utf8))
        XCTAssertEqual(try codec.decode(Data(expected.utf8)), empty)
    }

    func testAllStoredScalarsHiddenRowsAndHistoryRoundTripWithoutUnitConversion() throws {
        let fixture = fullDocument()
        let encoded = try codec.encode(fixture)
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded, fixture)
        XCTAssertFalse(decoded.manga[1].inLibrary)
        XCTAssertEqual(decoded.manga[1].lastFetched, .max)
        XCTAssertFalse(decoded.manga[0].chapters[0].isCurrent)
        XCTAssertEqual(decoded.manga[0].chapters[0].dateFetch, .max)
        XCTAssertEqual(decoded.manga[0].history[0].readDuration, 9_007_199_254_740_997)
        XCTAssertEqual(decoded.manga[0].knownChapters[1].url, "/gone")
        XCTAssertNil(decoded.manga[0].knownChapters[1].detectedAt)
    }

    func testEveryInt64UsesCanonicalStringAndPreservesExtremaBeyondJSONPrecision() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encode(fullDocument())) as? [String: Any])
        XCTAssertEqual(object["exportedAt"] as? String, String(Int64.max))
        let sources = object["sources"] as! [[String: Any]]
        XCTAssertEqual(sources[0]["sourceID"] as? String, String(Int64.min))
        let categories = object["categories"] as! [[String: Any]]
        XCTAssertEqual(categories[0]["sortOrder"] as? String, String(Int64.min))
        XCTAssertEqual(categories[0]["flags"] as? String, String(Int64.min))
        let manga = (object["manga"] as! [[String: Any]])[0]
        for field in ["sourceID", "dateAdded", "dateUpdated", "lastFetched"] { XCTAssertTrue(manga[field] is String) }
        let chapter = (manga["chapters"] as! [[String: Any]])[0]
        for field in ["sourceOrder", "dateUpload", "dateFetch", "lastPageRead"] { XCTAssertTrue(chapter[field] is String) }
        let history = (manga["history"] as! [[String: Any]])[0]
        XCTAssertEqual(history["readDuration"] as? String, "9007199254740997")
        XCTAssertTrue(history["lastRead"] is String)
        XCTAssertEqual((manga["discoveryBaseline"] as! [String: Any])["establishedAt"] as? String, "0")
        let known = (manga["knownChapters"] as! [[String: Any]])[0]
        XCTAssertTrue(known["firstSeen"] is String)
        XCTAssertEqual(known["detectedAt"] as? String, "0")
        XCTAssertTrue(chapter["number"] is NSNumber)
    }

    func testDefaultsAreExplicitAndBaselineAbsenceDiffersFromZero() throws {
        let absent = document(manga: [.init(sourceID: 1, url: "/m")])
        let present = document(manga: [.init(sourceID: 1, url: "/m", discoveryBaseline: .init(establishedAt: 0))])
        XCTAssertNotEqual(try codec.encode(absent), try codec.encode(present))
        XCTAssertNil(try codec.decode(codec.encode(absent)).manga[0].discoveryBaseline)
        XCTAssertEqual(try codec.decode(codec.encode(present)).manga[0].discoveryBaseline?.establishedAt, 0)
        let chapter = Document.Chapter(url: "/c", name: "")
        let withChapter = document(manga: [.init(sourceID: 1, url: "/m", chapters: [chapter])])
        XCTAssertEqual(try codec.decode(codec.encode(withChapter)).manga[0].chapters[0], chapter)
        XCTAssertEqual(chapter.number, -1)
        XCTAssertTrue(chapter.isCurrent)
    }

    func testCanonicalSortIsStableAcrossRowAndMembershipOrder() throws {
        let first = document(sources: [.init(sourceID: 2, name: "B"), .init(sourceID: -1, name: "A")],
                             categories: [.init(key: "b", name: "B", sortOrder: 0), .init(key: "a", name: "A", sortOrder: 0)],
                             manga: [.init(sourceID: 2, url: "/z"),
                                     .init(sourceID: -1, url: "/m", inLibrary: true, categoryKeys: ["b", "a"],
                                           chapters: [.init(sourceOrder: 3, url: "/z", name: "Z"),
                                                      .init(sourceOrder: 3, url: "/a", name: "A")],
                                           history: [.init(chapterURL: "/z"), .init(chapterURL: "/a")],
                                           knownChapters: [.init(url: "/z", firstSeen: 0), .init(url: "/a", firstSeen: 0)])])
        let second = document(sources: first.sources.reversed(), categories: first.categories.reversed(),
                              manga: [.init(sourceID: -1, url: "/m", inLibrary: true, categoryKeys: ["a", "b"],
                                            chapters: first.manga[1].chapters.reversed(),
                                            history: first.manga[1].history.reversed(),
                                            knownChapters: first.manga[1].knownChapters.reversed()), first.manga[0]])
        XCTAssertEqual(try codec.encode(first), try codec.encode(second))
        let decoded = try codec.decode(codec.encode(first))
        XCTAssertEqual(decoded.sources.map(\.sourceID), [-1, 2])
        XCTAssertEqual(decoded.categories.map(\.key), ["a", "b"])
        XCTAssertEqual(decoded.manga[0].chapters.map(\.url), ["/a", "/z"])
        XCTAssertEqual(decoded.manga[0].categoryKeys, ["a", "b"])
    }

    func testAlternateTitleAndGenreSequenceAndUnicodeBytesRemainStoredOrder() throws {
        let manga = Document.Manga(sourceID: 1, url: "/m", altTitles: ["z", "é", "e\u{301}"], genres: ["z", "a"])
        let decoded = try codec.decode(codec.encode(document(manga: [manga]))).manga[0]
        XCTAssertEqual(decoded, manga)
        XCTAssertEqual(decoded.altTitles.map { Data($0.utf8) }, manga.altTitles.map { Data($0.utf8) })
        XCTAssertEqual(decoded.genres, ["z", "a"])
    }

    func testExactUTF8IdentitiesDoNotCollapseCanonicalEquivalentUnicode() throws {
        let composed = "/é"
        let decomposed = "/e\u{301}"
        XCTAssertEqual(composed, decomposed) // Swift String equality would lose this distinction.
        let first = Document.Manga(sourceID: 1, url: composed)
        let second = Document.Manga(sourceID: 1, url: decomposed)
        XCTAssertNotEqual(first, second)
        let fixture = document(manga: [first, second,
            .init(sourceID: 1, url: "/parent", chapters: [.init(url: composed, name: ""), .init(url: decomposed, name: "")],
                  history: [.init(chapterURL: composed), .init(chapterURL: decomposed)],
                  knownChapters: [.init(url: composed, firstSeen: 0), .init(url: decomposed, firstSeen: 0)])])
        let result = try codec.decode(codec.encode(fixture))
        XCTAssertEqual(Set(result.manga.map { Data($0.url.utf8) }).count, 3)
        let parent = try XCTUnwrap(result.manga.first(where: { $0.url == "/parent" }))
        XCTAssertEqual(Set(parent.chapters.map { Data($0.url.utf8) }).count, 2)
        XCTAssertEqual(Set(parent.history.map { Data($0.chapterURL.utf8) }).count, 2)
    }

    func testRepeatedExactIdentitiesFailAcrossEveryRowSet() throws {
        let source = Document.Source(sourceID: 1, name: "")
        let category = Document.Category(key: "c", name: "Category")
        let chapter = Document.Chapter(url: "/c", name: "")
        let history = Document.History(chapterURL: "/c")
        let known = Document.KnownChapter(url: "/c", firstSeen: 0)
        let bad = [document(sources: [source, source]),
                   document(categories: [category, category]),
                   document(manga: [.init(sourceID: 1, url: "/m"), .init(sourceID: 1, url: "/m")]),
                   document(categories: [category], manga: [.init(sourceID: 1, url: "/m", inLibrary: true, categoryKeys: ["c", "c"])]),
                   document(manga: [.init(sourceID: 1, url: "/m", chapters: [chapter, chapter])]),
                   document(manga: [.init(sourceID: 1, url: "/m", chapters: [chapter], history: [history, history])]),
                   document(manga: [.init(sourceID: 1, url: "/m", knownChapters: [known, known])])]
        for fixture in bad { assertError(.duplicateIdentity, try codec.validate(fixture)) }
    }

    func testDanglingSourcesCategoriesAndExactHistoryReferencesFail() throws {
        let bad = [document(manga: [.init(sourceID: 2, url: "/m")]),
                   document(manga: [.init(sourceID: 1, url: "/m", inLibrary: true, categoryKeys: ["missing"])]),
                   document(manga: [.init(sourceID: 1, url: "/m", history: [.init(chapterURL: "/missing")])]),
                   document(manga: [.init(sourceID: 1, url: "/m", chapters: [.init(url: "/é", name: "")],
                                          history: [.init(chapterURL: "/e\u{301}")])])]
        for fixture in bad { assertError(.danglingReference, try codec.validate(fixture)) }
    }

    func testAmbiguousNamesAndNonCanonicalCategoryNamesFail() throws {
        assertError(.ambiguousCategoryName, try codec.validate(document(categories: [
            .init(key: "a", name: "Reading"), .init(key: "b", name: "reading"),
        ])))
        for name in ["", " ", " Trim ", "Two\nlines", String(repeating: "a", count: 101)] {
            assertError(.invalidSchema, try codec.validate(document(categories: [.init(key: "a", name: name)])))
        }
    }

    func testNonlibraryMembershipCannotBeRestoredAsValidDomainRows() throws {
        assertError(.invalidSchema, try codec.validate(document(categories: [.init(key: "c", name: "Category")],
            manga: [.init(sourceID: 1, url: "/m", categoryKeys: ["c"])])))
    }

    func testKnownFooDeploymentMustBeExplicitValidatedOrUnresolved() throws {
        let foo: Int64 = 6_351_052_922_295_965_587
        assertError(.invalidContentBinding, try codec.validate(document(sources: [.init(sourceID: foo, name: "Foo")])))
        let unresolved = document(sources: [.init(sourceID: foo, name: "Foo", contentBinding: .init(kind: .unresolved))])
        XCTAssertEqual(try codec.decode(codec.encode(unresolved)), unresolved)
        let exactURL = "https://reader.example.test/Deployment"
        let explicit = document(sources: [.init(sourceID: foo, name: "Foo",
            contentBinding: .init(kind: .deployment, deploymentURL: exactURL))])
        XCTAssertEqual(try codec.decode(codec.encode(explicit)).sources[0].contentBinding.deploymentURL, exactURL)
        for url in ["http://reader.example.test", "https://127.0.0.1", "https://reader.example.test/",
                    "https://user:secret@reader.example.test", "https://reader.example.test?x=1",
                    "https://reader.example.test#fragment", "https://reader.example.test/path "] {
            assertError(.invalidContentBinding, try codec.validate(document(sources: [.init(sourceID: foo, name: "",
                contentBinding: .init(kind: .deployment, deploymentURL: url))])))
        }
        for kind in [Document.ContentBinding.Kind.sourceIdentity, .unresolved] {
            assertError(.invalidContentBinding, try codec.validate(document(sources: [.init(sourceID: 1, name: "",
                contentBinding: .init(kind: kind, deploymentURL: exactURL))])))
        }
        assertError(.invalidContentBinding, try codec.validate(document(sources: [.init(sourceID: 1, name: "",
            contentBinding: .init(kind: .deployment, deploymentURL: exactURL))])))
    }

    func testUnsupportedEnvelopeAndVersionFailWithoutInventedDefaults() throws {
        let empty = document(sources: [])
        for (key, value) in [("format", "other.backup"), ("scope", "libraryOnly"), ("exportID", "invalid")] {
            assertError(.invalidEnvelope, try codec.decode(changedJSON(empty) { $0[key] = value }))
        }
        assertError(.unsupportedVersion(2), try codec.decode(changedJSON(empty) { $0["version"] = 2 }))
        for key in ["format", "version", "exportID", "scope", "sources", "categories", "manga"] {
            assertError(.invalidSchema, try codec.decode(changedJSON(empty) { $0.removeValue(forKey: key) }))
        }
    }

    func testUnknownKeysFailAtEverySchemaObjectIncludingAuthorityShapedMetadata() throws {
        let root = try changedJSON { $0["installed"] = true }
        assertError(.unknownSchemaKey, try codec.decode(root))
        for section in ["sources", "categories", "manga"] {
            assertError(.unknownSchemaKey, try codec.decode(changedJSON { object in
                var rows = object[section] as! [[String: Any]]
                rows[0]["trust"] = true
                object[section] = rows
            }))
        }
        assertError(.unknownSchemaKey, try codec.decode(changedJSON { object in
            var sources = object["sources"] as! [[String: Any]]
            var binding = sources[0]["contentBinding"] as! [String: Any]
            binding["preferences"] = [:] as [String: Any]
            sources[0]["contentBinding"] = binding
            object["sources"] = sources
        }))
        for section in ["chapters", "history", "knownChapters"] {
            let bytes = try changedJSON { object in
                changeFirstManga(&object) { manga in
                    var rows = manga[section] as! [[String: Any]]
                    rows[0]["extra"] = true
                    manga[section] = rows
                }
            }
            assertError(.unknownSchemaKey, try codec.decode(bytes))
        }
        assertError(.unknownSchemaKey, try codec.decode(changedJSON { object in
            changeFirstManga(&object) { $0["discoveryBaseline"] = ["establishedAt": "0", "extra": "value"] }
        }))
        assertError(.unknownSchemaKey, try codec.decode(changedJSON { object in
            changeFirstManga(&object) { manga in
                manga["categoryKeys"] = manga.removeValue(forKey: "categoryKeys")
            }
        }))
    }

    func testRequiredFieldsAndTypesCannotSilentlyBecomeDefaults() throws {
        for field in ["title", "altTitles", "genres", "inLibrary", "initialized", "categoryKeys", "chapters", "history", "knownChapters"] {
            let missing = try changedJSON { object in changeFirstManga(&object) { $0.removeValue(forKey: field) } }
            assertError(.invalidSchema, try codec.decode(missing))
        }
        for (field, value) in [("inLibrary", "true" as Any), ("initialized", 1), ("status", "6"),
                               ("status", 99), ("updateStrategy", "NEVER_UPDATE"), ("altTitles", "title"),
                               ("thumbnailURL", NSNull())] {
            let invalid = try changedJSON { object in changeFirstManga(&object) { $0[field] = value } }
            assertError(.invalidSchema, try codec.decode(invalid))
        }
    }

    func testCanonicalDecimalStringsRejectNumbersOverflowAndAlternativeSpellings() throws {
        for invalid: Any in [0, 9_007_199_254_740_992, "", "00", "01", "-0", "+1", " 1", "1 ", "1.0",
                            "1e3", "9223372036854775808", "-9223372036854775809", "١", NSNull()] {
            let bytes = try changedJSON(document(sources: [])) { $0["exportedAt"] = invalid }
            assertError(.invalidDecimalInteger, try codec.decode(bytes))
        }
        assertError(.invalidDecimalInteger, try codec.decode(changedJSON(document(sources: [])) { $0.removeValue(forKey: "exportedAt") }))
    }

    func testNegativeTimesAndPagesFailWhileSignedIdentityOrderAndFlagsSurvive() throws {
        assertError(.invalidSchema, try codec.validate(.init(exportID: exportID, exportedAt: -1)))
        for field in ["dateAdded", "dateUpdated", "lastFetched"] {
            assertError(.invalidSchema, try codec.decode(changedJSON { object in
                changeFirstManga(&object) { $0[field] = "-1" }
            }))
        }
        for field in ["dateUpload", "dateFetch", "lastPageRead"] {
            assertError(.invalidSchema, try codec.decode(changedJSON { object in
                changeFirstManga(&object) { manga in
                    var chapters = manga["chapters"] as! [[String: Any]]
                    chapters[0][field] = "-1"
                    manga["chapters"] = chapters
                }
            }))
        }
        for field in ["lastRead", "readDuration"] {
            assertError(.invalidSchema, try codec.decode(changedJSON { object in
                changeFirstManga(&object) { manga in
                    var history = manga["history"] as! [[String: Any]]
                    history[0][field] = "-1"
                    manga["history"] = history
                }
            }))
        }
        for field in ["firstSeen", "detectedAt"] {
            assertError(.invalidSchema, try codec.decode(changedJSON { object in
                changeFirstManga(&object) { manga in
                    var known = manga["knownChapters"] as! [[String: Any]]
                    known[0][field] = "-1"
                    manga["knownChapters"] = known
                }
            }))
        }
        assertError(.invalidSchema, try codec.validate(document(manga: [.init(sourceID: 1, url: "/m",
            discoveryBaseline: .init(establishedAt: -1))])))
        XCTAssertNoThrow(try codec.validate(fullDocument()))
    }

    func testOnlyFiniteChapterNumbersAreAcceptedIncludingUnknownSentinel() throws {
        for invalid in [Double.nan, .infinity, -.infinity] {
            assertError(.invalidSchema, try codec.encode(document(manga: [.init(sourceID: 1, url: "/m",
                chapters: [.init(url: "/c", name: "", number: invalid)])])))
        }
        for valid in [-1.0, 0, -0.0, 1.25, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude] {
            let fixture = document(manga: [.init(sourceID: 1, url: "/m", chapters: [.init(url: "/c", name: "", number: valid)])])
            XCTAssertEqual(try codec.decode(codec.encode(fixture)).manga[0].chapters[0].number, valid)
        }
        let encoded = String(decoding: try codec.encode(fullDocument()), as: UTF8.self)
        let overflow = encoded.replacingOccurrences(of: "\"number\":-1.0", with: "\"number\":1e400")
        assertError(.invalidSchema, try codec.decode(Data(overflow.utf8)))
    }

    func testDuplicateKeysIncludingEscapedEquivalentNamesFailBeforeFoundation() throws {
        for input in [#"{"format":"kami.library","format":"other"}"#,
                      #"{"format":"kami.library","\u0066ormat":"other"}"#,
                      #"{"nested":{"sourceID":"1","source\u0049D":"2"}}"#,
                      #"{"x":"value","x":null}"#,
                      #"{"\ud83d\ude00":1,"😀":2}"#,
                      #"{"categoryKeys":[],"categoryKeys":[]}"#,
                      #"{"é":1,"e\u0301":2}"#] {
            assertError(.duplicateJSONKey, try codec.decode(Data(input.utf8)))
        }
        XCTAssertNoThrow(try preflight(#"{"one":{"key":1},"two":{"key":2}}"#))
    }

    func testLexicalJSONRejectsMalformedSyntaxAndNumberGrammar() throws {
        for input in ["", " ", "{}{}", "[1,]", "{\"a\":1,}", "{\"a\" 1}", "[01]", "[-01]", "[+1]",
                      "[.1]", "[1.]", "[1e]", "[1e+]", "[NaN]", "[true false]", "[TRUE]", "[nullx]",
                      "\u{FEFF}{}", "\"raw\nline\"", #""bad\escape""#, "[", "{", "\""] {
            assertError(.invalidJSON, try codec.decode(Data(input.utf8)))
        }
        XCTAssertNoThrow(try preflight(" [true, false, null, -12.25e+3, 0, 1E-2] \n"))
    }

    func testInvalidUTF8AndUnpairedSurrogatesAreRejectedWithoutReplacement() throws {
        for invalid in [[UInt8](arrayLiteral: 0x22, 0xC0, 0xAF, 0x22),
                        [0x22, 0xED, 0xA0, 0x80, 0x22], [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22],
                        [0x22, 0xE2, 0x82, 0x22], [0x22, 0x80, 0x22]] {
            assertError(.invalidJSON, try codec.decode(Data(invalid)))
        }
        for invalid in [#""\ud800""#, #""\udc00""#, #""\ud800x""#, #""\ud800\u0041""#,
                        #""\ud800\ud800""#, #""\u0G00""#, #""\u12""#] {
            assertError(.invalidJSON, try codec.decode(Data(invalid.utf8)))
        }
        XCTAssertNoThrow(try preflight(#"["\ud83d\ude00","😀","\u0000"]"#))
    }

    func testIdentityControlsAndNULTextFailWhileDescriptionEscapesRoundTrip() throws {
        for url in ["", "/line\n", "/tab\t", "/nul\0", "/del\u{7F}", "/next\u{85}"] {
            assertError(.invalidSchema, try codec.validate(document(manga: [.init(sourceID: 1, url: url)])))
        }
        for title in ["before\0after"] {
            assertError(.invalidSchema, try codec.validate(document(manga: [.init(sourceID: 1, url: "/m", title: title)])))
        }
        let description = "Quote \" slash / backslash \\ newline\n tab\t bell\u{1} emoji 😀"
        let fixture = document(manga: [.init(sourceID: 1, url: "/m", descriptionText: description)])
        XCTAssertEqual(try codec.decode(codec.encode(fixture)).manga[0].descriptionText, description)
        let input = try changedJSON { object in changeFirstManga(&object) { $0["descriptionText"] = "before\0after" } }
        assertError(.invalidSchema, try codec.decode(input))
    }

    func testPolicyCannotRaiseAnyCeilingOrAcceptNegativeCounts() throws {
        let invalid: [() throws -> LibraryBackupPolicy] = [
            { try .init(maximumInputBytes: 64 * 1024 * 1024 + 1) }, { try .init(maximumDepth: 33) },
            { try .init(maximumJSONValues: 4_000_001) }, { try .init(maximumJSONStringBytes: 64 * 1024 * 1024 + 1) },
            { try .init(maximumJSONObjectKeys: 65) }, { try .init(maximumJSONArrayElements: 100_001) },
            { try .init(maximumManga: 10_001) }, { try .init(maximumSources: 10_001) },
            { try .init(maximumCategories: 1_001) }, { try .init(maximumChapters: 100_001) },
            { try .init(maximumHistory: 100_001) }, { try .init(maximumKnownChapters: 100_001) },
            { try .init(maximumMemberships: 100_001) }, { try .init(maximumChaptersPerManga: 20_001) },
            { try .init(maximumAlternateTitles: 257) }, { try .init(maximumGenres: 257) },
            { try .init(maximumURLBytes: 4_097) }, { try .init(maximumLabelBytes: 1_025) },
            { try .init(maximumMetadataBytes: 8_193) }, { try .init(maximumDescriptionBytes: 256 * 1024 + 1) },
            { try .init(maximumTotalStringBytes: 32 * 1024 * 1024 + 1) },
            { try .init(maximumInputBytes: 0) }, { try .init(maximumDepth: 0) }, { try .init(maximumManga: -1) },
        ]
        for create in invalid { assertError(.invalidPolicy, try create()) }
        let empty = document(sources: [])
        XCTAssertNoThrow(try LibraryBackupCodec(policy: .init(maximumManga: 0, maximumSources: 0,
                                                             maximumCategories: 0)).validate(empty))
    }

    func testInputLimitIsInclusiveAndWriterRejectsEscapedExpansionDuringAppend() throws {
        let empty = document(sources: [])
        let bytes = try codec.encode(empty)
        let exact = LibraryBackupCodec(policy: try .init(maximumInputBytes: bytes.count))
        XCTAssertEqual(try exact.encode(empty), bytes)
        XCTAssertEqual(try exact.decode(bytes), empty)
        let small = LibraryBackupCodec(policy: try .init(maximumInputBytes: bytes.count - 1))
        assertError(.limitExceeded(.inputBytes), try small.encode(empty))
        assertError(.limitExceeded(.inputBytes), try small.decode(bytes))
        let expanded = document(manga: [.init(sourceID: 1, url: "/m", descriptionText: String(repeating: "\u{1}", count: 2_000))])
        let policy = try LibraryBackupPolicy(maximumInputBytes: 1_024)
        XCTAssertNoThrow(try LibraryBackupCodec(policy: policy).validate(expanded))
        var writer = LibraryBackupJSONWriter(policy: policy)
        assertError(.limitExceeded(.inputBytes), try writer.write(expanded))
        XCTAssertLessThanOrEqual(writer.data.count, 1_024)
    }

    func testPreflightDepthValuesKeysAndArrayElementsHaveInclusiveLimits() throws {
        XCTAssertNoThrow(try preflight("[0]", policy: .init(maximumDepth: 2, maximumJSONValues: 2)))
        assertError(.limitExceeded(.depth), try preflight("[[0]]", policy: .init(maximumDepth: 2)))
        assertError(.limitExceeded(.jsonValues), try preflight("[0,1]", policy: .init(maximumJSONValues: 2)))
        XCTAssertNoThrow(try preflight(#"{"a":0,"b":1}"#, policy: .init(maximumJSONObjectKeys: 2)))
        assertError(.limitExceeded(.jsonObjectKeys), try preflight(#"{"a":0,"b":1}"#, policy: .init(maximumJSONObjectKeys: 1)))
        XCTAssertNoThrow(try preflight("[0,1]", policy: .init(maximumJSONArrayElements: 2)))
        assertError(.limitExceeded(.jsonArrayElements), try preflight("[0,1,2]", policy: .init(maximumJSONArrayElements: 2)))
        let empty = document(sources: [])
        assertError(.limitExceeded(.jsonObjectKeys), try LibraryBackupCodec(policy: .init(maximumJSONObjectKeys: 7)).encode(empty))
    }

    func testPreflightStringBudgetCountsDecodedUTF8IncludingKeysAndSurrogatePairs() throws {
        let escaped = #"{"a":"\ud83d\ude00"}"#
        XCTAssertNoThrow(try preflight(escaped, policy: .init(maximumJSONStringBytes: 5)))
        assertError(.limitExceeded(.jsonStringBytes), try preflight(escaped, policy: .init(maximumJSONStringBytes: 4)))
        XCTAssertNoThrow(try preflight(#"["\n","é"]"#, policy: .init(maximumJSONStringBytes: 3)))
        assertError(.limitExceeded(.jsonStringBytes), try preflight(#"["\n","é"]"#, policy: .init(maximumJSONStringBytes: 2)))
    }

    func testEntityCountsAreCumulativeAcrossMangaWithInclusiveBoundaries() throws {
        let fixture = document(sources: [.init(sourceID: 1, name: ""), .init(sourceID: 2, name: "")],
                               categories: [.init(key: "a", name: "A"), .init(key: "b", name: "B")],
                               manga: [1, 2].map { id in .init(sourceID: Int64(id), url: "/m", inLibrary: true,
                                   categoryKeys: [id == 1 ? "a" : "b"], chapters: [.init(url: "/c", name: "")],
                                   history: [.init(chapterURL: "/c")], knownChapters: [.init(url: "/gone", firstSeen: 0)]) })
        let exact = LibraryBackupCodec(policy: try .init(maximumManga: 2, maximumSources: 2, maximumCategories: 2,
            maximumChapters: 2, maximumHistory: 2, maximumKnownChapters: 2, maximumMemberships: 2))
        XCTAssertNoThrow(try exact.validate(fixture))
        let bounds: [(LibraryBackupPolicy, LibraryBackupError.Limit)] = [
            (try .init(maximumManga: 1), .manga), (try .init(maximumSources: 1), .sources),
            (try .init(maximumCategories: 1), .categories), (try .init(maximumChapters: 1), .chapters),
            (try .init(maximumHistory: 1), .history), (try .init(maximumKnownChapters: 1), .knownChapters),
            (try .init(maximumMemberships: 1), .memberships),
        ]
        for (policy, limit) in bounds { assertError(.limitExceeded(limit), try LibraryBackupCodec(policy: policy).validate(fixture)) }
        assertError(.limitExceeded(.chaptersPerManga), try LibraryBackupCodec(policy: .init(maximumChaptersPerManga: 1)).validate(fullDocument()))
    }

    func testFieldAndTotalStringBudgetsCountUTF8AndRepeatedOccurrences() throws {
        let urls = document(sources: [.init(sourceID: 1, name: "")], manga: [.init(sourceID: 1, url: "é")])
        XCTAssertNoThrow(try LibraryBackupCodec(policy: .init(maximumURLBytes: 2, maximumTotalStringBytes: 2)).validate(urls))
        assertError(.limitExceeded(.urlBytes), try LibraryBackupCodec(policy: .init(maximumURLBytes: 1)).validate(urls))
        let repeated = document(sources: [.init(sourceID: 1, name: "")], manga: [.init(sourceID: 1, url: "/m",
            chapters: [.init(url: "/c", name: "")], history: [.init(chapterURL: "/c")], knownChapters: [.init(url: "/c", firstSeen: 0)])])
        XCTAssertNoThrow(try LibraryBackupCodec(policy: .init(maximumTotalStringBytes: 8)).validate(repeated))
        assertError(.limitExceeded(.totalStringBytes), try LibraryBackupCodec(policy: .init(maximumTotalStringBytes: 7)).validate(repeated))
        let metadata = document(manga: [.init(sourceID: 1, url: "/m", title: String(repeating: "a", count: 1_025))])
        XCTAssertNoThrow(try codec.validate(metadata)) // manga metadata is 8 KiB, source/category labels are 1 KiB.
        assertError(.limitExceeded(.metadataBytes), try LibraryBackupCodec(policy: .init(maximumMetadataBytes: 1_024)).validate(metadata))
        assertError(.limitExceeded(.labelBytes), try LibraryBackupCodec(policy: .init(maximumLabelBytes: 2)).validate(document()))
        let description = document(manga: [.init(sourceID: 1, url: "/m", descriptionText: "éé")])
        XCTAssertNoThrow(try LibraryBackupCodec(policy: .init(maximumDescriptionBytes: 4)).validate(description))
        assertError(.limitExceeded(.descriptionBytes), try LibraryBackupCodec(policy: .init(maximumDescriptionBytes: 3)).validate(description))
        assertError(.limitExceeded(.alternateTitles), try LibraryBackupCodec(policy: .init(maximumAlternateTitles: 1)).validate(fullDocument()))
        assertError(.limitExceeded(.genres), try LibraryBackupCodec(policy: .init(maximumGenres: 1)).validate(fullDocument()))
    }

    func testCancellationIsCheckedForEncodeDecodeAndValidation() async throws {
        let fixture = document(sources: [])
        let encoded = try codec.encode(fixture)
        let localCodec = codec
        let operations: [@Sendable () throws -> Void] = [
            { _ = try localCodec.encode(fixture) }, { _ = try localCodec.decode(encoded) },
            { try localCodec.validate(fixture) },
        ]
        for operation in operations {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try operation()
            }
            do { try await task.value; XCTFail("Cancelled operation unexpectedly completed") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected cancellation error: \(error)") }
        }
    }
}
