import XCTest
@testable import MihonCompatKit

/// Executes REAL methods from REAL current extension APKs (mission §31/§38).
/// The corpus is fetched by `scripts/fetch_corpus.sh` (CI does this too);
/// tests skip when the corpus is absent so unit runs stay deterministic.
final class RealExtensionExecutionTests: XCTestCase {
    private func corpusAPK(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/MihonCompatKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/MihonCompatKit
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami (repo root)
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func loadVM(_ apk: String) throws -> (DexInterpreter, ExtensionManifest) {
        let bytes = try corpusAPK(apk)
        let manifest = try ExtensionManifest(apkBytes: bytes)
        let zip = try ZipArchive(bytes)
        let dex = try DexFile(try zip.data(named: "classes.dex"))
        return (DexInterpreter(dex: dex), manifest)
    }

    /// BatCave 1.6.9 (lib 1.6): getBaseUrl() = const-string/return-object —
    /// the first method from a real extension APK executed by Kami's VM.
    func testBatCaveGetBaseUrl() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getBaseUrl",
            args: [receiver]
        )
        let url = vmStringValue(result)
        XCTAssertTrue(url.hasPrefix("https://"), "expected a URL, got: \(url)")
        XCTAssertFalse(url.isEmpty)
    }

    func testBatCaveGetLang() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getLang",
            args: [receiver]
        )
        XCTAssertEqual(vmStringValue(result), "en")
    }

    func testBatCaveGetName() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getName",
            args: [receiver]
        )
        XCTAssertEqual(vmStringValue(result), "BatCave")
    }

    /// getId(): const-wide + return-wide — 64-bit path from a real APK.
    func testBatCaveGetId() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getId",
            args: [receiver]
        )
        guard case let .long(id) = result else {
            return XCTFail("expected long, got \(result)")
        }
        XCTAssertGreaterThan(id, 0, "Mihon source ids are positive 63-bit values")
    }

    /// The real generated source constructor now executes through its Kotlin
    /// lazy/reflection/atomic setup instead of using a fabricated receiver.
    func testBatCaveConstructorExecutes() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let value = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(object) = value else {
            return XCTFail("expected BatCave object, got \(value)")
        }
        XCTAssertEqual(object.dexType, cls)
    }

    /// Characterizes the next honest boundary for a complete popular-manga
    /// request. This locks all interpreted work before OkHttp form encoding:
    /// class initialization, filters, collections, iteration, and Kotlin ABI.
    func testBatCavePopularReachesHTTPBridgeFrontier() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)
        XCTAssertThrowsError(try vm.call(
            classDescriptor: cls,
            method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(1), .null]
        )) { error in
            guard case let VMError.unresolvedMethod(classDescriptor, signature) = error else {
                return XCTFail("expected exact OkHttp frontier, got \(error)")
            }
            XCTAssertEqual(classDescriptor, "Lokhttp3/FormBody$Builder;")
            XCTAssertEqual(
                signature,
                "<init>(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V"
            )
        }
    }

    /// MangaDex 1.4.212: the factory entry class's REAL constructor executes
    /// (invoke-direct Object.<init> + return-void). Its getters are iget-based
    /// (instance state from the host HttpSource superclass) — that is the M2/M3
    /// frontier, honestly out of scope for this test.
    func testMangaDexConstructorExecutes() throws {
        let (vm, manifest) = try loadVM("mangadex")
        let cls = "L" + (manifest.resolvedSourceClass ?? "").replacingOccurrences(of: ".", with: "/") + ";"
        let obj = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(o) = obj, o.dexType == cls else {
            return XCTFail("expected instance of \(cls)")
        }
    }

    /// Akuma 1.4.10 (27-source multisrc): execute the real factory constructor
    /// and require a real object, rather than treating any VM error as success.
    func testAkumaConstructorExecutes() throws {
        let (vm, manifest) = try loadVM("akuma")
        let cls = "L" + (manifest.resolvedSourceClass ?? "").replacingOccurrences(of: ".", with: "/") + ";"
        let obj = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(o) = obj, o.dexType == cls else {
            return XCTFail("expected instance of \(cls)")
        }
    }
}
