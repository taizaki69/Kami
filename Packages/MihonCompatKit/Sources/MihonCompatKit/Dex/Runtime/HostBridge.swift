import Foundation

/// Host method bridge: the only path from interpreted DEX to native Swift
/// (mission §23). Registrations are explicit; the VM never hardcodes classes.
public final class HostBridge {
    public typealias Method = (_ vm: DexInterpreter, _ args: [RVal]) throws -> RVal

    struct Registration {
        let method: Method
    }

    /// "descriptor.methodName" → implementations (last registration wins;
    /// a plain methodName key applies to any class — used sparingly).
    private var methods: [String: Registration] = [:]

    /// Static field storage for host classes (sget/sput on host classes).
    public var staticFields: [String: RVal] = [:]

    /// new-instance factories for host classes (StringBuilder, …).
    public var objectFactories: [String: (DexInterpreter) throws -> RVal] = [:]

    public init() {}

    public func register(class descriptor: String, _ methodName: String, _ body: @escaping Method) {
        methods["\(descriptor).\(methodName)"] = Registration(method: body)
    }

    public func resolve(class descriptor: String, _ methodName: String) -> Method? {
        if let r = methods["\(descriptor).\(methodName)"] { return r.method }
        return nil
    }

    /// Registers the minimal M1 host surface: Intrinsics null-checks and the
    /// object/String basics that real extension methods hit immediately.
    public static func minimal() -> HostBridge {
        let bridge = HostBridge()

        // Kotlin null checks — no-op in M1 (real parameter validation later).
        for name in [
            "checkNotNullParameter", "checkNotNull", "checkParameterIsNotNull",
            "checkExpressionValueIsNotNull", "checkNotNullExpressionValue",
            "throwNpe", "throwUninitializedProperty",
        ] {
            bridge.register(class: "Lkotlin/jvm/internal/Intrinsics;", name) { _, _ in .null }
        }

        // Object identity basics.
        bridge.register(class: "Ljava/lang/Object;", "<init>") { _, _ in .null }
        bridge.register(class: "Ljava/lang/Object;", "equals") { _, args in
            .int(args[0] === args[1] ? 1 : 0)
        }
        bridge.register(class: "Ljava/lang/Object;", "hashCode") { vm, args in
            if case let .obj(o) = args[0] {
                let h = UInt32(bitPattern: Int32(ObjectIdentifier(o).hashValue & 0x7FFFFFFF))
                return .int(Int32(bitPattern: h))
            }
            return .int(0)
        }
        bridge.register(class: "Ljava/lang/Object;", "toString") { _, args in
            Self.string(vmStringValue(args[0]))
        }
        bridge.register(class: "Ljava/lang/Object;", "getClass") { vm, args in
            Self.classObject(for: args[0], vm: vm)
        }

        // java.lang.String surface (payload-backed).
        Self.registerStringSurface(bridge)
        Self.registerStringBuilder(bridge)
        return bridge
    }

    /// StringBuilder: payload carries [String]; capacity ignored in M1.
    static func registerStringBuilder(_ bridge: HostBridge) {
        let d = "Ljava/lang/StringBuilder;"
        bridge.objectFactories[d] = { _ in
            .obj(ObjInstance(dexType: d, payload: "", isHost: true))
        }
        func text(_ v: RVal) -> String { vmStringValue(v) }
        bridge.register(class: d, "<init>") { _, _ in .null }
        bridge.register(class: d, "append") { _, args in
            guard case let .obj(o) = args[0] else { throw VMError.verify("append receiver") }
            let current = (o.payload as? String) ?? ""
            o.payload = current + text(args[1])
            return .obj(o)
        }
        bridge.register(class: d, "toString") { _, args in Self.string(text(args[0])) }
        bridge.register(class: d, "length") { _, args in .int(Int32(text(args[0]).utf16.count)) }
        bridge.register(class: d, "isEmpty") { _, args in .int(text(args[0]).isEmpty ? 1 : 0) }
    }

    static func string(_ s: String) -> RVal {
        .obj(ObjInstance(dexType: "Ljava/lang/String;", payload: s, isHost: true))
    }

    static func registerStringSurface(_ bridge: HostBridge) {
        let d = "Ljava/lang/String;"
        bridge.register(class: d, "length") { _, args in .int(Int32(vmStringValue(args[0]).utf16.count)) }
        bridge.register(class: d, "isEmpty") { _, args in .int(vmStringValue(args[0]).isEmpty ? 1 : 0) }
        bridge.register(class: d, "charAt") { _, args in
            guard case let .int(i) = args[1] else { throw VMError.verify("charAt non-int index") }
            let units = Array(vmStringValue(args[0]).utf16)
            guard Int(i) < units.count else { throw DEXThrowable(Self.string("StringIndexOutOfBoundsException")) }
            return .int(Int32(units[Int(i)]))
        }
        bridge.register(class: d, "equals") { _, args in
            .int(vmStringValue(args[0]) == vmStringValue(args[1]) ? 1 : 0)
        }
        bridge.register(class: d, "hashCode") { _, args in
            // Java string hash: s[0]*31^(n-1) + …
            var h: Int32 = 0
            for u in vmStringValue(args[0]).utf16 { h = 31 &* h &+ Int32(u) }
            return .int(h)
        }
        bridge.register(class: d, "concat") { _, args in
            Self.string(vmStringValue(args[0]) + vmStringValue(args[1]))
        }
        bridge.register(class: d, "toString") { _, args in Self.string(vmStringValue(args[0])) }
    }

    static func classObject(for value: RVal, vm: DexInterpreter) -> RVal {
        let name: String
        switch value {
        case .int: name = "Ljava/lang/Integer;"
        case .long: name = "Ljava/lang/Long;"
        case .float: name = "Ljava/lang/Float;"
        case .double: name = "Ljava/lang/Double;"
        case .null: name = "Ljava/lang/Void;"
        case let .obj(o): name = o.dexType
        case let .arr(a): name = "[" + a.elemDescriptor
        case let .host(h): name = "L" + h.className.replacingOccurrences(of: ".", with: "/") + ";"
        }
        return .obj(ObjInstance(dexType: "Ljava/lang/Class;", payload: name, isHost: true))
    }
}

/// Shared string coercion: host String objects carry their value in payload;
/// DEX-declared objects stringify via their toString for concatenation.
func vmStringValue(_ v: RVal) -> String {
    switch v {
    case let .obj(o):
        if let s = o.payload as? String { return s }
        if let s = o.payload as? Int32 { return String(s) }
        return o.dexType
    case let .host(h):
        if let s = h.value as? String { return s }
        return String(describing: h.value)
    case .null: return "null"
    case let .int(i): return String(i)
    case let .long(l): return String(l)
    case let .float(f): return String(f)
    case let .double(d): return String(d)
    case let .arr(a): return "[array \(a.elemDescriptor) x\(a.elements.count)]"
    }
}
