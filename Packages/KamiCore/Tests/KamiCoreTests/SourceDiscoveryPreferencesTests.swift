import Foundation
import XCTest
@testable import KamiCore

final class SourceDiscoveryPreferencesTests: XCTestCase {
    func testAllNoneIntersectionAndRegionalLanguageIdentity() throws {
        XCTAssertTrue(SourceDiscoveryPreferences.all.includes(sourceID: -8, language: "new-language"))
        XCTAssertFalse(SourceDiscoveryPreferences.none.includes(sourceID: 1, language: "en"))
        let selection = try SourceDiscoveryPreferences(sourceIDs: [1, -8], languages: ["EN", "pt-BR", "all"])
        XCTAssertEqual(selection.languages, ["en", "pt-br", "all"])
        XCTAssertTrue(selection.includes(sourceID: -8, language: "PT-br"))
        XCTAssertTrue(selection.includes(sourceID: 1, language: "all"))
        XCTAssertFalse(selection.includes(sourceID: 2, language: "en"))
        XCTAssertFalse(selection.includes(sourceID: 1, language: "pt"))
        XCTAssertFalse(selection.includes(sourceID: 1, language: "fr"))
        XCTAssertFalse(selection.includes(sourceID: 1, language: " en "))
        XCTAssertFalse(try SourceDiscoveryPreferences(sourceIDs: nil, languages: []).includes(sourceID: 1, language: "en"))
    }

    func testCanonicalRoundTripRetainsSignedIDsUnavailableChoicesAndExplicitEmptyLists() throws {
        let selected = try SourceDiscoveryPreferences(sourceIDs: [Int64.min, Int64.max, 9], languages: ["ZH-hans", "en"])
        let data = try selected.encoded()
        XCTAssertEqual(try SourceDiscoveryPreferences.decode(data), selected)
        XCTAssertEqual(try SourceDiscoveryPreferences(sourceIDs: [9, Int64.max, Int64.min], languages: ["en", "zh-Hans"]).encoded(), data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"-9223372036854775808\""))
        XCTAssertTrue(json.contains("\"9223372036854775807\""))
        XCTAssertFalse(selected.includes(sourceID: 100, language: "en"), "Newly enabled IDs must not enter an explicit selection")
        for value in [SourceDiscoveryPreferences.all, .none,
                      try .init(sourceIDs: nil, languages: []), try .init(sourceIDs: [], languages: [])] {
            XCTAssertEqual(try SourceDiscoveryPreferences.decode(value.encoded()), value)
        }
    }

    func testMalformedAmbiguousAndOversizedDocumentsCannotExpandSelection() throws {
        let invalid = [
            "{}", "null", "[]", "{\"version\":1,\"sourceIDs\":null}",
            "{\"version\":2,\"sourceIDs\":null,\"languages\":null}",
            "{\"version\":true,\"sourceIDs\":null,\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[],\"languages\":null,\"extra\":0}",
            "{\"version\":1,\"sourceIDs\":[],\"sourceIDs\":null,\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[],\"source\\u0049Ds\":null,\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[1],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[\"1\",\"1\"],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[\"01\"],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[\"-0\"],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[\"+1\"],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[\"9223372036854775808\"],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":[[[[]]]],\"languages\":null}",
            "{\"version\":1,\"sourceIDs\":null,\"languages\":[\"en\",\"EN\"]}",
            "{\"version\":1,\"sourceIDs\":null,\"languages\":[\"en\",\"en\"]}",
            "{\"version\":1,\"sourceIDs\":null,\"languages\":[\"en--us\"]}",
            "{\"version\":1,\"sourceIDs\":null,\"languages\":[\"en_US\"]}",
            "{\"version\":1,\"sourceIDs\":null,\"languages\":[\"é\"]}"
        ]
        for text in invalid {
            XCTAssertThrowsError(try SourceDiscoveryPreferences.decode(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try SourceDiscoveryPreferences.decode(Data(repeating: 0x20, count: 131_073)))
        for tag in ["", "-en", "en-", "https://private.invalid", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try SourceDiscoveryPreferences(sourceIDs: nil, languages: [tag]))
        }
    }

    func testLargestSupportedSelectionRoundTripsAndCountLimitsReject() throws {
        let ids = Set((0..<4_096).map { Int64.min + Int64($0) })
        let tags = Set((0..<256).map { "x-\($0)-" + String(repeating: "a", count: 50) })
        let value = try SourceDiscoveryPreferences(sourceIDs: ids, languages: tags)
        let data = try value.encoded()
        XCTAssertLessThanOrEqual(data.count, SourceDiscoveryPreferences.maximumBytes)
        XCTAssertEqual(try SourceDiscoveryPreferences.decode(data), value)
        XCTAssertThrowsError(try SourceDiscoveryPreferences(sourceIDs: ids.union([1]), languages: nil))
        XCTAssertThrowsError(try SourceDiscoveryPreferences(sourceIDs: nil, languages: tags.union(["en"])))
    }

    @MainActor
    private final class Memory {
        enum Failure: Error { case unavailable }
        enum WriteMode { case normal, failBefore, failAfter, ignore, replace }
        var data: Data?
        var failRead = false
        var mode = WriteMode.normal
        var writes = 0
        func read() throws -> Data? {
            if failRead { throw Failure.unavailable }
            return data
        }
        func write(_ value: Data) throws {
            writes += 1
            switch mode {
            case .normal: data = value
            case .failBefore: throw Failure.unavailable
            case .failAfter: data = value; throw Failure.unavailable
            case .ignore: break
            case .replace: data = Data("unexpected".utf8)
            }
        }
        func store() -> SourceDiscoveryStore { .init(read: { try self.read() }, write: { try self.write($0) }) }
    }

    @MainActor
    func testAtomicFilePersistsSelectionAcrossReopenIncludingNone() async throws {
        for existingParent in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            if existingParent { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let file = directory.appendingPathComponent("source-selection.json")
            do {
                let handle = try FileHandle(forReadingFrom: file)
                try handle.close()
                XCTFail("The fixture file must not exist before first launch")
            } catch {
                let failure = error as NSError
                XCTAssertTrue(SourceDiscoveryStore.isMissingFile(error),
                    "Unrecognized missing-file error: \(failure.domain)/\(failure.code)")
            }
            let store = SourceDiscoveryStore(fileURL: file)
            XCTAssertEqual(store.state.preferences, .all)
            XCTAssertFalse(store.state.requiresRecovery)
            let chosen = try SourceDiscoveryPreferences(sourceIDs: [-8, 99], languages: ["PT-br"])
            try store.save(chosen, expectedRevision: store.state.revision)
            XCTAssertEqual(try Data(contentsOf: file), try chosen.encoded())
            let reopened = SourceDiscoveryStore(fileURL: file)
            XCTAssertEqual(reopened.state.preferences, chosen)
            try reopened.save(.none, expectedRevision: reopened.state.revision)
            XCTAssertEqual(SourceDiscoveryStore(fileURL: file).state.preferences, .none)
        }
    }

    func testMissingFileCodesAreRecognizedWithoutTreatingOtherReadFailuresAsAbsence() {
        for error: Error in [CocoaError(.fileNoSuchFile), CocoaError(.fileReadNoSuchFile), POSIXError(.ENOENT)] {
            XCTAssertTrue(SourceDiscoveryStore.isMissingFile(error))
        }
        let unknownWithMissingUnderlying = NSError(domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
        for error: Error in [CocoaError(.fileReadNoPermission), CocoaError(.fileReadCorruptFile),
                             POSIXError(.EACCES), POSIXError(.EIO), unknownWithMissingUnderlying,
                             NSError(domain: "unrelated", code: Int(POSIXErrorCode.ENOENT.rawValue))] {
            XCTAssertFalse(SourceDiscoveryStore.isMissingFile(error))
        }
    }

    @MainActor
    func testRevisionsRejectStaleAndABAEditsAndNoOpKeepsCurrentSearchAlive() async throws {
        let memory = Memory()
        let store = memory.store()
        let first = store.snapshot()
        try store.save(.all, expectedRevision: first.id)
        XCTAssertEqual(memory.writes, 0)
        XCTAssertTrue(first.isCurrent)
        try store.save(.none, expectedRevision: first.id)
        XCTAssertFalse(first.isCurrent)
        let second = store.snapshot()
        XCTAssertThrowsError(try store.save(.all, expectedRevision: first.id)) {
            XCTAssertEqual($0 as? SourceDiscoveryPreferencesError, .staleSelection)
        }
        XCTAssertTrue(second.isCurrent)
        try store.save(.all, expectedRevision: second.id)
        XCTAssertFalse(second.isCurrent)
        XCTAssertNotEqual(first.id, store.state.revision)
        XCTAssertThrowsError(try store.save(.none, expectedRevision: first.id))
    }

    @MainActor
    func testCorruptAndUnreadableStorageRequireExplicitRecoveryWithoutWidening() async throws {
        let memory = Memory()
        memory.data = Data("broken".utf8)
        let store = memory.store()
        XCTAssertTrue(store.state.requiresRecovery)
        XCTAssertEqual(store.state.preferences, .none)
        XCTAssertEqual(memory.data, Data("broken".utf8), "Loading must preserve the unreadable file")
        try store.save(.none, expectedRevision: store.state.revision)
        XCTAssertFalse(store.state.requiresRecovery)
        XCTAssertEqual(try SourceDiscoveryPreferences.decode(XCTUnwrap(memory.data)), .none)

        memory.failRead = true
        let unreadable = memory.store()
        XCTAssertTrue(unreadable.state.requiresRecovery)
        XCTAssertEqual(unreadable.state.preferences, .none)
        let old = unreadable.snapshot()
        XCTAssertThrowsError(try unreadable.save(.all, expectedRevision: old.id))
        XCTAssertFalse(old.isCurrent)
        memory.failRead = false
        XCTAssertThrowsError(try unreadable.save(.all, expectedRevision: unreadable.state.revision))
        XCTAssertEqual(unreadable.state.preferences, .none)
        try unreadable.save(.all, expectedRevision: unreadable.state.revision)
        XCTAssertFalse(unreadable.state.requiresRecovery)
    }

    @MainActor
    func testChangedOrDeletedPersistedBytesInvalidatePendingEditsBeforeWriting() async throws {
        for external in [try SourceDiscoveryPreferences.none.encoded(), nil] {
            let memory = Memory()
            memory.data = try SourceDiscoveryPreferences(sourceIDs: [1], languages: nil).encoded()
            let store = memory.store()
            let old = store.snapshot()
            memory.data = external
            XCTAssertThrowsError(try store.save(.all, expectedRevision: old.id)) {
                XCTAssertEqual($0 as? SourceDiscoveryPreferencesError, .staleSelection)
            }
            XCTAssertEqual(memory.writes, 0)
            XCTAssertFalse(old.isCurrent)
            XCTAssertEqual(store.state.preferences, .none)
            XCTAssertTrue(store.state.requiresRecovery)
            try store.save(.none, expectedRevision: store.state.revision)
            XCTAssertFalse(store.state.requiresRecovery)
        }
    }

    @MainActor
    func testWriteFailureOrUnconfirmedReadbackRevokesSearchAndCanBeReviewedAgain() async throws {
        for mode in [Memory.WriteMode.failBefore, .failAfter, .ignore, .replace] {
            let memory = Memory()
            memory.data = try SourceDiscoveryPreferences(sourceIDs: [1], languages: nil).encoded()
            let store = memory.store()
            let original = store.snapshot()
            memory.mode = mode
            XCTAssertThrowsError(try store.save(.all, expectedRevision: original.id)) {
                XCTAssertEqual($0 as? SourceDiscoveryPreferencesError, .persistenceUnavailable)
            }
            XCTAssertFalse(original.isCurrent)
            XCTAssertEqual(store.state.preferences, .none)
            XCTAssertTrue(store.state.requiresRecovery)
            memory.mode = .normal
            try store.save(.none, expectedRevision: store.state.revision)
            XCTAssertFalse(store.state.requiresRecovery)
            XCTAssertEqual(try SourceDiscoveryPreferences.decode(XCTUnwrap(memory.data)), .none)
        }
    }

    @MainActor
    func testOversizedFileRemainsUntouchedUntilReviewedRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("selection.json")
        let oversized = Data(repeating: 0x20, count: 300_000)
        try oversized.write(to: file)
        let store = SourceDiscoveryStore(fileURL: file)
        XCTAssertEqual(store.state.preferences, .none)
        XCTAssertTrue(store.state.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: file), oversized)
        try store.save(.none, expectedRevision: store.state.revision)
        XCTAssertEqual(try Data(contentsOf: file), try SourceDiscoveryPreferences.none.encoded())
    }
}
