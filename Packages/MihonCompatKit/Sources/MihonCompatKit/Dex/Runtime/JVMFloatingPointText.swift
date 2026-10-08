import Foundation

/// JVM notation around Swift's shortest round-trip decimal digits. This keeps
/// locale out of source URLs, preserves signed zero, and uses the Java plain /
/// scientific thresholds. It does not emulate every legacy Android dtoa tie.
enum JVMFloatingPointText {
    // The nonlocalized printf initializer retains subnormal precision. Passing
    // a Locale routes through Foundation decimal formatting on some hosts.
    static func string(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value.sign == .minus ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        return render(String(value.magnitude), negative: value.sign == .minus) {
            String(format: "%.1e", Double(value.magnitude))
        }
    }

    static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value.sign == .minus ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        return render(String(value.magnitude), negative: value.sign == .minus) {
            String(format: "%.1e", value.magnitude)
        }
    }

    private static func parts(_ decimal: String) -> (digits: String, exponent: Int) {
        let pieces = decimal.lowercased().split(separator: "e")
        let mantissa = pieces[0]
        let explicitExponent = pieces.count == 2 ? Int(pieces[1])! : 0
        let integerCount = mantissa.prefix { $0 != "." }.count
        var digits = mantissa.filter { $0 != "." }
        let leadingZeroes = digits.prefix { $0 == "0" }.count
        digits.removeFirst(leadingZeroes)
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }
        return (digits, explicitExponent + integerCount - leadingZeroes - 1)
    }

    private static func render(_ decimal: String, negative: Bool, twoDigits: () -> String) -> String {
        var (digits, exponent) = parts(decimal)
        let sign = negative ? "-" : ""
        if (-3..<7).contains(exponent) {
            let point = exponent + 1
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count {
                return sign + digits + String(repeating: "0", count: point - digits.count) + ".0"
            }
            return sign + digits.prefix(point) + "." + digits.dropFirst(point)
        }
        // Java requires a fractional digit even when a one-digit decimal
        // already round-trips. Use the closest two-digit decimal, e.g. 1.4E-45
        // for Float's least subnormal rather than padding Swift's 1e-45 to 1.0.
        if digits.count == 1 { (digits, exponent) = parts(twoDigits()) }
        return sign + digits.prefix(1) + "." + (digits.count > 1 ? String(digits.dropFirst()) : "0") + "E" + String(exponent)
    }
}
