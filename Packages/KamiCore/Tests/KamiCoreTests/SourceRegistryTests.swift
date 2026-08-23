import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class SourceRegistryTests: XCTestCase {
    private actor NoNetworkTransport: CompatHTTPTransport {
        nonisolated let sourceID = "batcave-registry-test"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("registry test must not perform network I/O: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/KamiCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KamiCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami (repo root)
            .appendingPathComponent("Tests/corpus/batcave.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK batcave.apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    func testRegistryAcceptsPinnedInterpretedSourceAndDeduplicatesItsID() async throws {
        let source = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: NoNetworkTransport()
        )
        try await MainActor.run {
            let registry = SourceRegistry()
            let initialCount = registry.sources.count

            registry.add(source)
            registry.add(source)

            XCTAssertEqual(registry.sources.count, initialCount + 1)
            let registered = try XCTUnwrap(registry.source(id: source.id))
            XCTAssertEqual(registered.name, "BatCave")
            XCTAssertEqual(registered.language, "en")
            XCTAssertEqual(registered.baseURL, "https://batcave.biz")
        }
    }
}
