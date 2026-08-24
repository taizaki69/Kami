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
