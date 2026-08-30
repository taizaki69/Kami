import Foundation

/// App-facing operation stages used by privacy-safe compatibility diagnostics.
/// Raw values are stable because reports are intended to be diffed and attached
/// to issue reports.
public enum InterpretedCompatibilityStage: String, CaseIterable, Sendable {
    case construction
    case metadata
    case filters
    case popular
    case latest
    case search
    case mangaUpdate = "manga-update"
    case pages
    case imageRequest = "image-request"
}

/// An exact unsupported interpreter/bridge surface with no request values,
/// URLs, headers, cookies, response data, filesystem paths, or user data.
public enum InterpretedCompatibilitySurface: Hashable, Sendable {
    case unresolvedClass(String)
    case unresolvedMethod(classDescriptor: String, signature: String)
    case unresolvedField(classDescriptor: String, name: String)
    case unsupportedOpcode(UInt8)

    public var kind: String {
        switch self {
        case .unresolvedClass: return "class"
        case .unresolvedMethod: return "method"
        case .unresolvedField: return "field"
        case .unsupportedOpcode: return "opcode"
        }
    }

    public var summary: String {
        switch self {
        case let .unresolvedClass(descriptor):
            return descriptor
        case let .unresolvedMethod(classDescriptor, signature):
            return classDescriptor + "->" + signature
        case let .unresolvedField(classDescriptor, name):
            return classDescriptor + "->" + name
        case let .unsupportedOpcode(opcode):
            return String(format: "0x%02x %@", opcode, DexOpcodeInventory.name(for: opcode))
        }
    }

    fileprivate var sortKey: String { kind + "\u{0}" + summary }
}

public struct InterpretedCompatibilityFinding: Equatable, Sendable {
    public let stage: InterpretedCompatibilityStage
    public let surface: InterpretedCompatibilitySurface
    public let occurrences: Int
}

/// Deterministic local report for one exact package/version. This is diagnostic
/// data only and carries no admission authority.
public struct InterpretedCompatibilityRuntimeReport: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let findings: [InterpretedCompatibilityFinding]
    public let droppedFindingCount: Int

    public var hasFindings: Bool { !findings.isEmpty || droppedFindingCount > 0 }

    /// Stable redacted text suitable for redirecting to a local file and
    /// attaching to an issue. Only package/version and DEX API identities are
    /// emitted; dynamic values never enter the recorder.
    public func renderedText() -> String {
        var lines = [
            "Kami compatibility report v1",
            "package: \(packageName)",
            "version: \(versionName) (\(versionCode))",
            "findings: \(findings.count)",
        ]
        for finding in findings {
            lines.append(
                "\(finding.stage.rawValue) | \(finding.surface.kind) | "
                    + "\(finding.surface.summary) | count=\(finding.occurrences)"
            )
        }
        if droppedFindingCount > 0 {
            lines.append("dropped: \(droppedFindingCount)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Optional capability for app-facing sources that can expose a redacted local
/// runtime report after an operation fails.
public protocol InterpretedCompatibilityReportingSource: KamiSource {
    func compatibilityReport() -> InterpretedCompatibilityRuntimeReport
}

/// Thread-safe bounded recorder shared by a source actor and synchronous local
/// report readers. Only typed compatibility failures are accepted; arbitrary
/// error descriptions are deliberately ignored because they can contain
/// extension or user-controlled values.
public final class InterpretedCompatibilityRecorder: @unchecked Sendable {
    private struct Key: Hashable {
        let stage: InterpretedCompatibilityStage
        let surface: InterpretedCompatibilitySurface
    }

    private let packageName: String
    private let versionName: String
    private let versionCode: Int64
    private let maximumUniqueFindings: Int
    private let lock = NSLock()
    private var occurrences: [Key: Int] = [:]
    private var droppedFindingCount = 0

    public init(
        packageName: String,
        versionName: String,
        versionCode: Int64,
        maximumUniqueFindings: Int = 256
    ) {
        self.packageName = InterpretedCompatibilityRedaction.safePackage(packageName)
        self.versionName = InterpretedCompatibilityRedaction.safeVersion(versionName)
        self.versionCode = max(0, versionCode)
        self.maximumUniqueFindings = max(1, min(maximumUniqueFindings, 4_096))
    }

    /// Records only exact typed gaps. Returns false for cancellations, budgets,
    /// validation errors, HTTP failures, parser failures, and arbitrary error
    /// strings so none of their dynamic values enter a report.
    @discardableResult
    public func record(stage: InterpretedCompatibilityStage, error: any Error) -> Bool {
        guard let surface = Self.surface(from: error) else { return false }
        let key = Key(stage: stage, surface: surface)
        lock.lock()
        defer { lock.unlock() }
        if let count = occurrences[key] {
            occurrences[key] = Self.incremented(count)
        } else if occurrences.count < maximumUniqueFindings {
            occurrences[key] = 1
        } else {
            droppedFindingCount = Self.incremented(droppedFindingCount)
        }
        return true
    }

    public func report() -> InterpretedCompatibilityRuntimeReport {
        lock.lock()
        let snapshot = occurrences
        let dropped = droppedFindingCount
        lock.unlock()
        let findings = snapshot.map { key, count in
            InterpretedCompatibilityFinding(
                stage: key.stage,
                surface: key.surface,
                occurrences: count
            )
        }.sorted {
            if $0.stage.rawValue != $1.stage.rawValue {
                return $0.stage.rawValue < $1.stage.rawValue
            }
            return $0.surface.sortKey < $1.surface.sortKey
        }
        return InterpretedCompatibilityRuntimeReport(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            findings: findings,
            droppedFindingCount: dropped
        )
    }

    private static func surface(from error: any Error) -> InterpretedCompatibilitySurface? {
        guard let error = error as? VMError else { return nil }
        switch error {
        case let .unresolvedClass(descriptor):
            return .unresolvedClass(InterpretedCompatibilityRedaction.safeDEXSymbol(descriptor))
        case let .unresolvedMethod(classDescriptor, signature):
            return .unresolvedMethod(
                classDescriptor: InterpretedCompatibilityRedaction.safeDEXSymbol(classDescriptor),
                signature: InterpretedCompatibilityRedaction.safeDEXSymbol(signature)
            )
        case let .unresolvedField(classDescriptor, name):
            return .unresolvedField(
                classDescriptor: InterpretedCompatibilityRedaction.safeDEXSymbol(classDescriptor),
                name: InterpretedCompatibilityRedaction.safeDEXSymbol(name)
            )
        case let .unsupportedOpcode(opcode):
            return .unsupportedOpcode(opcode)
        case .budgetExceeded, .cancelled, .asyncExecutionRequired,
             .ambiguousMethod, .verify:
            return nil
        }
    }

    private static func incremented(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }
}

public enum InterpretedCompatibilityRegressionPromotionError:
    Error, Equatable, LocalizedError
{
    case reportTooLarge
    case invalidReport
    case noFinding

    public var errorDescription: String? {
        switch self {
        case .reportTooLarge:
            return "The compatibility report exceeds the promotion limit."
        case .invalidReport:
            return "The compatibility report is malformed or not privacy-safe."
        case .noFinding:
            return "The compatibility report has no runtime finding to promote."
        }
    }
}

/// A reviewable assertion seed for turning one fixed runtime gap into a focused
/// exact-profile regression. It contains only the already-redacted report
/// identity and typed surface; it never embeds request or response data.
public struct InterpretedCompatibilityRegressionSeed: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let stage: InterpretedCompatibilityStage
    public let surface: InterpretedCompatibilitySurface

    /// Swift/XCTest assertion intended to be pasted after the deterministic
    /// operation that previously reached this gap. The assertion fails if the
    /// fixed surface reappears in that exact profile's compatibility report.
    public func renderedXCTestAssertion() -> String {
        let fixedSurface: String
        switch surface {
        case let .unresolvedClass(descriptor):
            fixedSurface = ".unresolvedClass(\(Self.swiftLiteral(descriptor)))"
        case let .unresolvedMethod(classDescriptor, signature):
            fixedSurface = """
            .unresolvedMethod(
                classDescriptor: \(Self.swiftLiteral(classDescriptor)),
                signature: \(Self.swiftLiteral(signature))
            )
            """
        case let .unresolvedField(classDescriptor, name):
            fixedSurface = """
            .unresolvedField(
                classDescriptor: \(Self.swiftLiteral(classDescriptor)),
                name: \(Self.swiftLiteral(name))
            )
            """
        case let .unsupportedOpcode(opcode):
            fixedSurface = String(format: ".unsupportedOpcode(0x%02x)", opcode)
        }

        return """
        // Promoted from a privacy-safe Kami runtime compatibility report.
        // package: \(packageName)
        // version: \(versionName) (\(versionCode))
        // Execute the exact deterministic \(stage.rawValue) operation before this assertion.
        let fixedCompatibilitySurface: InterpretedCompatibilitySurface = \(fixedSurface)
        XCTAssertFalse(
            source.compatibilityReport().findings.contains {
                $0.stage == .\(Self.swiftStage(stage)) &&
                    $0.surface == fixedCompatibilitySurface
            },
            "fixed compatibility gap regressed"
        )
        """ + "\n"
    }

    private static func swiftStage(_ stage: InterpretedCompatibilityStage) -> String {
        switch stage {
        case .construction: return "construction"
        case .metadata: return "metadata"
        case .filters: return "filters"
        case .popular: return "popular"
        case .latest: return "latest"
        case .search: return "search"
        case .mangaUpdate: return "mangaUpdate"
        case .pages: return "pages"
        case .imageRequest: return "imageRequest"
        }
    }

    private static func swiftLiteral(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }
}

/// Strict parser/promotion seam for the recorder's canonical v1 text. Input is
/// bounded and every exported identity is revalidated through the same
/// redaction allow-list before a Swift assertion is emitted.
public enum InterpretedCompatibilityRegressionPromotion {
    /// Covers the recorder's maximum 4,096 unique findings even when both
    /// symbols in every method finding reach their 4 KiB redaction cap.
    public static let maximumReportBytes = 40 * 1_024 * 1_024

    public static func seed(
        fromRenderedReport text: String
    ) throws -> InterpretedCompatibilityRegressionSeed {
        guard text.utf8.count <= maximumReportBytes else {
            throw InterpretedCompatibilityRegressionPromotionError.reportTooLarge
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 5,
              lines[0] == "Kami compatibility report v1",
              let packageName = value(after: "package: ", in: lines[1]),
              packageName == InterpretedCompatibilityRedaction.safePackage(packageName),
              let versionPayload = value(after: "version: ", in: lines[2]),
              let versionRange = versionPayload.range(of: " (", options: .backwards),
              versionPayload.hasSuffix(")"),
              let versionCode = Int64(versionPayload[
                  versionRange.upperBound..<versionPayload.index(before: versionPayload.endIndex)
              ]),
              versionCode >= 0,
              let findingCountText = value(after: "findings: ", in: lines[3]),
              let findingCount = Int(findingCountText),
              (0...4_096).contains(findingCount) else {
            throw InterpretedCompatibilityRegressionPromotionError.invalidReport
        }
        guard findingCount > 0 else {
            throw InterpretedCompatibilityRegressionPromotionError.noFinding
        }
        let versionName = String(versionPayload[..<versionRange.lowerBound])
        guard versionName == InterpretedCompatibilityRedaction.safeVersion(versionName),
              lines.count >= 5 + findingCount else {
            throw InterpretedCompatibilityRegressionPromotionError.invalidReport
        }
        var parsedFindings: [(
            stage: InterpretedCompatibilityStage,
            surface: InterpretedCompatibilitySurface
        )] = []
        parsedFindings.reserveCapacity(findingCount)
        for line in lines[4..<(4 + findingCount)] {
            parsedFindings.append(try parseFinding(line))
        }
        let tail = Array(lines.dropFirst(4 + findingCount))
        let validTail: Bool
        if tail == [""] {
            validTail = true
        } else if tail.count == 2,
                  tail[1].isEmpty,
                  let droppedText = value(after: "dropped: ", in: tail[0]),
                  let dropped = Int(droppedText),
                  dropped > 0 {
            validTail = true
        } else {
            validTail = false
        }
        guard validTail, let first = parsedFindings.first else {
            throw InterpretedCompatibilityRegressionPromotionError.invalidReport
        }
        return InterpretedCompatibilityRegressionSeed(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            stage: first.stage,
            surface: first.surface
        )
    }

    private static func parseFinding(
        _ line: String
    ) throws -> (
        stage: InterpretedCompatibilityStage,
        surface: InterpretedCompatibilitySurface
    ) {
        let components = line.components(separatedBy: " | ")
        guard components.count == 4,
              let stage = InterpretedCompatibilityStage(rawValue: components[0]),
              let countText = value(after: "count=", in: components[3]),
              let count = Int(countText),
              count > 0 else {
            throw InterpretedCompatibilityRegressionPromotionError.invalidReport
        }
        return (
            stage,
            try parseSurface(kind: components[1], summary: components[2])
        )
    }

    private static func parseSurface(
        kind: String,
        summary: String
    ) throws -> InterpretedCompatibilitySurface {
        switch kind {
        case "class":
            guard summary == InterpretedCompatibilityRedaction.safeDEXSymbol(summary) else {
                throw InterpretedCompatibilityRegressionPromotionError.invalidReport
            }
            return .unresolvedClass(summary)
        case "method", "field":
            guard let separator = summary.range(of: "->") else {
                throw InterpretedCompatibilityRegressionPromotionError.invalidReport
            }
            let classDescriptor = String(summary[..<separator.lowerBound])
            let member = String(summary[separator.upperBound...])
            guard classDescriptor == InterpretedCompatibilityRedaction.safeDEXSymbol(
                classDescriptor
            ), member == InterpretedCompatibilityRedaction.safeDEXSymbol(member) else {
                throw InterpretedCompatibilityRegressionPromotionError.invalidReport
            }
            if kind == "method" {
                return .unresolvedMethod(
                    classDescriptor: classDescriptor,
                    signature: member
                )
            }
            return .unresolvedField(classDescriptor: classDescriptor, name: member)
        case "opcode":
            guard let token = summary.split(separator: " ").first,
                  token.count == 4,
                  token.hasPrefix("0x"),
                  let opcode = UInt8(token.dropFirst(2), radix: 16),
                  summary == String(
                      format: "0x%02x %@",
                      opcode,
                      DexOpcodeInventory.name(for: opcode)
                  ) else {
                throw InterpretedCompatibilityRegressionPromotionError.invalidReport
            }
            return .unsupportedOpcode(opcode)
        default:
            throw InterpretedCompatibilityRegressionPromotionError.invalidReport
        }
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}

enum InterpretedCompatibilityRedaction {
    static func safePackage(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 512,
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a) ||
                      byte == 0x2e || byte == 0x5f
              }) else { return "<redacted-package>" }
        return value
    }

    static func safeVersion(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a) ||
                      byte == 0x2b || byte == 0x2d || byte == 0x2e || byte == 0x5f
              }) else { return "<redacted-version>" }
        return value
    }

    static func safeDEXSymbol(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.utf8.allSatisfy({ byte in
                  if (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a) {
                      return true
                  }
                  switch byte {
                  case 0x24, 0x28, 0x29, 0x2d, 0x2f, 0x3b, 0x3c, 0x3e,
                       0x5b, 0x5d, 0x5f:
                      return true
                  default:
                      return false
                  }
              }) else { return "<redacted-symbol>" }
        return value
    }
}
