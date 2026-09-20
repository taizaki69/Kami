import Foundation
import XCTest
@testable import MihonCompatKit

final class EternalMangasRuntimeTests: XCTestCase {
    private actor RejectingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "eternal-construction-probe"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("construction must not execute a request")
            throw CompatHTTPTransportError.invalidResponse
        }
    }

    func testExactEternalMangasConstructionAndMetadataProbe() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/eternalmangas.apk")
        let bytes = [UInt8](try Data(contentsOf: path))
        let archive = try ZipArchive(bytes)
        let dex = try DexFile(try archive.data(named: "classes.dex"))
        let bridge = HostBridge.minimal(
            transport: RejectingTransport(),
            resources: try .localization(from: archive)
        )
        let vm = DexInterpreter(dex: dex, bridge: bridge)
        let receiver = try vm.instantiate(
            classDescriptor: "Leu/kanade/tachiyomi/extension/es/eternalmangas/ExtensionGenerated;"
        )
        for method in ["getName", "getLang", "getBaseUrl"] {
            let value = try vm.callVirtualEntry(
                receiver: receiver,
                method: method,
                prototype: "()Ljava/lang/String;",
                args: [receiver]
            )
            print("ETERNAL \(method): \(vmStringValue(value))")
        }
        let filters = try vm.callVirtualEntry(
            receiver: receiver,
            method: "getFilterList",
            prototype: "()Leu/kanade/tachiyomi/source/model/FilterList;",
            args: [receiver]
        )
        print("ETERNAL filters: \(String(describing: HostBridge.sourceFilters(from: filters)))")
    }
}
