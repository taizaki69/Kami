import Foundation

/// Runtime value model for the DEX interpreter (M1).
///
/// Maps Dalvik's register model onto a tagged enum. 32/64-bit and
/// object/array references are distinguished exactly as the bytecode needs;
/// `host` boxes Swift-provided objects (java.lang.String et al.) reached
/// through the host bridge.
public indirect enum RVal {
    case null
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case obj(ObjInstance)
    case arr(ArrInstance)
    case host(HostBox)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Instance of a class defined in extension DEX (`fields`) or of a host
/// compatibility class (`payload` carries the backing Swift value).
public final class ObjInstance {
    public let dexType: String          // type descriptor the DEX sees
    public var fields: [String: RVal] = [:]
    public var payload: Any?            // host backing (String, StringBuilder, …)
    /// True when this object's class is a host compat class.
    public let isHost: Bool

    public init(dexType: String, fields: [String: RVal] = [:], payload: Any? = nil, isHost: Bool = false) {
        self.dexType = dexType
        self.fields = fields
        self.payload = payload
        self.isHost = isHost
    }
}

/// DEX array instance. `elemDescriptor` distinguishes int[] vs []byte etc.
public final class ArrInstance {
    public let elemDescriptor: String
    public var elements: [RVal]

    public init(elemDescriptor: String, elements: [RVal]) {
        self.elemDescriptor = elemDescriptor
        self.elements = elements
    }
}

/// Boxing for host compatibility objects.
public struct HostBox {
    public let className: String   // java-compatible class name, e.g. "java.lang.String"
    public let value: Any

    public init(_ className: String, _ value: Any) {
        self.className = className
        self.value = value
    }
}

/// DEX-level exception carrying the thrown runtime object.
public struct DEXThrowable: Error, CustomStringConvertible {
    public let value: RVal

    public init(_ value: RVal) { self.value = value }

    public var description: String {
        if case let .host(box) = value, let s = box.value as? String {
            return "DEX exception: \(box.className): \(s)"
        }
        return "DEX exception: \(value)"
    }
}

/// Interpreter guardrail failures (mission §21: runaway protection).
public enum VMError: Error, CustomStringConvertible {
    case budgetExceeded(limit: Int)
    case cancelled
    case unresolvedMethod(class: String, signature: String)
    case unresolvedClass(String)
    case unresolvedField(class: String, name: String)
    case verify(String)

    public var description: String {
        switch self {
        case let .budgetExceeded(limit): return "instruction budget exceeded (\(limit)); possible runaway extension code"
        case .cancelled: return "execution cancelled"
        case let .unresolvedMethod(c, s): return "UNRESOLVED HOST METHOD: \(c).\(s)"
        case let .unresolvedClass(c): return "UNRESOLVED CLASS: \(c)"
        case let .unresolvedField(c, n): return "UNRESOLVED FIELD: \(c).\(n)"
        case let .verify(msg): return "verification: \(msg)"
        }
    }
}

extension RVal {
    /// Reference identity for object/array values (value equality elsewhere
    /// stays intentional per-family; `===` is Java's `==` for references).
    static func === (lhs: RVal, rhs: RVal) -> Bool {
        switch (lhs, rhs) {
        case let (.obj(a), .obj(b)): return a === b
        case let (.arr(a), .arr(b)): return a === b
        case (.null, .null): return true
        default: return false
        }
    }
    static func !== (lhs: RVal, rhs: RVal) -> Bool { !(lhs === rhs) }
}
