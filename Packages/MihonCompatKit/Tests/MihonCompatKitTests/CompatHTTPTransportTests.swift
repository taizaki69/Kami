import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MihonCompatKit

final class CompatHTTPTransportTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        struct Stub {
            let response: HTTPURLResponse
            let chunks: [Data]
        }

        private static let lock = NSLock()
        private static var stubs: [Stub] = []
        private static var capturedRequests: [URLRequest] = []

        static func configure(_ values: [Stub]) {
            lock.lock()
            stubs = values
            capturedRequests = []
            lock.unlock()
        }

        static func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.capturedRequests.append(request)
            let stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
            Self.lock.unlock()
            guard let stub else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.resourceUnavailable)
                )
                return
            }
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testRequestEncodingIsBoundedAndDeterministic() throws {
        let request = CompatHTTPRequest(
            url: "https://example.test/search?q=raw",
            method: "POST",
            headers: [CompatHTTPHeader(name: "Accept", value: "text/html")],
            body: .form(fields: [
                CompatHTTPFormField(name: "query", value: "a b"),
                CompatHTTPFormField(name: "snow", value: "☃"),
            ]),
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 30)
        )
        let encoded = try CompatHTTPRequestEncoder.encode(request, policy: .init())

        XCTAssertEqual(encoded.url?.absoluteString, request.url)
        XCTAssertEqual(encoded.httpMethod, "POST")
        XCTAssertEqual(encoded.value(forHTTPHeaderField: "Accept"), "text/html")
        XCTAssertEqual(
            encoded.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(encoded.value(forHTTPHeaderField: "Cache-Control"), "max-age=30")
        XCTAssertEqual(
            encoded.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            "query=a%20b&snow=%E2%98%83"
        )
    }

    func testRequestEncoderRejectsDirectlyConstructedUnsafeValues() throws {
        XCTAssertThrowsError(try CompatHTTPRequestEncoder.encode(
            CompatHTTPRequest(url: "http://example.test"),
            policy: .init(allowsInsecureHTTP: false)
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .disallowedScheme) }

        XCTAssertThrowsError(try CompatHTTPRequestEncoder.encode(
            CompatHTTPRequest(url: "https://example.test", method: "GET\r\n"),
            policy: .init()
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .invalidMethod) }

        XCTAssertThrowsError(try CompatHTTPRequestEncoder.encode(
            CompatHTTPRequest(
                url: "https://example.test",
                headers: [CompatHTTPHeader(name: "X-Test", value: "ok\r\nInjected: yes")]
            ),
            policy: .init()
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .invalidHeader) }

        XCTAssertThrowsError(try CompatHTTPRequestEncoder.encode(
            CompatHTTPRequest(
                url: "https://example.test",
                method: "POST",
                body: .text(value: "12345", mediaType: "text/plain")
            ),
            policy: .init(maximumRequestBodyBytes: 4)
        )) {
            XCTAssertEqual(
                $0 as? CompatHTTPTransportError,
                .requestBodyTooLarge(limit: 4)
            )
        }

        XCTAssertThrowsError(try CompatHTTPRequestEncoder.encode(
            CompatHTTPRequest(
                url: "https://example.test",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: -1)
            ),
            policy: .init()
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .invalidCachePolicy) }
    }

    func testRedirectPolicyBlocksDowngradeAndStripsCrossOriginSecrets() throws {
        let policy = CompatHTTPTransportPolicy(maximumRedirects: 2)
        let source = try XCTUnwrap(URL(string: "https://one.example/path"))
        var crossOrigin = URLRequest(url: try XCTUnwrap(URL(string: "https://two.example/next")))
        crossOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        crossOrigin.setValue("session=secret", forHTTPHeaderField: "Cookie")
        crossOrigin.setValue("legacy=secret", forHTTPHeaderField: "Cookie2")
        crossOrigin.setValue("keep", forHTTPHeaderField: "X-Test")

        let sanitized = try CompatHTTPRedirectPolicy.sanitizedRequest(
            from: source,
            proposed: crossOrigin,
            redirectCount: 1,
            policy: policy
        )
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie2"))
        XCTAssertEqual(sanitized.value(forHTTPHeaderField: "X-Test"), "keep")

        XCTAssertThrowsError(try CompatHTTPRedirectPolicy.sanitizedRequest(
            from: source,
            proposed: URLRequest(url: try XCTUnwrap(URL(string: "http://one.example/next"))),
            redirectCount: 1,
            policy: policy
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .insecureRedirect) }

        XCTAssertThrowsError(try CompatHTTPRedirectPolicy.sanitizedRequest(
            from: source,
            proposed: crossOrigin,
            redirectCount: 3,
            policy: policy
        )) {
            XCTAssertEqual($0 as? CompatHTTPTransportError, .tooManyRedirects(limit: 2))
        }
    }

    func testGETFollowUpUsesRewrittenLocationAndPreservesOnlySafeCrossOriginHeaders() throws {
        let request = CompatHTTPRequest(
            url: "https://one.example/images/start.jpg",
            headers: [
                CompatHTTPHeader(name: "Authorization", value: "Bearer secret"),
                CompatHTTPHeader(name: "Proxy-Authorization", value: "proxy secret"),
                CompatHTTPHeader(name: "Cookie", value: "session=secret"),
                CompatHTTPHeader(name: "Host", value: "one.example"),
                CompatHTTPHeader(name: "Referer", value: "https://reader.example/"),
            ],
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 30)
        )
        let response = CompatHTTPResponse(
            finalURL: request.url,
            statusCode: 302,
            headers: [
                CompatHTTPHeader(name: "Location", value: "/ignored.jpg"),
                CompatHTTPHeader(name: "Location", value: "https://two.example/final.jpg"),
            ]
        )
        let followUp = try XCTUnwrap(CompatHTTPRedirectPolicy.followUpGETRequest(
            from: request,
            response: response,
            redirectCount: 1,
            policy: .init(maximumRedirects: 2)
        ))

        XCTAssertEqual(followUp.url, "https://two.example/final.jpg")
        XCTAssertEqual(followUp.method, "GET")
        XCTAssertNil(followUp.body)
        XCTAssertEqual(followUp.cachePolicy, request.cachePolicy)
        XCTAssertEqual(followUp.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://reader.example/"),
        ])
        XCTAssertNil(try CompatHTTPRedirectPolicy.followUpGETRequest(
            from: request,
            response: CompatHTTPResponse(finalURL: request.url, statusCode: 404),
            redirectCount: 1,
            policy: .init()
        ))
        XCTAssertThrowsError(try CompatHTTPRedirectPolicy.followUpGETRequest(
            from: request,
            response: response,
            redirectCount: 3,
            policy: .init(maximumRedirects: 2)
        )) {
            XCTAssertEqual($0 as? CompatHTTPTransportError, .tooManyRedirects(limit: 2))
        }

        let downgrade = CompatHTTPResponse(
            finalURL: request.url,
            statusCode: 302,
            headers: [CompatHTTPHeader(name: "Location", value: "http://one.example/final.jpg")]
        )
        XCTAssertThrowsError(try CompatHTTPRedirectPolicy.followUpGETRequest(
            from: request,
            response: downgrade,
            redirectCount: 1,
            policy: .init()
        )) { XCTAssertEqual($0 as? CompatHTTPTransportError, .insecureRedirect) }
    }

    func testSourceImageHeadersBindSecretsToSourceOriginButKeepCDNHeaders() throws {
        let headers = [
            "Authorization": "Bearer secret",
            "Proxy-Authorization": "proxy secret",
            "Cookie": "session=secret",
            "Cookie2": "legacy=secret",
            "Host": "source.example",
            "Referer": "https://source.example/reader",
            "Origin": "https://source.example",
            "X-Reader": "keep",
        ]

        let sameOrigin = try XCTUnwrap(CompatHTTPHeaderPolicy.sourceImageHeaders(
            headers,
            sourceBaseURL: "https://source.example/reader",
            imageURL: "https://source.example/images/page.jpg"
        ))
        XCTAssertEqual(sameOrigin, headers)

        let crossOrigin = try XCTUnwrap(CompatHTTPHeaderPolicy.sourceImageHeaders(
            headers,
            sourceBaseURL: "https://source.example/reader",
            imageURL: "https://cdn.example/images/page.jpg"
        ))
        XCTAssertEqual(crossOrigin, [
            "Referer": "https://source.example/reader",
            "Origin": "https://source.example",
            "X-Reader": "keep",
        ])
    }

    func testResponseBufferEnforcesHeaderDeclaredAndStreamedBodyLimits() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/final"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "4", "X-Test": "ok"]
        ))
        var buffer = CompatHTTPResponseBuffer(policy: .init(maximumResponseBodyBytes: 4))
        try buffer.receive(response)
        try buffer.append(Data([1, 2]))
        try buffer.append(Data([3, 4]))
        XCTAssertEqual(try buffer.finish(), CompatHTTPResponse(
            finalURL: url.absoluteString,
            statusCode: 200,
            headers: buffer.headers,
            body: [1, 2, 3, 4]
        ))

        var declaredTooLarge = CompatHTTPResponseBuffer(
            policy: .init(maximumResponseBodyBytes: 3)
        )
        XCTAssertThrowsError(try declaredTooLarge.receive(response)) {
            XCTAssertEqual(
                $0 as? CompatHTTPTransportError,
                .responseBodyTooLarge(limit: 3)
            )
        }

        let unknownLength = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        var streamedTooLarge = CompatHTTPResponseBuffer(
            policy: .init(maximumResponseBodyBytes: 4)
        )
        try streamedTooLarge.receive(unknownLength)
        try streamedTooLarge.append(Data([1, 2, 3]))
        XCTAssertThrowsError(try streamedTooLarge.append(Data([4, 5]))) {
            XCTAssertEqual(
                $0 as? CompatHTTPTransportError,
                .responseBodyTooLarge(limit: 4)
            )
        }

        var headersTooLarge = CompatHTTPResponseBuffer(
            policy: .init(maximumResponseHeaderBytes: 16)
        )
        XCTAssertThrowsError(try headersTooLarge.receive(response)) {
            XCTAssertEqual(
                $0 as? CompatHTTPTransportError,
                .responseHeadersTooLarge(limit: 16)
            )
        }
    }

    func testCookieJarKeepsHostPathAndSecureScope() throws {
        var jar = CompatHTTPCookieJar()
        jar.store(from: CompatHTTPResponse(
            finalURL: "https://example.test/foo/login",
            statusCode: 200,
            headers: [
                CompatHTTPHeader(
                    name: "Set-Cookie",
                    value: "session=host; Path=/foo; Secure; HttpOnly"
                ),
                CompatHTTPHeader(
                    name: "Set-Cookie",
                    value: "shared=domain; Domain=example.test; Path=/"
                ),
            ]
        ))

        var sameHost = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/foo/page"))
        )
        jar.apply(to: &sameHost)
        let sameHostCookie = try XCTUnwrap(sameHost.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(sameHostCookie.contains("session=host"))
        XCTAssertTrue(sameHostCookie.contains("shared=domain"))

        var subdomain = URLRequest(
            url: try XCTUnwrap(URL(string: "https://sub.example.test/foo/page"))
        )
        jar.apply(to: &subdomain)
        let subdomainCookie = try XCTUnwrap(subdomain.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(subdomainCookie.contains("session=host"))
        XCTAssertTrue(subdomainCookie.contains("shared=domain"))

        var wrongPath = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/foobar"))
        )
        jar.apply(to: &wrongPath)
        let wrongPathCookie = try XCTUnwrap(wrongPath.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(wrongPathCookie.contains("session=host"))

        var insecure = URLRequest(
            url: try XCTUnwrap(URL(string: "http://example.test/foo/page"))
        )
        jar.apply(to: &insecure)
        let insecureCookie = try XCTUnwrap(insecure.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(insecureCookie.contains("session=host"))

        jar.clear()
        var cleared = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/foo/page"))
        )
        jar.apply(to: &cleared)
        XCTAssertNil(cleared.value(forHTTPHeaderField: "Cookie"))
    }

    func testURLSessionAdapterStreamsResponseAndKeepsCookiesPerSource() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/foo/page"))
        let firstResponse = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "session=one; Path=/foo; Secure"]
        ))
        let ordinaryResponse = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        StubURLProtocol.configure([
            .init(response: firstResponse, chunks: [Data([1, 2]), Data([3, 4])]),
            .init(response: ordinaryResponse, chunks: [Data([5])]),
            .init(response: ordinaryResponse, chunks: [Data([6])]),
        ])
        let firstSource = URLSessionCompatHTTPTransport(
            sourceID: "source-a",
            protocolClasses: [StubURLProtocol.self]
        )
        let secondSource = URLSessionCompatHTTPTransport(
            sourceID: "source-b",
            protocolClasses: [StubURLProtocol.self]
        )

        let request = CompatHTTPRequest(url: url.absoluteString)
        let firstBody = try await firstSource.execute(request).body
        let secondBody = try await firstSource.execute(request).body
        let isolatedBody = try await secondSource.execute(request).body
        XCTAssertEqual(firstBody, [1, 2, 3, 4])
        XCTAssertEqual(secondBody, [5])
        XCTAssertEqual(isolatedBody, [6])

        let captured = StubURLProtocol.requests()
        XCTAssertEqual(captured.count, 3)
        XCTAssertNil(captured[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(captured[1].value(forHTTPHeaderField: "Cookie")?.contains("session=one") == true)
        XCTAssertNil(captured[2].value(forHTTPHeaderField: "Cookie"))
    }

    func testURLSessionAdapterCancelsWhenStreamExceedsLimit() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/large"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        StubURLProtocol.configure([
            .init(response: response, chunks: [Data([1, 2, 3]), Data([4, 5])]),
        ])
        let transport = URLSessionCompatHTTPTransport(
            sourceID: "source-a",
            policy: .init(maximumResponseBodyBytes: 4),
            protocolClasses: [StubURLProtocol.self]
        )

        do {
            _ = try await transport.execute(CompatHTTPRequest(url: url.absoluteString))
            XCTFail("expected streamed body limit")
        } catch {
            XCTAssertEqual(
                error as? CompatHTTPTransportError,
                .responseBodyTooLarge(limit: 4)
            )
        }
    }

    func testURLSessionSingleExchangeExposesRedirectAndStoresItsCookie() async throws {
        let startURL = try XCTUnwrap(URL(string: "https://example.test/start"))
        let nextURL = try XCTUnwrap(URL(string: "https://example.test/next"))
        let redirect = try XCTUnwrap(HTTPURLResponse(
            url: startURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Location": nextURL.absoluteString,
                "Set-Cookie": "redirect=seen; Path=/; Secure",
            ]
        ))
        let final = try XCTUnwrap(HTTPURLResponse(
            url: nextURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        StubURLProtocol.configure([
            .init(response: redirect, chunks: [Data([1])]),
            .init(response: final, chunks: [Data([2])]),
        ])
        let transport = URLSessionCompatHTTPTransport(
            sourceID: "single-exchange-source",
            protocolClasses: [StubURLProtocol.self]
        )

        let first = try await transport.executeSingleExchange(
            CompatHTTPRequest(url: startURL.absoluteString)
        )
        let second = try await transport.executeSingleExchange(
            CompatHTTPRequest(url: nextURL.absoluteString)
        )

        XCTAssertEqual(first.statusCode, 302)
        XCTAssertEqual(first.finalURL, startURL.absoluteString)
        XCTAssertEqual(first.body, [1])
        XCTAssertEqual(second.statusCode, 200)
        XCTAssertEqual(second.body, [2])
        let requests = StubURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(
            requests[1].value(forHTTPHeaderField: "Cookie")?.contains("redirect=seen") == true
        )
    }
}
