import Foundation

/// The cookie value shared by the OkHttp host surface and HTTP transports.
/// Parsing follows the RFC 6265 attributes used by OkHttp; storage applies a
/// separate bounded acceptance policy. SameSite is outside this native HTTP
/// client's model (there is no browser document or script origin).
struct CompatHTTPCookie: Sendable, Equatable {
    static let maximumBytes = 8_192
    static let maximumExpiry: Int64 = 253_402_300_799_999

    var name: String
    var value: String
    var domain: String
    var path = "/"
    var expiresAt = maximumExpiry
    var secure = false
    var httpOnly = false
    var persistent = false
    var hostOnly = false

    var byteCount: Int { name.utf8.count + value.utf8.count + domain.utf8.count + path.utf8.count }
    var key: String { name + "\u{0}" + domain + "\u{0}" + path }

    func matches(_ url: URL) -> Bool {
        guard let host = url.host.flatMap(Self.canonicalHost),
              hostOnly ? host == domain : Self.domainMatches(host: host, domain: domain),
              !secure || url.scheme?.lowercased() == "https" else { return false }
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let actualPath = requestPath.isEmpty ? "/" : requestPath
        return actualPath == path || (actualPath.hasPrefix(path)
            && (path.hasSuffix("/") || actualPath.dropFirst(path.count).hasPrefix("/")))
    }

    static func canonicalHost(_ source: String) -> String? {
        guard !source.isEmpty, source.utf8.count <= 1_024,
              !source.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              !source.contains(where: { "/\\?#@%".contains($0) }) else { return nil }
        if source.contains(":") {
            let stripped = source.hasPrefix("[") && source.hasSuffix("]") ? String(source.dropFirst().dropLast()) : source
            guard stripped.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46 }),
                  let host = URL(string: "https://[\(stripped)]/")?.host else { return nil }
            return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        }
        guard !source.contains("["), !source.contains("]"),
              let host = URL(string: "https://\(source)/")?.host?.lowercased(),
              host.utf8.count <= 253,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else { return nil }
        return host
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
    }

    static func domainMatches(host: String, domain: String) -> Bool {
        host == domain || (!isIPAddress(host) && host.hasSuffix("." + domain))
    }

    static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    static func parse(_ header: String, url: URL, now: Int64 = nowMilliseconds()) -> Self? {
        guard header.utf8.count <= maximumBytes,
              let urlHost = url.host.flatMap(canonicalHost),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let attributes = header.split(separator: ";", omittingEmptySubsequences: false)
        guard let pair = attributes.first, let equals = pair.firstIndex(of: "=") else { return nil }
        let name = asciiTrim(String(pair[..<equals]))
        let value = asciiTrim(String(pair[pair.index(after: equals)...]))
        guard !name.isEmpty, printableASCII(name), printableASCII(value) else { return nil }
        var result = Self(name: name, value: value, domain: urlHost, hostOnly: true)
        var maxAge: Int64?
        var explicitPath: String?
        for attribute in attributes.dropFirst() {
            let parts = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            let key = asciiTrim(String(first)).lowercased()
            let value = parts.count == 2 ? asciiTrim(String(parts[1])) : ""
            switch key {
            case "expires":
                if let expiry = parseExpiry(value) { result.expiresAt = expiry; result.persistent = true }
            case "max-age":
                if let age = parseMaxAge(value) { maxAge = age; result.persistent = true }
            case "domain":
                // An invalid Domain attribute is ignored, as in OkHttp; a
                // syntactically valid unrelated/public domain rejects below.
                guard !value.hasSuffix(".") else { continue }
                let candidate = value.hasPrefix(".") ? String(value.dropFirst()) : value
                if let domain = canonicalHost(candidate) { result.domain = domain; result.hostOnly = false }
            case "path": explicitPath = value
            case "secure": result.secure = true
            case "httponly": result.httpOnly = true
            default: break
            }
        }
        if let maxAge {
            if maxAge <= 0 { result.expiresAt = Int64.min }
            else {
                let delta = maxAge.multipliedReportingOverflow(by: 1_000)
                let expiry = now.addingReportingOverflow(delta.partialValue)
                result.expiresAt = delta.overflow || expiry.overflow ? maximumExpiry : min(expiry.partialValue, maximumExpiry)
            }
        }
        guard domainMatches(host: urlHost, domain: result.domain) else { return nil }
        if !result.hostOnly, urlHost != result.domain,
           !CompatPublicSuffixList.shared.permitsDomainCookie(result.domain) { return nil }
        if let explicitPath, explicitPath.hasPrefix("/") { result.path = explicitPath }
        else {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
            if let slash = path.lastIndex(of: "/"), slash != path.startIndex { result.path = String(path[..<slash]) }
        }
        return result.byteCount <= maximumBytes ? result : nil
    }

    private static func asciiTrim(_ input: String) -> String {
        input.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0b}\u{0c}"))
    }

    static func printableASCII(_ input: String) -> Bool { input.utf8.allSatisfy { (32...126).contains($0) } }

    private static func parseMaxAge(_ input: String) -> Int64? {
        let digits = input.hasPrefix("-") ? input.dropFirst() : input[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        if input.hasPrefix("-") { return Int64.min }
        return Int64(input).map { $0 <= 0 ? Int64.min : $0 } ?? Int64.max
    }

    /// RFC 6265's date token algorithm accepts obsolete HTTP date separators
    /// and two-digit years without accepting Calendar's rollover of bad dates.
    private static func parseExpiry(_ input: String) -> Int64? {
        let tokens = input.utf8.split { byte in
            byte == 9 || (32...47).contains(byte) || (59...64).contains(byte)
                || (91...96).contains(byte) || (123...126).contains(byte)
        }.map { String(decoding: $0, as: UTF8.self) }
        var hour: Int?, minute: Int?, second: Int?, day: Int?, month: Int?, year: Int?
        func number(_ token: Substring, minimum: Int, maximum: Int) -> Int? {
            let digits = token.prefix { $0.isASCII && $0.isNumber }
            guard (minimum...maximum).contains(digits.count),
                  !token.dropFirst(digits.count).contains(where: { $0.isASCII && $0.isNumber }) else { return nil }
            return Int(digits)
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for token in tokens {
            let times = token.split(separator: ":", omittingEmptySubsequences: false)
            if hour == nil, times.count == 3,
               let h = number(times[0], minimum: 1, maximum: 2), String(h).count <= 2,
               times[0].allSatisfy({ $0.isASCII && $0.isNumber }),
               let m = number(times[1], minimum: 1, maximum: 2), times[1].allSatisfy({ $0.isASCII && $0.isNumber }),
               let s = number(times[2], minimum: 1, maximum: 2) { hour = h; minute = m; second = s; continue }
            if day == nil, let d = number(token[...], minimum: 1, maximum: 2) { day = d; continue }
            if month == nil, let m = months.firstIndex(of: String(token.prefix(3)).lowercased()) { month = m + 1; continue }
            if year == nil, let y = number(token[...], minimum: 2, maximum: 4) { year = y }
        }
        guard var year, let month, let day, let hour, let minute, let second,
              (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        if (70...99).contains(year) { year += 1900 }
        else if (0...69).contains(year) { year += 2000 }
        guard year >= 1601 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}

/// Vendored ICANN + PRIVATE rules, including wildcard exceptions. No network
/// lookup occurs while parsing a cookie. Missing or malformed data fails closed
/// for domain cookies; host-only cookies remain usable.
struct CompatPublicSuffixList: Sendable {
    static let shared: Self = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return .init(text: nil) }
        return .init(text: text)
    }()

    private let rules: Set<String>
    private let exceptions: Set<String>
    private let wildcards: Set<String>
    private let valid: Bool

    init(text: String?) {
        var rules = Set<String>(), exceptions = Set<String>(), wildcards = Set<String>()
        var valid = text != nil
        for raw in (text ?? "").split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            let exception = line.hasPrefix("!"), wildcard = line.hasPrefix("*.")
            let body = exception ? String(line.dropFirst()) : (wildcard ? String(line.dropFirst(2)) : line)
            guard let domain = CompatHTTPCookie.canonicalHost(body) else { valid = false; continue }
            if exception { exceptions.insert(domain) }
            else if wildcard { wildcards.insert(domain) }
            else { rules.insert(domain) }
        }
        self.rules = rules
        self.exceptions = exceptions
        self.wildcards = wildcards
        self.valid = valid && !rules.isEmpty && rules.count + exceptions.count + wildcards.count <= 30_000
    }

    func permitsDomainCookie(_ domain: String) -> Bool {
        guard valid, let canonical = CompatHTTPCookie.canonicalHost(domain),
              !CompatHTTPCookie.isIPAddress(canonical) else { return false }
        let labels = canonical.split(separator: ".")
        var suffixLength = 1 // prevailing default rule '*'
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            let length = labels.count - index
            if exceptions.contains(suffix) { return labels.count > length - 1 }
            if rules.contains(suffix) { suffixLength = max(suffixLength, length) }
            if index > 0, wildcards.contains(suffix) { suffixLength = max(suffixLength, length + 1) }
        }
        return labels.count > suffixLength
    }
}
