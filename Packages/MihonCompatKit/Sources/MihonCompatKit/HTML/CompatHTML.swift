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

        let cost = queryBytes.multipliedReportingOverflow(by: max(1, nodeCount))
        guard !cost.overflow, cost.partialValue <= remainingSelectorWork else {
            throw CompatHTMLError.selectorBudgetExceeded(limit: policy.maximumSelectorWork)
        }
        remainingSelectorWork -= cost.partialValue

        do {
            let elements = try root.select(query).array()
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
