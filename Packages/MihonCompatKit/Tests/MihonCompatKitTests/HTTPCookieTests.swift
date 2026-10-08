import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MihonCompatKit

final class HTTPCookieTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private func url(_ value: String = "https://sub.example.com/foo/login") throws -> URL { try XCTUnwrap(URL(string: value)) }

    func testParseAttributesDefaultPathAndMaxAgePrecedence() throws {
        let input = try url()
        let host = try XCTUnwrap(CompatHTTPCookie.parse(" session=one ; Secure; HttpOnly", url: input, now: now))
        XCTAssertEqual(host.name, "session")
        XCTAssertEqual(host.value, "one")
        XCTAssertEqual(host.path, "/foo")
        XCTAssertEqual(host.domain, "sub.example.com")
        XCTAssertTrue(host.hostOnly)
        XCTAssertTrue(host.secure)
        XCTAssertTrue(host.httpOnly)
        XCTAssertFalse(host.persistent)
        let domain = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Domain=.EXAMPLE.com; Max-Age=60; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Path=/", url: input, now: now))
        XCTAssertEqual(domain.domain, "example.com")
        XCTAssertFalse(domain.hostOnly)
        XCTAssertEqual(domain.expiresAt, now + 60_000)
        XCTAssertTrue(domain.persistent)
        for value in ["0", "-1", "-9999999999999999999999999999"] {
            XCTAssertEqual(CompatHTTPCookie.parse("a=; Max-Age=\(value)", url: input, now: now)?.expiresAt, Int64.min)
        }
        XCTAssertEqual(CompatHTTPCookie.parse("a=b; Max-Age=99999999999999999999999999", url: input, now: now)?.expiresAt, CompatHTTPCookie.maximumExpiry)
        XCTAssertFalse(try XCTUnwrap(CompatHTTPCookie.parse("a=b; Max-Age=+1; Expires=bad", url: input, now: now)).persistent)
    }

    func testExpiryDatesObsoleteSeparatorsAndInvalidCalendarValues() throws {
        let input = try url()
        let expected: Int64 = 1_623_233_894_000
        for expiry in ["Wed, 09 Jun 2021 10:18:14 GMT", "Wed, 09-Jun-21 10:18:14 GMT", "Wed Jun  9 10:18:14 2021"] {
            let cookie = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Expires=\(expiry)", url: input, now: now))
            XCTAssertEqual(cookie.expiresAt, expected, expiry)
            XCTAssertTrue(cookie.persistent)
        }
        for expiry in ["31 Feb 2025 00:00:00 GMT", "09 Jun 1599 00:00:00 GMT", "09 Jun 2021 25:00:00 GMT", "09 Jun 2021 00:00:60 GMT", "09 Jun 2021abc2 00:00:00 GMT"] {
            XCTAssertFalse(try XCTUnwrap(CompatHTTPCookie.parse("a=b; Expires=\(expiry)", url: input, now: now)).persistent, expiry)
        }
    }

    func testParserRejectsUnrelatedDomainsAndUnsafeOrOversizedInput() throws {
        for header in ["bad", "=empty", "name=bad\r\nvalue", "é=x", "x=é", "a=b; Domain=evil.example", "a=b; Domain=com", "a=" + String(repeating: "x", count: 8_192)] {
            XCTAssertNil(CompatHTTPCookie.parse(header, url: try url(), now: now), header.prefix(40).description)
        }
        let ignored = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Domain=example.com.; Domain=bad/host; Path=no-slash", url: url(), now: now))
        XCTAssertTrue(ignored.hostOnly)
        XCTAssertEqual(ignored.domain, "sub.example.com")
        XCTAssertEqual(ignored.path, "/foo")
        XCTAssertNotNil(CompatHTTPCookie.parse("a=b;;;;", url: try url(), now: now))
    }

    func testDomainPathAndSecureBoundariesUseEncodedPath() throws {
        let cookie = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Domain=example.com; Path=/foo%2Fbar; Secure", url: url(), now: now))
        XCTAssertTrue(cookie.matches(try url("https://other.example.com/foo%2Fbar/page")))
        for target in ["https://badexample.com/foo%2Fbar", "https://example.com.evil/foo%2Fbar", "https://example.com/foo%2Fbarista", "https://example.com/foo/bar", "http://example.com/foo%2Fbar"] {
            XCTAssertFalse(cookie.matches(try url(target)), target)
        }
        let hostOnly = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Path=/", url: url(), now: now))
        XCTAssertFalse(hostOnly.matches(try url("https://child.sub.example.com/")))
        XCTAssertTrue(hostOnly.matches(try url("http://sub.example.com/")))
    }

    func testPinnedPublicSuffixRulesPrivateDomainsWildcardExceptionsAndIDN() throws {
        let list = CompatPublicSuffixList.shared
        for domain in ["com", "co.uk", "github.io", "blogspot.com", "ck", "a.ck", "foo.kawasaki.jp", "公司.cn"] {
            XCTAssertFalse(list.permitsDomainCookie(domain), domain)
        }
        for domain in ["example.com", "reader.co.uk", "reader.github.io", "www.ck", "child.www.ck", "city.kawasaki.jp", "kawasaki.jp", "食狮.公司.cn"] {
            XCTAssertTrue(list.permitsDomainCookie(domain), domain)
        }
        for domain in ["bad..com", "evil/com", "user@evil.com", "example.com:443", "example.com."] {
            XCTAssertNil(CompatHTTPCookie.canonicalHost(domain), domain)
        }
        XCTAssertEqual(CompatHTTPCookie.canonicalHost("食狮.公司.cn"), "xn--85x722f.xn--55qx5d.cn")
        XCTAssertFalse(CompatPublicSuffixList(text: nil).permitsDomainCookie("example.com"))
        XCTAssertFalse(CompatPublicSuffixList(text: "com\ninvalid/rule").permitsDomainCookie("example.com"))
        XCTAssertNil(CompatHTTPCookie.parse("a=b; Domain=github.io", url: try url("https://one.github.io/")))
        XCTAssertNil(CompatHTTPCookie.parse("a=b; Domain=co.uk", url: try url("https://reader.co.uk/")))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/MihonCompatKit/Resources/public_suffix_list.dat"))
        XCTAssertEqual(APKSignatureVerifier.apkSHA256([UInt8](data)), "ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612")
    }

    func testIPCookiesMatchOnlyTheExactIP() throws {
        let address = try url("https://127.0.0.1/foo")
        let cookie = try XCTUnwrap(CompatHTTPCookie.parse("a=b; Domain=127.0.0.1; Path=/", url: address, now: now))
        XCTAssertTrue(cookie.matches(address))
        XCTAssertFalse(cookie.matches(try url("https://2.127.0.0.1/")))
        XCTAssertNil(CompatHTTPCookie.parse("a=b; Domain=0.0.1", url: address, now: now))
        let ipv6 = try url("https://[::1]/")
        let hostOnly = try XCTUnwrap(CompatHTTPCookie.parse("a=b", url: ipv6, now: now))
        XCTAssertTrue(hostOnly.matches(ipv6))
        XCTAssertFalse(hostOnly.matches(try url("https://[::2]/")))
    }

    func testStoreReplacementExpiryDeletionAndPathOrdering() throws {
        let jar = CompatHTTPCookieJar(), origin = try url()
        func save(_ header: String) throws { jar.save([try XCTUnwrap(CompatHTTPCookie.parse(header, url: origin, now: now))], for: origin, now: now) }
        try save("first=one; Path=/")
        try save("second=two; Path=/; Max-Age=1")
        try save("deep=value; Path=/foo")
        try save("first=replaced; Path=/")
        XCTAssertEqual(jar.load(for: origin, now: now).map(\.name), ["deep", "first", "second"])
        XCTAssertEqual(jar.load(for: origin, now: now)[1].value, "replaced")
        XCTAssertEqual(jar.load(for: origin, now: now + 1_000).map(\.name), ["deep", "first"])
        try save("first=gone; Path=/; Max-Age=0")
        XCTAssertEqual(jar.load(for: origin, now: now).map(\.name), ["deep"])
        jar.clear()
        XCTAssertTrue(jar.load(for: origin, now: now).isEmpty)
    }

    func testStoreRejectsForgedCookiesAndEvictsOldestAtCapacity() throws {
        let jar = CompatHTTPCookieJar(), origin = try url()
        let rejected = [
            CompatHTTPCookie(name: "a", value: "b", domain: "com"),
            CompatHTTPCookie(name: "a", value: "b", domain: "evil.com"),
            CompatHTTPCookie(name: "a", value: "b", domain: "example.com", hostOnly: true),
            CompatHTTPCookie(name: "bad=name", value: "b", domain: "example.com"),
            CompatHTTPCookie(name: "a", value: "b; injected=c", domain: "example.com"),
            CompatHTTPCookie(name: "a", value: "bad\r\n", domain: "example.com"),
        ]
        jar.save(rejected, for: origin, now: now)
        XCTAssertTrue(jar.load(for: origin, now: now).isEmpty)
        for index in 0...256 {
            jar.save([.init(name: "n\(index)", value: "v", domain: "example.com")], for: origin, now: now)
        }
        XCTAssertEqual(jar.load(for: origin, now: now).count, 256)
        XCTAssertEqual(jar.load(for: origin, now: now).first?.name, "n1")
        XCTAssertEqual(jar.load(for: origin, now: now).last?.name, "n256")
    }

    func testExplicitCookieHeaderWinsAndCookiesCountAgainstHeaderBudget() throws {
        let jar = CompatHTTPCookieJar(), origin = try url()
        jar.save([.init(name: "a", value: String(repeating: "b", count: 50), domain: "example.com")], for: origin)
        let explicit = CompatHTTPRequest(url: origin.absoluteString, headers: [.init(name: "cOoKiE", value: "explicit=one")])
        XCTAssertEqual(jar.applying(to: explicit), explicit)
        let applied = jar.applying(to: .init(url: origin.absoluteString))
        XCTAssertEqual(applied.headers.count, 1)
        XCTAssertThrowsError(try CompatHTTPTransportPolicy(maximumRequestHeaderBytes: 30).validate(request: applied)) {
            XCTAssertEqual($0 as? CompatHTTPTransportError, .requestHeadersTooLarge(limit: 30))
        }
        XCTAssertTrue(CompatHTTPCookieJar().applying(to: .init(url: origin.absoluteString)).headers.isEmpty)
    }

    func testRedirectSavesCookieRefreshesAutoHeaderAndRemovesWrongPath() throws {
        let jar = CompatHTTPCookieJar(), origin = try url()
        jar.save([.init(name: "session", value: "old", domain: "sub.example.com", path: "/foo", hostOnly: true)], for: origin)
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "session=new; Path=/foo; Secure"]))
        var next = URLRequest(url: try url("https://sub.example.com/foo/next"))
        next.setValue("session=old", forHTTPHeaderField: "Cookie")
        let prepared = try CompatHTTPRedirectPolicy.cookieManagedRequest(response: response, proposed: next,
            redirectCount: 1, policy: .init(), jar: jar, automaticCookieHeader: "session=old")
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Cookie"), "session=new")
        XCTAssertEqual(prepared.automaticCookieHeader, "session=new")
        var wrongPath = prepared.request
        wrongPath.url = try url("https://sub.example.com/elsewhere")
        let pruned = try CompatHTTPRedirectPolicy.cookieManagedRequest(response: response, proposed: wrongPath,
            redirectCount: 2, policy: .init(), jar: jar, automaticCookieHeader: prepared.automaticCookieHeader)
        XCTAssertNil(pruned.request.value(forHTTPHeaderField: "Cookie"))
    }

    func testRedirectPreservesExplicitSameOriginHeaderAndStripsCrossOriginSecrets() throws {
        let jar = CompatHTTPCookieJar(), origin = try url()
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:]))
        var next = URLRequest(url: origin)
        next.setValue("manual=secret", forHTTPHeaderField: "Cookie")
        next.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let same = try CompatHTTPRedirectPolicy.cookieManagedRequest(response: response, proposed: next,
            redirectCount: 1, policy: .init(), jar: jar, automaticCookieHeader: nil)
        XCTAssertEqual(same.request.value(forHTTPHeaderField: "Cookie"), "manual=secret")
        XCTAssertNil(same.automaticCookieHeader)
        let other = try url("https://other.example.net/")
        jar.save([.init(name: "destination", value: "own", domain: "other.example.net", hostOnly: true)], for: other)
        next.url = other
        let cross = try CompatHTTPRedirectPolicy.cookieManagedRequest(response: response, proposed: next,
            redirectCount: 1, policy: .init(), jar: jar, automaticCookieHeader: nil)
        XCTAssertEqual(cross.request.value(forHTTPHeaderField: "Cookie"), "destination=own")
        XCTAssertNil(cross.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try CompatHTTPRedirectPolicy.cookieManagedRequest(response: response, proposed: next,
            redirectCount: 1, policy: .init(maximumRequestHeaderBytes: 10), jar: jar, automaticCookieHeader: nil))
    }
}
