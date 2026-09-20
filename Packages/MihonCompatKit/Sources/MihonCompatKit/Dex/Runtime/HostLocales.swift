import Foundation

private struct LanguageTagLocale {
    let identifier: String

    /// Bounded BCP-47 core tags. Java ignores the first malformed subtag and
    /// everything after it. Valid extensions/private-use/legacy tags are
    /// explicitly unsupported instead of silently losing their semantics.
    init(_ tag: String) throws {
        guard tag.utf8.count <= 255 else { throw VMError.verify("locale tag exceeds 255 bytes") }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let legacy = [
            "art-lojban", "cel-gaulish", "en-gb-oed", "i-ami", "i-bnn", "i-default",
            "i-enochian", "i-hak", "i-klingon", "i-lux", "i-mingo", "i-navajo",
            "i-pwn", "i-tao", "i-tay", "i-tsu", "no-bok", "no-nyn", "sgn-be-fr",
            "sgn-be-nl", "sgn-ch-de", "zh-guoyu", "zh-hakka", "zh-min", "zh-min-nan", "zh-xiang",
        ]
        guard !legacy.contains(tag.lowercased()) else { throw VMError.verify("legacy locale tag unsupported") }
        if parts.first?.lowercased() == "x", parts.count > 1, Self.alphanumeric(parts[1], 1...8) {
            throw VMError.verify("private-use locale tag unsupported")
        }
        guard let first = parts.first, Self.alpha(first, 2...8) else {
            identifier = ""
            return
        }
        var language = first.lowercased()
        var index = 1
        if first.utf8.count <= 3 {
            for extlang in 0..<3 {
                guard index < parts.count, Self.alpha(parts[index], 3...3) else { break }
                if extlang == 0 { language = parts[index].lowercased() }
                index += 1
            }
        }
        language = ["iw": "he", "ji": "yi", "in": "id"][language] ?? language
        var canonical = [language == "und" ? "und" : language]
        if index < parts.count, Self.alpha(parts[index], 4...4) {
            let script = parts[index].lowercased()
            canonical.append(script.prefix(1).uppercased() + script.dropFirst())
            index += 1
        }
        if index < parts.count,
           Self.alpha(parts[index], 2...2) || Self.digits(parts[index], 3...3) {
            canonical.append(parts[index].uppercased())
            index += 1
        }
        while index < parts.count {
            let variant = parts[index]
            if Self.alphanumeric(variant, 5...8)
                || (Self.alphanumeric(variant, 4...4) && variant.utf8.first.map { (48...57).contains($0) } == true) {
                canonical.append(variant)
                index += 1
            } else { break }
        }
        if index + 1 < parts.count, Self.alphanumeric(parts[index], 1...1) {
            let minimum = parts[index].lowercased() == "x" ? 1 : 2
            if Self.alphanumeric(parts[index + 1], minimum...8) {
                throw VMError.verify("locale extensions unsupported")
            }
        }
        identifier = canonical == ["und"] ? "" : canonical.joined(separator: "-")
    }

    private static func alpha(_ value: String, _ count: ClosedRange<Int>) -> Bool {
        count.contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    private static func digits(_ value: String, _ count: ClosedRange<Int>) -> Bool {
        count.contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func alphanumeric(_ value: String, _ count: ClosedRange<Int>) -> Bool {
        count.contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}

private struct HostCollator {
    let locale: Locale
}

private func localeArgument(_ args: [RVal], _ index: Int) throws -> RVal {
    guard args.indices.contains(index) else { throw VMError.verify("locale argument missing") }
    guard !args[index].isNull else {
        throw DEXThrowable(.obj(ObjInstance(dexType: "Ljava/lang/NullPointerException;", isHost: true)))
    }
    return args[index]
}

private func localeString(_ args: [RVal], _ index: Int) throws -> String {
    guard case let .obj(object) = try localeArgument(args, index),
          object.dexType == "Ljava/lang/String;", let value = object.payload as? String else {
        throw DEXThrowable(.obj(ObjInstance(dexType: "Ljava/lang/ClassCastException;", isHost: true)))
    }
    return value
}

extension HostBridge {
    static func foundationLocale(from value: RVal, operation: String) throws -> Locale {
        guard !value.isNull else {
            throw DEXThrowable(.obj(ObjInstance(dexType: "Ljava/lang/NullPointerException;", isHost: true)))
        }
        guard case let .obj(object) = value, object.dexType == "Ljava/util/Locale;" else {
            throw VMError.verify("\(operation) locale argument")
        }
        if let locale = object.payload as? LanguageTagLocale { return Locale(identifier: locale.identifier) }
        if let name = object.payload as? String,
           let identifier = ["ROOT": "", "ENGLISH": "en", "FRENCH": "fr", "US": "en-US"][name] {
            return Locale(identifier: identifier)
        }
        throw VMError.verify("\(operation) unsupported locale")
    }

    static func registerLocaleSurface(_ bridge: HostBridge, maximumStringBytes: Int) {
        bridge.register(class: "Ljava/util/Locale;", "forLanguageTag",
                        prototype: "(Ljava/lang/String;)Ljava/util/Locale;", isStatic: true) { _, args in
            .obj(ObjInstance(dexType: "Ljava/util/Locale;",
                             payload: try LanguageTagLocale(localeString(args, 0)), isHost: true))
        }
        let collatorType = "Ljava/text/Collator;"
        bridge.register(class: collatorType, "getInstance",
                        prototype: "(Ljava/util/Locale;)Ljava/text/Collator;", isStatic: true) { _, args in
            let locale = try foundationLocale(from: localeArgument(args, 0), operation: "Collator.getInstance")
            return .obj(ObjInstance(dexType: collatorType, payload: HostCollator(locale: locale), isHost: true))
        }
        for prototype in ["(Ljava/lang/String;Ljava/lang/String;)I", "(Ljava/lang/Object;Ljava/lang/Object;)I"] {
            bridge.register(class: collatorType, "compare", prototype: prototype) { _, args in
                guard case let .obj(receiver) = try localeArgument(args, 0),
                      let collator = receiver.payload as? HostCollator else {
                    throw VMError.verify("Collator.compare receiver")
                }
                let lhs = try localeString(args, 1)
                let rhs = try localeString(args, 2)
                guard lhs.utf8.count <= maximumStringBytes,
                      rhs.utf8.count <= maximumStringBytes else {
                    throw VMError.verify("Collator.compare string limit")
                }
                // Foundation supplies native ICU collation. Exact ordering for
                // all Unicode/locale versions is not claimed as Android parity.
                switch lhs.compare(rhs, options: [], locale: collator.locale) {
                case .orderedAscending: return .int(-1)
                case .orderedSame: return .int(0)
                case .orderedDescending: return .int(1)
                }
            }
        }
    }
}
