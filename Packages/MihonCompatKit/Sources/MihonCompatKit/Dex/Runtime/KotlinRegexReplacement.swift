import Foundation

/// Kotlin/JVM replacement expressions are not Foundation replacement templates.
/// In particular, numeric references greedily consume only a valid group index,
/// and named references use `${name}`. Matching remains the existing ICU subset.
enum KotlinRegexReplacement {
    enum Failure: Error { case malformedReplacement, missingGroup, outputLimit }
    private enum Part { case literal(String), indexed(Int), named(String) }

    static func replace(
        expression: NSRegularExpression, input: String, replacement: String,
        maximumBytes: Int, maximumMatches: Int = 10_000,
        cancelled: @escaping () -> Bool
    ) throws -> String {
        guard input.utf8.count <= maximumBytes, replacement.utf8.count <= maximumBytes,
              expression.numberOfCaptureGroups < 128 else { throw Failure.outputLimit }
        var output = "", outputBytes = 0, end = 0, matches = 0, progress = 0
        var parts: [Part]?
        var failure: Error?
        let text = input as NSString
        let started = DispatchTime.now().uptimeNanoseconds
        func append(_ value: String) throws {
            let size = outputBytes.addingReportingOverflow(value.utf8.count)
            guard !size.overflow, size.partialValue <= maximumBytes else { throw Failure.outputLimit }
            output += value
            outputBytes = size.partialValue
        }
        func appendRange(_ range: NSRange) throws {
            if range.location == NSNotFound { return } // A valid, unmatched group expands to empty.
            guard range.location <= text.length, range.length <= text.length - range.location else {
                throw VMError.verify("Regex.replace invalid capture range")
            }
            try append(text.substring(with: range))
        }
        if cancelled() { throw VMError.cancelled }
        expression.enumerateMatches(in: input, options: [.reportProgress],
                                    range: NSRange(location: 0, length: text.length)) { match, _, stop in
            do {
                if cancelled() { throw VMError.cancelled }
                progress += 1
                guard progress <= 100_000,
                      DispatchTime.now().uptimeNanoseconds - started <= 1_000_000_000 else {
                    throw VMError.verify("Regex.replace exceeds bounded matching work")
                }
                guard let match else { return }
                matches += 1
                guard matches <= maximumMatches else { throw Failure.outputLimit }
                // JVM validates replacement syntax only when there is a match.
                if parts == nil { parts = try parse(replacement, expression: expression) }
                guard match.range.location >= end else { throw VMError.verify("Regex.replace overlapping matches") }
                try appendRange(NSRange(location: end, length: match.range.location - end))
                for part in parts ?? [] {
                    switch part {
                    case .literal(let value): try append(value)
                    case .indexed(let index): try appendRange(match.range(at: index))
                    case .named(let name): try appendRange(match.range(withName: name))
                    }
                }
                end = match.range.location + match.range.length
            } catch {
                failure = error
                stop.pointee = true
            }
        }
        if let failure { throw failure }
        if cancelled() { throw VMError.cancelled }
        try appendRange(NSRange(location: end, length: text.length - end))
        return output
    }

    private static func parse(_ replacement: String, expression: NSRegularExpression) throws -> [Part] {
        let scalars = Array(replacement.unicodeScalars)
        var parts: [Part] = [], literal = "", cursor = 0
        var namedGroupProbe: NSTextCheckingResult?
        func flush() { if !literal.isEmpty { parts.append(.literal(literal)); literal = "" } }
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            cursor += 1
            if scalar == "\\" {
                guard cursor < scalars.count else { throw Failure.malformedReplacement }
                literal.unicodeScalars.append(scalars[cursor]); cursor += 1
            } else if scalar == "$" {
                flush()
                guard cursor < scalars.count else { throw Failure.malformedReplacement }
                if scalars[cursor] == "{" {
                    cursor += 1
                    let start = cursor
                    while cursor < scalars.count, isLetter(scalars[cursor]) || isDigit(scalars[cursor]) { cursor += 1 }
                    guard cursor > start, isLetter(scalars[start]), cursor < scalars.count,
                          scalars[cursor] == "}" else { throw Failure.malformedReplacement }
                    let name = String(String.UnicodeScalarView(scalars[start..<cursor]))
                    cursor += 1
                    if namedGroupProbe == nil {
                        // Ask the compiled expression for the name's index. A
                        // synthetic result with every range present distinguishes
                        // an absent name from a valid group that did not match,
                        // without reparsing ICU's pattern grammar ourselves.
                        let count = expression.numberOfCaptureGroups + 1
                        var ranges = Array(repeating: NSRange(location: 0, length: 0), count: count)
                        namedGroupProbe = NSTextCheckingResult.regularExpressionCheckingResult(
                            ranges: &ranges, count: count, regularExpression: expression)
                    }
                    guard namedGroupProbe?.range(withName: name).location != NSNotFound else {
                        throw Failure.malformedReplacement
                    }
                    parts.append(.named(name))
                } else {
                    guard isDigit(scalars[cursor]) else { throw Failure.malformedReplacement }
                    var group = Int(scalars[cursor].value - 48)
                    cursor += 1
                    guard group <= expression.numberOfCaptureGroups else { throw Failure.missingGroup }
                    while cursor < scalars.count, isDigit(scalars[cursor]) {
                        let next = group * 10 + Int(scalars[cursor].value - 48)
                        guard next <= expression.numberOfCaptureGroups else { break }
                        group = next; cursor += 1
                    }
                    parts.append(.indexed(group))
                }
            } else { literal.unicodeScalars.append(scalar) }
        }
        flush()
        return parts
    }

    private static func isLetter(_ value: Unicode.Scalar) -> Bool {
        (65...90).contains(value.value) || (97...122).contains(value.value)
    }
    private static func isDigit(_ value: Unicode.Scalar) -> Bool { (48...57).contains(value.value) }

}
