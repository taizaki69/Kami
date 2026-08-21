import XCTest
@testable import MihonCompatKit

final class RepositoryIndexTests: XCTestCase {
    /// Hand-built protobuf wire bytes for one Extension message, verifying the
    /// wire decoder against the tachiyomix index.proto schema.
    func testProtoStoreIndex() throws {
        func varint(_ v: UInt64) -> [UInt8] {
            var out: [UInt8] = []
            var value = v
            repeat {
                var b = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { b |= 0x80 }
                out.append(b)
            } while value != 0
            return out
        }
        func tag(_ field: Int, _ wt: Int) -> [UInt8] { varint(UInt64(field << 3 | wt)) }
        func lenDelim(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
            tag(field, 2) + varint(UInt64(payload.count)) + payload
        }
        func str(_ field: Int, _ s: String) -> [UInt8] { lenDelim(field, Array(s.utf8)) }

        // Source { id=1: 42, name=2: "MangaDex", language=3: "en", homeUrl=4: "https://mangadex.org" }
        let source = varint(UInt64(1 << 3 | 0)) + varint(42)
            + str(2, "MangaDex") + str(3, "en") + str(4, "https://mangadex.org")
        // Resources { apkUrl=1: "https://example.com/e.apk", iconUrl=2: "i.png" }
        let resources = str(1, "https://example.com/e.apk") + str(2, "i.png")
        // Extension { name=1, packageName=2, resources=3, extensionLib=4,
        //             versionCode=5, versionName=6, contentWarning=7, sources=8 }
        let ext = str(1, "MangaDex") + str(2, "eu.kanade.tachiyomi.extension.all.mangadex")
            + lenDelim(3, resources) + str(4, "1.6")
            + varint(UInt64(5 << 3 | 0)) + varint(212) + str(6, "1.4.212")
            + varint(UInt64(7 << 3 | 0)) + varint(2)
            + lenDelim(8, source)
        // ExtensionList { extensions=1: [...] } → Index.extensions(101)
        let list = lenDelim(1, ext)
        let index = str(1, "Keiyoushi") + str(2, "KEI") + str(3, "signing-key-material")
            + lenDelim(101, list)

        let parsed = try ExtensionRepositoryIndex(bytes: index, url: URL(fileURLWithPath: "index.pb"))
        XCTAssertEqual(parsed.storeName, "Keiyoushi")
        XCTAssertEqual(parsed.badgeLabel, "KEI")
        XCTAssertEqual(parsed.signingKey, "signing-key-material")
        XCTAssertEqual(parsed.extensions.count, 1)

        let e = try XCTUnwrap(parsed.extensions.first)
        XCTAssertEqual(e.name, "MangaDex")
        XCTAssertEqual(e.packageName, "eu.kanade.tachiyomi.extension.all.mangadex")
        XCTAssertEqual(e.extensionLib, "1.6")
        XCTAssertEqual(e.versionCode, 212)
        XCTAssertEqual(e.versionName, "1.4.212")
        XCTAssertEqual(e.contentWarning, .mixed)
        XCTAssertEqual(e.apkURL, "https://example.com/e.apk")
        XCTAssertEqual(e.iconURL, "i.png")
        XCTAssertEqual(e.sources.count, 1)
        XCTAssertEqual(e.sources.first?.id, 42)
        XCTAssertEqual(e.sources.first?.name, "MangaDex")
        XCTAssertEqual(e.sources.first?.language, "en")
        XCTAssertEqual(e.sources.first?.homeURL, "https://mangadex.org")
    }

    /// Legacy keiyoushi index.min.json schema (verified against the live repo).
    func testLegacyJSONIndex() throws {
        let json = """
        [{"name":"MangaDex","pkg":"eu.kanade.tachiyomi.extension.all.mangadex",
          "apk":"tachiyomi-all.mangadex-v1.4.212.apk","lang":"all","code":212,
          "version":"1.4.212","nsfw":0,
          "sources":[{"name":"MangaDex","lang":"en","id":"2499283573021220255",
                      "baseUrl":"https://mangadex.org"}]}]
        """
        let url = URL(string: "https://example.com/repo/index.min.json")!
        let parsed = try ExtensionRepositoryIndex(bytes: Array(json.utf8), url: url)
        XCTAssertEqual(parsed.extensions.count, 1)
        let e = try XCTUnwrap(parsed.extensions.first)
        XCTAssertEqual(e.packageName, "eu.kanade.tachiyomi.extension.all.mangadex")
        XCTAssertEqual(e.versionCode, 212)
        // APK filename resolves relative to the index URL.
        XCTAssertEqual(e.apkURL, "https://example.com/repo/tachiyomi-all.mangadex-v1.4.212.apk")
        XCTAssertEqual(e.sources.first?.id, 2_499_283_573_021_220_255)
    }
}

final class ProtoReaderTests: XCTestCase {
    func testVarintLengthDelimitedFixed32() throws {
        // field 1 varint 300; field 2 string "ok"; field 3 fixed32 (12345).
        let bytes: [UInt8] = [0x08, 0xAC, 0x02, 0x12, 0x02, 0x6F, 0x6B, 0x1D]
            + [0x39, 0x30, 0x00, 0x00]
        let msg = try ProtoMessage(bytes)
        XCTAssertEqual(msg.int64(1), 300)
        XCTAssertEqual(msg.string(2), "ok")
        // 12345 as IEEE-754 float bit pattern.
        XCTAssertEqual(msg.float(3), Float(bitPattern: 12345))
        XCTAssertNil(msg.string(3))
    }

    func testUnknownFieldsCoexist() throws {
        // field 1 varint 1, field 4 fixed64, then field 2 varint 42 — decoder
        // must skip the middle field by wire type.
        let bytes: [UInt8] = [0x08, 0x01, 0x21, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x2A]
        let msg = try ProtoMessage(bytes)
        XCTAssertEqual(msg.int(1), 1)
        XCTAssertEqual(msg.int(2), 42)
        XCTAssertNil(msg.fields[5])
    }
}
