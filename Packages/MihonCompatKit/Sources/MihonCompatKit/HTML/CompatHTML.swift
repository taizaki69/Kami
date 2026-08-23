import Foundation
import SwiftSoup

/// Resource policy for HTML supplied by an untrusted extension response.
///
/// SwiftSoup supplies broad HTML5 parsing and CSS selector compatibility. Kami
/// owns the limits around it so an extension cannot turn one response into an
/// unbounded DOM or repeatedly run expensive selectors.
public struct CompatHTMLPolicy: Sendable, Equatable {
    public let maximumInputBytes: Int
    public let maximumNodes: Int
    public let maximumDepth: Int
    public let maximumAttributes: Int
    public let maximumAttributesPerElement: Int
    public let maximumSelectorBytes: Int
    public let maximumSelectorResults: Int
    public let maximumSelectorWork: Int
    public let maximumExtractedStringBytes: Int

    public init(
        maximumInputBytes: Int = 8 * 1024 * 1024,
        maximumNodes: Int = 100_000,
        maximumDepth: Int = 256,
        maximumAttributes: Int = 250_000,
        maximumAttributesPerElement: Int = 256,
        maximumSelectorBytes: Int = 2_048,
        maximumSelectorResults: Int = 50_000,
        maximumSelectorWork: Int = 50_000_000,
        maximumExtractedStringBytes: Int = 1024 * 1024
    ) {
        self.maximumInputBytes = max(1, min(maximumInputBytes, 32 * 1024 * 1024))
        self.maximumNodes = max(1, min(maximumNodes, 500_000))
        self.maximumDepth = max(1, min(maximumDepth, 1_024))
        self.maximumAttributes = max(1, min(maximumAttributes, 1_000_000))
        self.maximumAttributesPerElement = max(1, min(maximumAttributesPerElement, 4_096))
        self.maximumSelectorBytes = max(1, min(maximumSelectorBytes, 16_384))
        self.maximumSelectorResults = max(1, min(maximumSelectorResults, 500_000))
        self.maximumSelectorWork = max(1, min(maximumSelectorWork, 1_000_000_000))
        self.maximumExtractedStringBytes = max(
            1,
            min(maximumExtractedStringBytes, 16 * 1024 * 1024)
        )
    }
}

public enum CompatHTMLError: Swift.Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBaseURL
    case inputTooLarge(limit: Int)
    case tooManyNodes(limit: Int)
    case nestingTooDeep(limit: Int)
    case tooManyAttributes(limit: Int)
    case tooManyAttributesOnElement(limit: Int)
    case invalidSelector
    case selectorTooLarge(limit: Int)
    case tooManySelectorResults(limit: Int)
    case selectorBudgetExceeded(limit: Int)
    case extractedStringTooLarge(limit: Int)
    case malformedHTML

    public var description: String {
        switch self {
        case .invalidBaseURL: return "invalid HTML base URL"
        case let .inputTooLarge(limit): return "HTML input exceeds \(limit) bytes"
        case let .tooManyNodes(limit): return "HTML DOM exceeds \(limit) nodes"
        case let .nestingTooDeep(limit): return "HTML DOM exceeds depth \(limit)"
        case let .tooManyAttributes(limit): return "HTML DOM exceeds \(limit) attributes"
        case let .tooManyAttributesOnElement(limit):
            return "HTML element exceeds \(limit) attributes"
        case .invalidSelector: return "invalid CSS selector"
        case let .selectorTooLarge(limit): return "CSS selector exceeds \(limit) bytes"
        case let .tooManySelectorResults(limit):
            return "CSS selector exceeds \(limit) results"
        case let .selectorBudgetExceeded(limit):
            return "CSS selector work exceeds \(limit) units"
        case let .extractedStringTooLarge(limit):
            return "HTML extracted string exceeds \(limit) bytes"
        case .malformedHTML: return "HTML parsing failed"
        }
    }
}

/// Shared state for one parsed document. Element wrappers retain this context
/// so selector work is cumulative across every call derived from the document.
final class CompatHTMLContext {
    private struct DirectChildHasPlan {
        let baseQuery: String
        let childQueries: [String]
    }

    let document: SwiftSoup.Document
    let policy: CompatHTMLPolicy
    let nodeCount: Int
    private var remainingSelectorWork: Int

    init(document: SwiftSoup.Document, policy: CompatHTMLPolicy, nodeCount: Int) {
        self.document = document
        self.policy = policy
        self.nodeCount = nodeCount
        self.remainingSelectorWork = policy.maximumSelectorWork
    }

    func select(_ root: SwiftSoup.Element, query: String) throws -> [SwiftSoup.Element] {
        let queryBytes = query.utf8.count
        guard queryBytes > 0 else { throw CompatHTMLError.invalidSelector }
        guard queryBytes <= policy.maximumSelectorBytes else {
            throw CompatHTMLError.selectorTooLarge(limit: policy.maximumSelectorBytes)
        }

        let directChildPlan = Self.directChildHasPlan(query)
        let passes = 1 + (directChildPlan?.childQueries.count ?? 0)
        let baseCost = queryBytes.multipliedReportingOverflow(by: max(1, nodeCount))
        let cost = baseCost.partialValue.multipliedReportingOverflow(by: passes)
        guard !baseCost.overflow, !cost.overflow,
              cost.partialValue <= remainingSelectorWork else {
            throw CompatHTMLError.selectorBudgetExceeded(limit: policy.maximumSelectorWork)
        }
        remainingSelectorWork -= cost.partialValue

        do {
            let elements: [SwiftSoup.Element]
            if let plan = directChildPlan {
                let candidates = try Self.selectRaw(root, query: plan.baseQuery)
                let evaluators = try plan.childQueries.map {
                    try SwiftSoup.QueryParser.parse($0)
                }
                elements = try candidates.filter { candidate in
                    for evaluator in evaluators {
                        let hasDirectMatch = try candidate.children().array().contains { child in
                            try evaluator.matches(candidate, child)
                        }
                        if !hasDirectMatch { return false }
                    }
                    return true
                }
            } else {
                elements = try Self.selectRaw(root, query: query)
            }
            guard elements.count <= policy.maximumSelectorResults else {
                throw CompatHTMLError.tooManySelectorResults(
                    limit: policy.maximumSelectorResults
                )
            }
            return elements
        } catch let error as CompatHTMLError {
            throw error
        } catch {
            throw CompatHTMLError.invalidSelector
        }
    }

    private static func selectRaw(
        _ root: SwiftSoup.Element,
        query: String
    ) throws -> [SwiftSoup.Element] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(">") {
            return try root.select(":root " + trimmed).array()
        }
        return try root.select(trimmed).array()
    }

    /// SwiftSoup 2.9.6 predates Jsoup's relative-selector handling inside
    /// `:has(...)`. Extract top-level `:has(> child)` clauses and enforce them
    /// against direct children while leaving the rest of the selector to the
    /// full CSS engine. Nested/quoted parentheses are scanned, not split by a
    /// regular expression, so `:contains(...)` remains intact.
    private static func directChildHasPlan(_ query: String) -> DirectChildHasPlan? {
        let bytes = Array(query.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var children: [String] = []
        var index = 0
        var nesting = 0
        var quote: UInt8?
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if byte == 0x22 || byte == 0x27 {
                quote = byte
                output.append(byte)
                index += 1
                continue
            }

            if nesting == 0, isHasToken(bytes, at: index),
               let close = matchingParenthesis(bytes, open: index + 4) {
                var start = index + 5
                var end = close
                while start < end, isASCIIWhitespace(bytes[start]) { start += 1 }
                while end > start, isASCIIWhitespace(bytes[end - 1]) { end -= 1 }
                if start < end, bytes[start] == 0x3E {
                    start += 1
                    while start < end, isASCIIWhitespace(bytes[start]) { start += 1 }
                    guard start < end else { return nil }
                    children.append(String(decoding: bytes[start..<end], as: UTF8.self))
                    index = close + 1
                    continue
                }
            }

            output.append(byte)
            if byte == 0x28 {
                nesting += 1
            } else if byte == 0x29, nesting > 0 {
                nesting -= 1
            }
            index += 1
        }

        guard !children.isEmpty else { return nil }
        let base = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DirectChildHasPlan(
            baseQuery: base.isEmpty ? "*" : base,
            childQueries: children
        )
    }

    private static func isHasToken(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 4 < bytes.count, bytes[index] == 0x3A else { return false }
        let h = bytes[index + 1] | 0x20
        let a = bytes[index + 2] | 0x20
        let s = bytes[index + 3] | 0x20
        return h == 0x68 && a == 0x61 && s == 0x73 && bytes[index + 4] == 0x28
    }

    private static func matchingParenthesis(_ bytes: [UInt8], open: Int) -> Int? {
        guard open < bytes.count, bytes[open] == 0x28 else { return nil }
        var depth = 1
        var index = open + 1
        var quote: UInt8?
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == activeQuote {
                    quote = nil
                }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x28 {
                depth += 1
            } else if byte == 0x29 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    func boundedString(_ value: String) throws -> String {
        guard value.utf8.count <= policy.maximumExtractedStringBytes else {
            throw CompatHTMLError.extractedStringTooLarge(
                limit: policy.maximumExtractedStringBytes
            )
        }
        return value
    }
}

struct CompatHTMLElementBox {
    let context: CompatHTMLContext
    let element: SwiftSoup.Element
}

enum CompatHTMLParser {
    static func parse(
        _ html: String,
        baseURL: String,
        policy: CompatHTMLPolicy
    ) throws -> CompatHTMLContext {
        guard html.utf8.count <= policy.maximumInputBytes else {
            throw CompatHTMLError.inputTooLarge(limit: policy.maximumInputBytes)
        }
        guard baseURL.utf8.count <= 8_192,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil else {
            throw CompatHTMLError.invalidBaseURL
        }

        let document: SwiftSoup.Document
        do {
            document = try SwiftSoup.parse(html, baseURL)
        } catch {
            throw CompatHTMLError.malformedHTML
        }

        var nodeCount = 0
        var attributeCount = 0
        var stack: [(node: SwiftSoup.Node, depth: Int)] = [(document, 0)]
        while let current = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= policy.maximumNodes else {
                throw CompatHTMLError.tooManyNodes(limit: policy.maximumNodes)
            }
            guard current.depth <= policy.maximumDepth else {
                throw CompatHTMLError.nestingTooDeep(limit: policy.maximumDepth)
            }
            if let attributes = current.node.getAttributes() {
                let count = attributes.size()
                guard count <= policy.maximumAttributesPerElement else {
                    throw CompatHTMLError.tooManyAttributesOnElement(
                        limit: policy.maximumAttributesPerElement
                    )
                }
                let total = attributeCount.addingReportingOverflow(count)
                guard !total.overflow, total.partialValue <= policy.maximumAttributes else {
                    throw CompatHTMLError.tooManyAttributes(limit: policy.maximumAttributes)
                }
                attributeCount = total.partialValue
            }
            for child in current.node.getChildNodes().reversed() {
                stack.append((child, current.depth + 1))
            }
        }

        return CompatHTMLContext(document: document, policy: policy, nodeCount: nodeCount)
    }
}
