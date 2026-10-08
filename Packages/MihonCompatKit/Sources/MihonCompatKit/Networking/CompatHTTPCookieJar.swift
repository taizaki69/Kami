import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Internal capability: a source's DEX client and URLSession must read/write
/// the same jar. Injected transports without this capability use the bridge's
/// own jar at the HTTP boundary. No global cookie storage participates.
protocol CompatHTTPCookieStoreProviding: CompatHTTPTransport {
    var cookieJar: CompatHTTPCookieJar { get }
}

/// The lock protects immutable cookie values and insertion order only. No
/// interpreter, user callback or network call runs while it is held.
final class CompatHTTPCookieJar: @unchecked Sendable {
    private struct Entry {
        let value: CompatHTTPCookie
        let sequence: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextSequence: UInt64 = 0
    static let maximumCookies = 256

    func load(for url: URL, now: Int64 = CompatHTTPCookie.nowMilliseconds()) -> [CompatHTTPCookie] {
        lock.lock()
        defer { lock.unlock() }
        removeExpired(now: now)
        return entries.values.filter { $0.value.matches(url) }.sorted {
            let left = $0.value.path.utf8.count, right = $1.value.path.utf8.count
            return left != right ? left > right : $0.sequence < $1.sequence
        }.map(\.value)
    }

    func save(_ cookies: [CompatHTTPCookie], for url: URL, now: Int64 = CompatHTTPCookie.nowMilliseconds()) {
        guard cookies.count <= Self.maximumCookies,
              let host = url.host.flatMap(CompatHTTPCookie.canonicalHost),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        // Reject values that could escape their origin or alter a Cookie
        // header. Builder-created values receive the same acceptance checks.
        let accepted = cookies.filter { cookie in
            cookie.byteCount <= CompatHTTPCookie.maximumBytes
                && !cookie.name.isEmpty && CompatHTTPCookie.printableASCII(cookie.name)
                && !cookie.name.contains(where: { "()<>@,;:\\\"/[]?={} \t".contains($0) })
                && CompatHTTPCookie.printableASCII(cookie.value) && !cookie.value.contains(";")
                && cookie.path.hasPrefix("/") && CompatHTTPCookie.printableASCII(cookie.path)
                && CompatHTTPCookie.canonicalHost(cookie.domain) == cookie.domain
                && (cookie.hostOnly ? host == cookie.domain : CompatHTTPCookie.domainMatches(host: host, domain: cookie.domain))
                && (cookie.hostOnly || CompatHTTPCookie.isIPAddress(cookie.domain)
                    || CompatPublicSuffixList.shared.permitsDomainCookie(cookie.domain))
        }
        lock.lock()
        defer { lock.unlock() }
        removeExpired(now: now)
        for cookie in accepted {
            if cookie.expiresAt <= now { entries.removeValue(forKey: cookie.key); continue }
            let sequence: UInt64
            if let existing = entries[cookie.key] { sequence = existing.sequence }
            else {
                if nextSequence == UInt64.max {
                    let ordered = entries.values.sorted { $0.sequence < $1.sequence }
                    entries = Dictionary(uniqueKeysWithValues: ordered.enumerated().map {
                        ($0.element.value.key, Entry(value: $0.element.value, sequence: UInt64($0.offset)))
                    })
                    nextSequence = UInt64(entries.count)
                }
                sequence = nextSequence
                nextSequence += 1
            }
            entries[cookie.key] = Entry(value: cookie, sequence: sequence)
            if entries.count > Self.maximumCookies,
               let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
    }

    func store(from response: CompatHTTPResponse) {
        guard let url = URL(string: response.finalURL) else { return }
        // HTTP boundary validation precedes this; retain a local finite bound
        // as well for direct host use and injected transports.
        for header in response.headers.prefix(4_096)
            where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            if let cookie = CompatHTTPCookie.parse(header.value, url: url) { save([cookie], for: url) }
        }
    }

    func applying(to request: CompatHTTPRequest) -> CompatHTTPRequest {
        guard !request.headers.contains(where: { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }),
              let url = URL(string: request.url) else { return request }
        let cookies = load(for: url)
        guard !cookies.isEmpty else { return request }
        var result = request
        result.headers.append(.init(name: "Cookie", value: cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")))
        return result
    }

    func apply(to request: inout URLRequest) {
        guard request.value(forHTTPHeaderField: "Cookie") == nil, let url = request.url else { return }
        let cookies = load(for: url)
        guard !cookies.isEmpty else { return }
        request.setValue(cookies.map { $0.name + "=" + $0.value }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        nextSequence = 0
    }

    private func removeExpired(now: Int64) { entries = entries.filter { $0.value.value.expiresAt > now } }
}
