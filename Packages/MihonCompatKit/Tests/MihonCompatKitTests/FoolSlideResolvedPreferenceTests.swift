import Foundation
import XCTest
import MihonCompatKit

/// The pure product resolver's values are exercised against the exact APK;
/// validating an editor draft is never used as a source execution shortcut.
final class FoolSlideResolvedPreferenceTests: XCTestCase {
    private actor FixtureTransport: CompatHTTPTransport {
        nonisolated let sourceID = "foolslide-resolved-preferences"
        private var requests: [CompatHTTPRequest] = []
        let response: CompatHTTPResponse

        init(url: String) {
            response = CompatHTTPResponse(
                finalURL: url, statusCode: 200,
                body: Array(#"<script>var pages = [{"url":"/images/one.jpg"}];</script>"#.utf8)
            )
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private static let baseURL = "https://configured-foolslide.example"

    private func schema() throws -> InterpretedExtensionPreferenceSchema {
        try XCTUnwrap(InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: "eu.kanade.tachiyomi.extension.all.foolslidecustomizable",
            versionName: "1.6.6", versionCode: 6
        ))
    }

    private func apkBytes() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/foolslidecustomizable.apk")
        return [UInt8](try Data(contentsOf: path))
    }

    func testResolvedUserValuesDriveExactAdultAndNonAdultRequests() async throws {
        let schema = try schema()
        let bytes = try apkBytes()
        for adult in [false, true] {
            let resolved = try schema.validateUserValues([
                .baseURL: .string(Self.baseURL), .adult: .boolean(adult),
            ])
            try await assertRequest(resolved, schema: schema, bytes: bytes, adult: adult)
        }
    }

    func testOmittedAdultUsesMeasuredDefaultInActualRequest() async throws {
        let schema = try schema()
        let resolved = try schema.validateUserValues([.baseURL: .string(Self.baseURL)])
        try await assertRequest(resolved, schema: schema, bytes: apkBytes(), adult: true)
    }

    private func assertRequest(
        _ resolved: ResolvedExtensionPreferences,
        schema: InterpretedExtensionPreferenceSchema,
        bytes: [UInt8],
        adult: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = Self.baseURL + "/read/title/en/0/1/"
        let transport = FixtureTransport(url: url)
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: bytes, transport: transport,
            preferences: resolved.runtimePreferences
        )
        XCTAssertEqual(Set([source.id]), schema.identity.sourceIDs, file: file, line: line)
        XCTAssertEqual(source.baseURL, Self.baseURL, file: file, line: line)
        let constructionRequests = await transport.snapshot()
        XCTAssertEqual(constructionRequests, [], file: file, line: line)

        let pages = try await source.getPageList(chapter: .init(
            url: "/read/title/en/0/1/", name: "Chapter 1"
        ))
        XCTAssertEqual(pages.map(\.index), [0], file: file, line: line)
        XCTAssertEqual(pages.map(\.url), [""], file: file, line: line)
        XCTAssertEqual(pages.map(\.imageURL), [Self.baseURL + "/images/one.jpg"],
                       file: file, line: line)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [CompatHTTPRequest(
            url: url, method: adult ? "POST" : "GET",
            headers: [
                CompatHTTPHeader(name: "Referer", value: Self.baseURL + "/"),
                CompatHTTPHeader(name: "Origin", value: Self.baseURL),
            ],
            body: adult ? .form(fields: [CompatHTTPFormField(name: "adult", value: "true")]) : nil,
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        )], file: file, line: line)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty, file: file, line: line)
    }
}
