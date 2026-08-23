import Foundation

/// Non-error control flow: `return` unwinds exactly one frame.
struct FrameReturn: Error {
    let value: RVal
}

/// Register-based Dalvik interpreter (M1).
///
/// Executes `code_item` instruction streams from a parsed `DexFile`,
/// resolving calls to either interpreted DEX methods or the `HostBridge`.
/// Hard instruction budget + cancellation keep untrusted code from freezing
/// the host; unresolved surface reports precisely (mission §21/§34).
public final class DexInterpreter {
    private enum InvocationKind {
        case virtual
        case superMethod
        case direct
        case staticMethod
        case interface

        init?(opcode: UInt8) {
            switch opcode {
            case 0x6e, 0x74: self = .virtual
            case 0x6f, 0x75: self = .superMethod
            case 0x70, 0x76: self = .direct
            case 0x71, 0x77: self = .staticMethod
            case 0x72, 0x78: self = .interface
            default: return nil
            }
        }

        var isStatic: Bool {
            if case .staticMethod = self { return true }
            return false
        }

        var usesReceiverDispatch: Bool {
            switch self {
            case .virtual, .interface: return true
            case .superMethod, .direct, .staticMethod: return false
            }
        }
    }

    public let dex: DexFile
    public let bridge: HostBridge
    public var maxInstructions: Int
    public var cancelled: () -> Bool
    /// Trace sink for the runtime trace mode (§33); nil = off.
    public var trace: ((String) -> Void)?

    /// methodIndex → (defining class def, encoded method).
    private var dexMethodTable: [Int: (DexFile.ClassDef, DexFile.EncodedMethod)] = [:]
    /// Static field storage for DEX-defined classes: "class->name".
    private var dexStatics: [String: RVal] = [:]
    private enum ClassInitializationState {
        case initializing
        case initialized
        case failed(String)
    }
    private var classInitialization: [String: ClassInitializationState] = [:]
    /// Method indexes whose complete code-item and exception geometry was
    /// verified once, mapped to the decoded handlers used during execution.
    private var verifiedMethods: [Int: [DexTryBlock]] = [:]
    private var lastResult: RVal = .null
    /// Current interpreted-frame depth (recursion guard).
    private var depth = 0
    /// One budget shared by the complete interpreted call tree.
    private var remainingInstructions = 0
    /// Public entry points can perform class initialization before the first
    /// frame. Keep that work in the same instruction-budget session.
    private var entryDepth = 0
    /// Conservative default: interpreted frames are large in debug builds and
    /// unbounded recursion (obfuscated/mis-resolved super calls) must not
    /// overflow the host stack. The production runtime raises this by
    /// executing on a dedicated big-stack thread (see docs/EXTENSION_RUNTIME).
    public var maxCallDepth = 48

    public init(dex: DexFile,
                bridge: HostBridge = HostBridge.minimal(),
                maxInstructions: Int = 2_000_000,
                cancelled: @escaping () -> Bool = { false }) {
        self.dex = dex
        self.bridge = bridge
        self.maxInstructions = maxInstructions
        self.cancelled = cancelled
        for def in dex.classDefs {
            for m in def.directMethods + def.virtualMethods {
                dexMethodTable[m.methodIndex] = (def, m)
            }
        }
    }

    // MARK: - Public entry points

    @discardableResult
    public func call(classDescriptor: String, method: String, args: [RVal] = []) throws -> RVal {
        guard let defIndex = dex.classIndexByDescriptor[classDescriptor] else {
            throw VMError.unresolvedClass(classDescriptor)
        }
        let def = dex.classDefs[defIndex]
        let all = def.directMethods + def.virtualMethods
        let matches = all.filter { dex.methodIds[$0.methodIndex].name == method }
        guard !matches.isEmpty else {
            throw VMError.unresolvedMethod(class: classDescriptor, signature: method)
        }
        guard matches.count == 1, let match = matches.first else {
            let candidates = matches.map { dex.methodIds[$0.methodIndex].signature }.sorted()
            throw VMError.ambiguousMethod(class: classDescriptor, name: method, candidates: candidates)
        }
        return try withInstructionBudget {
            if method == "<clinit>" {
                guard args.isEmpty else {
                    throw VMError.verify("\(classDescriptor).<clinit>()V expects no arguments")
                }
                try ensureClassInitialized(classDescriptor)
                return .null
            }
            if match.accessFlags & 0x8 != 0 {
                try ensureClassInitialized(classDescriptor)
            }
            return try execute(def: def, method: match, args: args)
        }
    }

    /// Calls one exact DEX overload. Use this at API boundaries where a class
    /// may expose multiple methods with the same name.
    @discardableResult
    public func call(classDescriptor: String, method: String, prototype: String,
                     args: [RVal] = []) throws -> RVal {
        guard let defIndex = dex.classIndexByDescriptor[classDescriptor] else {
            throw VMError.unresolvedClass(classDescriptor)
        }
        let def = dex.classDefs[defIndex]
        let matches = (def.directMethods + def.virtualMethods).filter {
            let reference = dex.methodIds[$0.methodIndex]
            return reference.name == method && reference.prototype.descriptor == prototype
        }
        guard !matches.isEmpty else {
            throw VMError.unresolvedMethod(class: classDescriptor, signature: method + prototype)
        }
        guard matches.count == 1, let match = matches.first else {
            throw VMError.verify("duplicate encoded method \(classDescriptor).\(method)\(prototype)")
        }
        return try withInstructionBudget {
            if method == "<clinit>" {
                guard prototype == "()V", args.isEmpty else {
                    throw VMError.verify("\(classDescriptor).<clinit>()V expects no arguments")
                }
                try ensureClassInitialized(classDescriptor)
                return .null
            }
            if match.accessFlags & 0x8 != 0 {
                try ensureClassInitialized(classDescriptor)
            }
            return try execute(def: def, method: match, args: args)
        }
    }

    /// Allocates a DEX class instance and runs `<init>` (constructor).
    @discardableResult
    public func instantiate(classDescriptor: String) throws -> RVal {
        guard let defIndex = dex.classIndexByDescriptor[classDescriptor] else {
            throw VMError.unresolvedClass(classDescriptor)
        }
        let def = dex.classDefs[defIndex]
        return try withInstructionBudget {
            try ensureClassInitialized(classDescriptor)
            let obj = ObjInstance(dexType: classDescriptor)
            for f in def.instanceFields {
                guard let field = try? fieldAt(f.fieldIndex) else { continue }
                obj.fields[field.name] = defaultValue(for: field.type)
            }
            let constructors = def.directMethods.filter { dex.methodIds[$0.methodIndex].name == "<init>" }
            let noArgumentConstructors = constructors.filter {
                let reference = dex.methodIds[$0.methodIndex]
                return reference.prototype.descriptor == "()V"
            }
            if noArgumentConstructors.count == 1, let ctor = noArgumentConstructors.first {
                _ = try execute(def: def, method: ctor, args: [.obj(obj)])
            } else if noArgumentConstructors.count > 1 {
                throw VMError.verify("duplicate encoded constructor \(classDescriptor).<init>()V")
            } else if !constructors.isEmpty {
                throw VMError.unresolvedMethod(class: classDescriptor, signature: "<init>()V")
            }
            return .obj(obj)
        }
    }

    private func withInstructionBudget<T>(_ operation: () throws -> T) throws -> T {
        let startsSession = entryDepth == 0 && depth == 0
        if startsSession { remainingInstructions = maxInstructions }
        entryDepth += 1
        defer { entryDepth -= 1 }
        return try operation()
    }

    private func ensureClassInitialized(_ descriptor: String) throws {
        guard let defIndex = dex.classIndexByDescriptor[descriptor] else { return }
        if let state = classInitialization[descriptor] {
            switch state {
            case .initializing, .initialized:
                return
            case let .failed(reason):
                throw VMError.verify("class initialization previously failed for \(descriptor): \(reason)")
            }
        }

        classInitialization[descriptor] = .initializing
        do {
            let def = dex.classDefs[defIndex]
            if def.superclassIndex >= 0, def.superclassIndex < dex.typeDescriptors.count {
                try ensureClassInitialized(dex.typeDescriptors[def.superclassIndex])
            }
            let initializers = def.directMethods.filter {
                let reference = dex.methodIds[$0.methodIndex]
                return reference.name == "<clinit>" && reference.prototype.descriptor == "()V"
            }
            guard initializers.count <= 1 else {
                throw VMError.verify("duplicate class initializer \(descriptor).<clinit>()V")
            }
            if let initializer = initializers.first {
                guard initializer.accessFlags & 0x8 != 0 else {
                    throw VMError.verify("non-static class initializer \(descriptor).<clinit>()V")
                }
                _ = try execute(def: def, method: initializer, args: [])
            }
            classInitialization[descriptor] = .initialized
        } catch {
            classInitialization[descriptor] = .failed(String(describing: error))
            throw error
        }
    }

    func defaultValue(for descriptor: String) -> RVal {
        switch descriptor {
        case "J": return .long(0)
        case "F": return .float(0)
        case "D": return .double(0)
        case "Z", "B", "C", "S", "I": return .int(0)
        default: return .null // L...; and [...
        }
    }

    private func validateLogicalArguments(_ args: [RVal], prototype: DexFile.Prototype,
                                          hasReceiver: Bool, context: String) throws {
        let expectedCount = prototype.parameters.count + (hasReceiver ? 1 : 0)
        guard args.count == expectedCount else {
            throw VMError.verify(
                "\(context) expects \(expectedCount) logical arguments, got \(args.count)"
            )
        }

        var offset = 0
        if hasReceiver {
            let receiver = args[0]
            guard Self.matches(receiver, descriptor: "Ljava/lang/Object;") else {
                throw VMError.verify("\(context) receiver is not a reference")
            }
            if Self.isNullReference(receiver) {
                throw DEXThrowable(HostBridge.string("NullPointerException"))
            }
            offset = 1
        }

        for (index, descriptor) in prototype.parameters.enumerated() {
            guard Self.matches(args[index + offset], descriptor: descriptor) else {
                throw VMError.verify(
                    "\(context) argument \(index) does not match DEX type \(descriptor)"
                )
            }
        }
    }

    private func validatedReturn(_ value: RVal, prototype: DexFile.Prototype,
                                 context: String) throws -> RVal {
        if prototype.returnType == "V" {
            guard value.isNull else {
                throw VMError.verify("\(context) returned a value from a void method")
            }
            return .null
        }
        guard Self.matches(value, descriptor: prototype.returnType) else {
            throw VMError.verify(
                "\(context) result does not match DEX return type \(prototype.returnType)"
            )
        }
        if Self.isReferenceDescriptor(prototype.returnType), Self.isNullReference(value) {
            return .null
        }
        return value
    }

    private static func isReferenceDescriptor(_ descriptor: String) -> Bool {
        descriptor.hasPrefix("L") || descriptor.hasPrefix("[")
    }

    private static func isNullReference(_ value: RVal) -> Bool {
        if value.isNull { return true }
        if case let .int(raw) = value { return raw == 0 }
        return false
    }

    private static func matches(_ value: RVal, descriptor: String) -> Bool {
        switch descriptor {
        case "Z", "B", "C", "S", "I":
            if case .int = value { return true }
            return false
        case "J":
            if case .long = value { return true }
            return false
        case "F":
            if case .float = value { return true }
            return false
        case "D":
            if case .double = value { return true }
            return false
        default:
            guard isReferenceDescriptor(descriptor) else { return false }
            switch value {
            case .null, .obj, .arr, .host: return true
            case let .int(raw): return raw == 0 // const/4 0 is verifier-polymorphic null
            default: return false
            }
        }
    }

    // MARK: - Execution

    @discardableResult
    func execute(def: DexFile.ClassDef, method: DexFile.EncodedMethod, args: [RVal]) throws -> RVal {
        let ref = dex.methodIds[method.methodIndex]
        let hasReceiver = method.accessFlags & 0x8 == 0
        try validateLogicalArguments(
            args,
            prototype: ref.prototype,
            hasReceiver: hasReceiver,
            context: ref.signature
        )

        guard let code = dex.codeItem(for: method) else {
            guard method.codeOffset == 0 else {
                throw VMError.verify("malformed code item for \(ref.declaringClass).\(ref.signature)")
            }
            if let host = bridge.resolve(ref, isStatic: !hasReceiver) {
                return try validatedReturn(try host(self, args), prototype: ref.prototype, context: ref.signature)
            }
            throw VMError.unresolvedMethod(class: ref.declaringClass, signature: ref.signature)
        }
        let isRootFrame = depth == 0
        guard depth < maxCallDepth else {
            throw VMError.verify("call depth exceeded \(maxCallDepth) (runaway recursion)")
        }
        depth += 1
        defer { depth -= 1 }

        let incomingWords = args.reduce(0) { $0 + ($1.isWide ? 2 : 1) }
        guard incomingWords == Int(code.insSize), incomingWords <= Int(code.registersSize) else {
            throw VMError.verify(
                "argument width \(incomingWords) does not match ins_size \(code.insSize) for \(dex.methodIds[method.methodIndex].name)"
            )
        }
        if isRootFrame, entryDepth == 0 { remainingInstructions = maxInstructions }

        let tries: [DexTryBlock]
        if let verified = verifiedMethods[method.methodIndex] {
            tries = verified
        } else {
            let verified = try DexCodeVerifier.verify(code: code, method: method, dex: dex)
            verifiedMethods[method.methodIndex] = verified
            tries = verified
        }

        var regs = [RVal](repeating: .int(0), count: Int(code.registersSize))
        var cursor = regs.count - incomingWords
        for value in args {
            guard cursor + (value.isWide ? 2 : 1) <= regs.count else {
                throw VMError.verify("register file too small for arguments of \(dex.methodIds[method.methodIndex].name)")
            }
            regs[cursor] = value
            if value.isWide { regs[cursor + 1] = value }
            cursor += value.isWide ? 2 : 1
        }

        var pc = 0
        var pendingException: RVal?

        while pc < code.insnsCount {
            guard remainingInstructions > 0 else { throw VMError.budgetExceeded(limit: maxInstructions) }
            remainingInstructions -= 1
            if remainingInstructions & 0x3FF == 0, cancelled() { throw VMError.cancelled }

            do {
                pc = try step(pc, &regs, &pendingException, def, method, code)
            } catch let ret as FrameReturn {
                return try validatedReturn(ret.value, prototype: ref.prototype, context: ref.signature)
            } catch let thrown as DEXThrowable {
                guard let handler = Self.handler(for: thrown.value, at: pc, in: tries) else { throw thrown }
                pendingException = thrown.value
                pc = handler
            }
        }
        throw VMError.verify("method \(dex.methodIds[method.methodIndex].name) fell off the end of its code item")
    }

    static func handler(for value: RVal, at pc: Int, in tries: [DexTryBlock]) -> Int? {
        for t in tries where pc >= t.startAddress && pc < t.endAddress {
            for h in t.handlers {
                if h.type == nil || thrownValue(value, isCaughtBy: h.type!) {
                    return h.address
                }
            }
        }
        return nil
    }

    static func thrownValue(_ value: RVal, isCaughtBy descriptor: String) -> Bool {
        switch descriptor {
        case "Ljava/lang/Throwable;", "Ljava/lang/Exception;", "Ljava/lang/RuntimeException;",
             "Ljava/lang/Error;", "Ljava/lang/Object;":
            return true // approximation until the class hierarchy exists
        default:
            if case let .obj(o) = value { return o.dexType == descriptor }
            return false
        }
    }

    // MARK: - Safe table access

    private func stringAt(_ idx: Int) throws -> String {
        guard idx >= 0, idx < dex.strings.count else { throw VMError.verify("string index \(idx)") }
        return dex.strings[idx]
    }
    private func typeAt(_ idx: Int) throws -> String {
        guard idx >= 0, idx < dex.typeDescriptors.count else { throw VMError.verify("type index \(idx)") }
        return dex.typeDescriptors[idx]
    }
    private func fieldAt(_ idx: Int) throws -> DexFile.FieldRef {
        guard idx >= 0, idx < dex.fieldIds.count else { throw VMError.verify("field index \(idx)") }
        return dex.fieldIds[idx]
    }

    // MARK: - One instruction

    /// Reads up to `count` instruction code units at `pc` (speculative reads
    /// past the instruction are safe: bounded by the code item).
    private func readUnits(_ pc: Int, _ code: DexFile.CodeItem, count: Int) throws -> [UInt16] {
        guard pc >= 0, pc < code.insnsCount else {
            throw VMError.verify("instruction address \(pc) outside code item")
        }
        var out: [UInt16] = []
        out.reserveCapacity(count)
        for i in 0..<count where pc + i < code.insnsCount {
            let off = code.insnsOffset + (pc + i) * 2
            guard off >= 0, off + 1 < dex.source.count else {
                throw VMError.verify("truncated instruction at address \(pc + i)")
            }
            out.append(UInt16(dex.source[off]) | UInt16(dex.source[off + 1]) << 8)
        }
        while out.count < count { out.append(0) }
        return out
    }

    private func step(_ pc0: Int, _ regs: inout [RVal], _ pendingException: inout RVal?, _ def: DexFile.ClassDef,
                      _ method: DexFile.EncodedMethod, _ code: DexFile.CodeItem) throws -> Int {
        let pc = pc0
        let u = try readUnits(pc, code, count: 5)
        let op = UInt8(u[0] & 0xFF)
        let reference = dex.methodIds[method.methodIndex]
        trace?(
            "depth=\(depth) \(reference.declaringClass)->\(reference.signature) "
                + "pc=\(pc) op=0x\(String(op, radix: 16)) "
                + "u=\(u.prefix(3).map { String($0, radix: 16) }) regs=\(regs.map { short($0) })"
        )

        // Bounds-safe register access: malformed streams or unsupported
        // instruction sequences must degrade to nulls, never crash the host.
        func reg(_ i: Int) -> RVal {
            i >= 0 && i < regs.count ? regs[i] : .null
        }
        func setReg(_ i: Int, _ v: RVal) {
            guard i >= 0, i < regs.count else { return }
            regs[i] = v
            if v.isWide, i + 1 < regs.count { regs[i + 1] = v }
        }
        func i32(_ i: Int) -> Int32 { if case let .int(v) = reg(i) { return v }; return 0 }
        func i64(_ i: Int) -> Int64 { if case let .long(v) = reg(i) { return v }; return 0 }
        func f32(_ i: Int) -> Float { if case let .float(v) = reg(i) { return v }; return 0 }
        func f64(_ i: Int) -> Double { if case let .double(v) = reg(i) { return v }; return 0 }
        func obj(_ i: Int) throws -> ObjInstance {
            guard case let .obj(o) = reg(i) else { throw DEXThrowable(HostBridge.string("NullPointerException")) }
            return o
        }
        func arr(_ i: Int) throws -> ArrInstance {
            guard case let .arr(a) = reg(i) else { throw DEXThrowable(HostBridge.string("NullPointerException")) }
            return a
        }

        switch op {
        // ---- nop / moves (0x00–0x0d) ----
        case 0x00: return pc + 1
        case 0x01, 0x04, 0x07: // move[-wide|-object] vA, vB (12x)
            setReg(Int(u[0] >> 8 & 0x0F), reg(Int(u[0] >> 12))); return pc + 1
        case 0x02, 0x05, 0x08: // .../from16 vAA, vBBBB (22x)
            setReg(Int(u[0] >> 8), reg(Int(u[1]))); return pc + 2
        case 0x03, 0x06, 0x09: // .../16 (32x)
            setReg(Int(u[1]), reg(Int(u[2]))); return pc + 3
        case 0x0a, 0x0b, 0x0c: // move-result[-wide|-object] vAA (11x)
            setReg(Int(u[0] >> 8), lastResult); return pc + 1
        case 0x0d: // move-exception vAA
            guard let exception = pendingException else {
                throw VMError.verify("move-exception outside an exception handler")
            }
            setReg(Int(u[0] >> 8), exception)
            pendingException = nil
            return pc + 1

        // ---- returns (0x0e–0x11) ----
        case 0x0e: throw FrameReturn(value: .null)
        case 0x0f, 0x10, 0x11: throw FrameReturn(value: reg(Int(u[0] >> 8)))

        // ---- constants (0x12–0x1c) ----
        case 0x12: // const/4 vA, #+B — B is a signed nibble
            let raw = Int32((u[0] >> 12) & 0x0F)
            setReg(Int(u[0] >> 8 & 0x0F), .int((raw & 0x08) == 0 ? raw : raw - 16))
            return pc + 1
        case 0x13: // const/16 vAA, #+BBBB
            setReg(Int(u[0] >> 8), .int(Int32(Int16(bitPattern: u[1])))); return pc + 2
        case 0x14: return { // const vAA, #+BBBBBBBB
            let v = UInt32(u[1]) | UInt32(u[2]) << 16
            setReg(Int(u[0] >> 8), .int(Int32(bitPattern: v))); return pc + 3
        }()
        case 0x15: // const/high16
            setReg(Int(u[0] >> 8), .int(Int32(bitPattern: UInt32(u[1]) << 16))); return pc + 2
        case 0x16: // const-wide/16
            setReg(Int(u[0] >> 8), .long(Int64(Int16(bitPattern: u[1])))); return pc + 2
        case 0x17: // const-wide/32
            let bits = UInt32(u[1]) | UInt32(u[2]) << 16
            setReg(Int(u[0] >> 8), .long(Int64(Int32(bitPattern: bits)))); return pc + 3
        case 0x18: return { // const-wide vAA, #+BBBBBBBBBBBBBBBB
            let lo = UInt32(u[1]) | UInt32(u[2]) << 16
            let hi = UInt32(u[3]) | UInt32(u[4]) << 16
            setReg(Int(u[0] >> 8), .long(Int64(bitPattern: UInt64(hi) << 32 | UInt64(lo))))
            return pc + 5
        }()
        case 0x19: // const-wide/high16
            setReg(Int(u[0] >> 8), .long(Int64(bitPattern: UInt64(u[1]) << 48))); return pc + 2
        case 0x1a: // const-string vAA, string@BBBB
            setReg(Int(u[0] >> 8), Self.javaString(try stringAt(Int(u[1])))); return pc + 2
        case 0x1b: return try { // const-string/jumbo
            let idx = Int(UInt32(u[1]) | UInt32(u[2]) << 16)
            setReg(Int(u[0] >> 8), Self.javaString(try stringAt(idx))); return pc + 3
        }()
        case 0x1c: // const-class
            let desc = try typeAt(Int(u[1]))
            setReg(Int(u[0] >> 8), .obj(ObjInstance(dexType: "Ljava/lang/Class;", payload: desc, isHost: true)))
            return pc + 2

        case 0x1d, 0x1e: return pc + 1 // monitor-enter/exit (single-threaded M1)

        case 0x1f: return pc + 2 // category-verified; exact hierarchy check remains M1 work
        case 0x20: return try { // instance-of vA, vB, type@CCCC
            let target = try typeAt(Int(u[1]))
            let result = Self.typeCheck(reg(Int(u[0] >> 12)), ofType: target)
            setReg(Int(u[0] >> 8 & 0x0F), .int(result ? 1 : 0)); return pc + 2
        }()
        case 0x21: return try { // array-length vA, vB
            let a = try arr(Int(u[0] >> 12))
            setReg(Int(u[0] >> 8 & 0x0F), .int(Int32(a.elements.count))); return pc + 1
        }()
        case 0x22: return try { // new-instance vAA, type@BBBB
            let desc = try typeAt(Int(u[1]))
            setReg(Int(u[0] >> 8), try allocate(desc)); return pc + 2
        }()
        case 0x23: return try { // new-array vA, vB, type@CCCC
            let count = i32(Int(u[0] >> 12))
            let elem = String(try typeAt(Int(u[1])).dropFirst())
            guard count >= 0 else { throw DEXThrowable(HostBridge.string("NegativeArraySizeException")) }
            guard count <= 1_000_000 else { throw VMError.verify("array size \(count) exceeds runtime limit") }
            let fill = defaultValue(for: elem)
            setReg(Int(u[0] >> 8 & 0x0F), .arr(ArrInstance(elemDescriptor: elem, elements: [RVal](repeating: fill, count: Int(count)))))
            return pc + 2
        }()
        case 0x24: return try { // filled-new-array {vC..vG}, type@CCCC
            let count = Int(u[0] >> 12)
            guard count <= 5 else { throw VMError.verify("filled-new-array register count \(count)") }
            let g = Int(u[0] >> 8 & 0x0F)
            var indices = [Int(u[2] & 0x0F), Int(u[2] >> 4 & 0x0F), Int(u[2] >> 8 & 0x0F), Int(u[2] >> 12)]
            if count == 5 { indices.append(g) } else { indices = Array(indices.prefix(count)) }
            let elem = String(try typeAt(Int(u[1])).dropFirst())
            lastResult = .arr(ArrInstance(elemDescriptor: elem, elements: indices.map(reg)))
            return pc + 3
        }()
        case 0x25: return try { // filled-new-array/range {vCCCC .. vNNNN}
            let count = Int(u[0] >> 8)
            let start = Int(u[2])
            let elem = String(try typeAt(Int(u[1])).dropFirst())
            lastResult = .arr(ArrInstance(elemDescriptor: elem, elements: (0..<count).map { reg(start + $0) }))
            return pc + 3
        }()
        case 0x26: return try { // fill-array-data vAA, +BBBBBBBB
            let off = Int(Int32(bitPattern: UInt32(u[1]) | UInt32(u[2]) << 16))
            var a = try arr(Int(u[0] >> 8))
            try fillArrayData(into: &a, payloadAddr: pc + off, code: code)
            setReg(Int(u[0] >> 8), .arr(a)); return pc + 3
        }()
        case 0x27: // throw vAA
            throw DEXThrowable(reg(Int(u[0] >> 8)))

        // ---- goto / switch (0x28–0x2c) ----
        case 0x28: return pc + Int(Int8(bitPattern: UInt8(u[0] >> 8)))
        case 0x29: return pc + Int(Int16(bitPattern: u[1]))
        case 0x2a: return pc + Int(Int32(bitPattern: UInt32(u[1]) | UInt32(u[2]) << 16))
        case 0x2b: return try { // packed-switch vAA, +payload
            let off = Int(Int32(bitPattern: UInt32(u[1]) | UInt32(u[2]) << 16))
            let target = try packedSwitchTarget(test: i32(Int(u[0] >> 8)), payloadAddr: pc + off, code: code)
            return target.map { pc + $0 } ?? pc + 3
        }()
        case 0x2c: return try { // sparse-switch
            let off = Int(Int32(bitPattern: UInt32(u[1]) | UInt32(u[2]) << 16))
            let target = try sparseSwitchTarget(test: i32(Int(u[0] >> 8)), payloadAddr: pc + off, code: code)
            return target.map { pc + $0 } ?? pc + 3
        }()

        // ---- cmp (0x2d–0x31): vAA ← cmp(vBB, vCC) ----
        case 0x2d: setReg(Int(u[0] >> 8), .int(javaCmpF(Double(f32(Int(u[1] & 0xFF))), Double(f32(Int(u[1] >> 8))), nanIsLess: true))); return pc + 2
        case 0x2e: setReg(Int(u[0] >> 8), .int(javaCmpF(Double(f32(Int(u[1] & 0xFF))), Double(f32(Int(u[1] >> 8))), nanIsLess: false))); return pc + 2
        case 0x2f: setReg(Int(u[0] >> 8), .int(javaCmpF(f64(Int(u[1] & 0xFF)), f64(Int(u[1] >> 8)), nanIsLess: true))); return pc + 2
        case 0x30: setReg(Int(u[0] >> 8), .int(javaCmpF(f64(Int(u[1] & 0xFF)), f64(Int(u[1] >> 8)), nanIsLess: false))); return pc + 2
        case 0x31: setReg(Int(u[0] >> 8), .int(javaCmp(i64(Int(u[1] & 0xFF)), i64(Int(u[1] >> 8))))); return pc + 2

        // ---- if-test (0x32–0x37): vA, vB, +CCCC ----
        case 0x32...0x37: // if-test vA, vB, +CCCC (22t: offset in unit 2)
            let a = Int(u[0] >> 8 & 0x0F), b = Int(u[0] >> 12)
            let off = Int(Int16(bitPattern: u[1]))
            let taken: Bool
            switch op {
            case 0x32: taken = javaEquals(reg(a), reg(b))          // if-eq
            case 0x33: taken = !javaEquals(reg(a), reg(b))         // if-ne
            case 0x34: taken = i32(a) < i32(b)                    // if-lt
            case 0x35: taken = i32(a) >= i32(b)                   // if-ge
            case 0x36: taken = i32(a) > i32(b)                    // if-gt
            default:   taken = i32(a) <= i32(b)                   // if-le
            }
            return taken ? pc + off : pc + 2

        // ---- if-*z (0x38–0x3d) ----
        case 0x38...0x3d:
            let a = Int(u[0] >> 8)
            let off = Int(Int16(bitPattern: u[1]))
            let v = reg(a)
            let taken: Bool
            switch op {
            case 0x38: taken = isZero(v)                          // if-eqz
            case 0x39: taken = !isZero(v)                         // if-nez
            case 0x3a: taken = intLessThanZero(v)                 // if-ltz
            case 0x3b: taken = !intLessThanZero(v)                // if-gez
            case 0x3c: taken = intGreaterThanZero(v)              // if-gtz
            default:   taken = !intGreaterThanZero(v)             // if-lez
            }
            return taken ? pc + off : pc + 2

        // ---- aget (0x44–0x4a) ----
        case 0x44...0x4a:
            let a = try arr(Int(u[1] & 0xFF))
            let idx = i32(Int(u[1] >> 8))
            let value = try element(a, at: idx)
            setReg(Int(u[0] >> 8), value); return pc + 2

        // ---- aput (0x4b–0x51) ----
        case 0x4b...0x51:
            let value = reg(Int(u[0] >> 8))
            let a = try arr(Int(u[1] & 0xFF))
            let idx = i32(Int(u[1] >> 8))
            guard idx >= 0, Int(idx) < a.elements.count else {
                throw DEXThrowable(HostBridge.string("ArrayIndexOutOfBoundsException: \(idx)"))
            }
            a.elements[Int(idx)] = value; return pc + 2

        // ---- iget/iput (0x52–0x5f) ----
        case 0x52...0x5f: // 22c: field index in unit 2 (u[1])
            let a = Int(u[0] >> 8 & 0x0F), b = Int(u[0] >> 12)
            let field = try fieldAt(Int(u[1]))
            let target = try obj(b)
            if op <= 0x58 {
                setReg(a, target.fields[field.name] ?? defaultValue(for: field.type))
            } else {
                target.fields[field.name] = reg(a)
            }
            return pc + 2

        // ---- sget/sput (0x60–0x6d) ----
        case 0x60...0x6d:
            let a = Int(u[0] >> 8)
            let field = try fieldAt(Int(u[1]))
            if dex.classIndexByDescriptor[field.declaringClass] != nil {
                try ensureClassInitialized(field.declaringClass)
            }
            let key = "\(field.declaringClass)->\(field.name)"
            if op <= 0x66 {
                setReg(a, dexStatics[key] ?? bridge.staticFields[key] ?? defaultValue(for: field.type))
            } else if dex.classIndexByDescriptor[field.declaringClass] != nil {
                dexStatics[key] = reg(a)
            } else {
                bridge.staticFields[key] = reg(a)
            }
            return pc + 2

        // ---- invoke (0x6e–0x72) ----
        case 0x6e...0x72: return try {
            guard let invocationKind = InvocationKind(opcode: op) else {
                throw VMError.verify("invalid invoke opcode 0x\(String(op, radix: 16))")
            }
            let count = Int(u[0] >> 12)
            guard count <= 5 else { throw VMError.verify("invoke register count \(count)") }
            let g = Int(u[0] >> 8 & 0x0F)
            // 35c: A|G|op, BBBB method index, F|E|D|C registers.
            var indices = [Int(u[2] & 0x0F), Int(u[2] >> 4 & 0x0F), Int(u[2] >> 8 & 0x0F), Int(u[2] >> 12)]
            if count == 5 { indices.append(g) } else { indices = Array(indices.prefix(count)) }
            try invokeRegs(
                methodIndex: Int(u[1]),
                regs: regs,
                indices: indices,
                kind: invocationKind,
                callerOutsSize: Int(code.outsSize)
            )
            return pc + 3
        }()

        // ---- invoke/range (0x74–0x78) ----
        case 0x74...0x78: return try {
            guard let invocationKind = InvocationKind(opcode: op) else {
                throw VMError.verify("invalid invoke opcode 0x\(String(op, radix: 16))")
            }
            // 3rc unit order: AA|op, method index, first register.
            let count = Int(u[0] >> 8)
            let start = Int(u[2])
            let indices = Array(start..<(start + count))
            try invokeRegs(
                methodIndex: Int(u[1]),
                regs: regs,
                indices: indices,
                kind: invocationKind,
                callerOutsSize: Int(code.outsSize)
            )
            return pc + 3
        }()

        // ---- unary (0x7b–0x8f), format 12x: vA ← op vB ----
        case 0x7b...0x8f:
            let dst = Int(u[0] >> 8 & 0x0F)
            let src = Int(u[0] >> 12)
            switch op {
            case 0x7b: setReg(dst, .int(0 &- i32(src)))
            case 0x7c: setReg(dst, .int(~i32(src)))
            case 0x7d: setReg(dst, .long(0 &- i64(src)))
            case 0x7e: setReg(dst, .long(~i64(src)))
            case 0x7f: setReg(dst, .float(-f32(src)))
            case 0x80: setReg(dst, .double(-f64(src)))
            case 0x81: setReg(dst, .long(Int64(i32(src))))
            case 0x82: setReg(dst, .float(Float(i32(src))))
            case 0x83: setReg(dst, .double(Double(i32(src))))
            case 0x84: setReg(dst, .int(Int32(truncatingIfNeeded: i64(src))))
            case 0x85: setReg(dst, .float(Float(i64(src))))
            case 0x86: setReg(dst, .double(Double(i64(src))))
            case 0x87: setReg(dst, .int(javaNarrowToInt(Double(f32(src)))))
            case 0x88: setReg(dst, .long(javaNarrowToLong(Double(f32(src)))))
            case 0x89: setReg(dst, .double(Double(f32(src))))
            case 0x8a: setReg(dst, .int(javaNarrowToInt(f64(src))))
            case 0x8b: setReg(dst, .long(javaNarrowToLong(f64(src))))
            case 0x8c: setReg(dst, .float(Float(f64(src))))
            case 0x8d: setReg(dst, .int(Int32(Int8(truncatingIfNeeded: i32(src)))))
            case 0x8e: setReg(dst, .int(Int32(UInt16(truncatingIfNeeded: i32(src)))))
            default:   setReg(dst, .int(Int32(Int16(truncatingIfNeeded: i32(src)))))
            }
            return pc + 1

        // ---- binop 23x (0x90–0xaf): vAA ← vBB op vCC ----
        case 0x90...0xaf: // 23x: two units (AA|op, BB|CC)
            setReg(Int(u[0] >> 8), try binop(op, reg(Int(u[1] & 0xFF)), reg(Int(u[1] >> 8))))
            return pc + 2

        // ---- binop/2addr 12x (0xb0–0xcf): vA ← vA op vB ----
        case 0xb0...0xcf:
            let dst = Int(u[0] >> 8 & 0x0F)
            setReg(dst, try binop(UInt8(op - 0x20), reg(dst), reg(Int(u[0] >> 12))))
            return pc + 1

        // ---- binop/lit16 22s (0xd0–0xd7): vA ← vB op #+CCCC ----
        case 0xd0...0xd7:
            let dst = Int(u[0] >> 8 & 0x0F), src = Int(u[0] >> 12)
            setReg(dst, try binopLiteral(op, reg(src), Int32(Int16(bitPattern: u[1]))))
            return pc + 2

        // ---- binop/lit8 22b (0xd8–0xe2): vAA ← vBB op #+CC ----
        case 0xd8...0xe2:
            let dst = Int(u[0] >> 8), src = Int(u[1] & 0xFF)
            setReg(dst, try binopLiteral(op, reg(src), Int32(Int8(bitPattern: UInt8(u[1] >> 8)))))
            return pc + 2

        default:
            throw VMError.verify("unsupported opcode 0x\(String(op, radix: 16)) at pc \(pc) in \(dex.methodIds[method.methodIndex].name)")
        }
    }

    private func short(_ v: RVal) -> String {
        switch v {
        case .null: return "null"
        case let .int(i): return "i:\(i)"
        case let .long(l): return "l:\(l)"
        case let .float(f): return "f:\(f)"
        case let .double(d): return "d:\(d)"
        case .obj: return "obj"
        case .arr(let a): return "arr[\(a.elements.count)]"
        case .host: return "host"
        }
    }

    // MARK: - if-*z predicates

    private func isZero(_ v: RVal) -> Bool {
        switch v {
        case .null: return true
        case let .int(i): return i == 0
        default: return false
        }
    }
    private func intLessThanZero(_ v: RVal) -> Bool {
        if case let .int(i) = v { return i < 0 }
        return false
    }
    private func intGreaterThanZero(_ v: RVal) -> Bool {
        if case let .int(i) = v { return i > 0 }
        return !isZero(v) // objects: non-null ⇒ > 0
    }

    private func javaEquals(_ a: RVal, _ b: RVal) -> Bool {
        switch (a, b) {
        case let (.int(x), .int(y)): return x == y
        case let (.long(x), .long(y)): return x == y
        case let (.obj(x), .obj(y)): return x === y
        case let (.arr(x), .arr(y)): return x === y
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: - allocation & element access

    private func allocate(_ descriptor: String) throws -> RVal {
        if let defIndex = dex.classIndexByDescriptor[descriptor] {
            try ensureClassInitialized(descriptor)
            let d = dex.classDefs[defIndex]
            let obj = ObjInstance(dexType: descriptor)
            for f in d.instanceFields {
                let field = dex.fieldIds[f.fieldIndex]
                obj.fields[field.name] = defaultValue(for: field.type)
            }
            return .obj(obj)
        }
        if let factory = bridge.objectFactories[descriptor] {
            return try factory(self)
        }
        // Unknown host class: object with no surface; first method call on it
        // produces a precise UNRESOLVED HOST METHOD report.
        return .obj(ObjInstance(dexType: descriptor, isHost: true))
    }

    private func element(_ a: ArrInstance, at idx: Int32) throws -> RVal {
        guard idx >= 0, Int(idx) < a.elements.count else {
            throw DEXThrowable(HostBridge.string("ArrayIndexOutOfBoundsException: \(idx)"))
        }
        return a.elements[Int(idx)]
    }

    static func javaString(_ s: String) -> RVal {
        .obj(ObjInstance(dexType: "Ljava/lang/String;", payload: s, isHost: true))
    }

    // MARK: - invocation

    /// Invoke with explicit argument register words. The method prototype, not
    /// the runtime value tags, determines how those words are grouped.
    private func invokeRegs(methodIndex: Int, regs: [RVal], indices: [Int],
                            kind: InvocationKind, callerOutsSize: Int) throws {
        guard methodIndex >= 0, methodIndex < dex.methodIds.count else { throw VMError.verify("method index \(methodIndex)") }
        let ref = dex.methodIds[methodIndex]
        let isStaticInvocation = kind.isStatic
        let hasReceiver = !isStaticInvocation
        let expectedWords = ref.prototype.parameterWordCount + (hasReceiver ? 1 : 0)
        guard indices.count == expectedWords else {
            throw VMError.verify(
                "\(ref.signature) expects \(expectedWords) invoke register words, got \(indices.count)"
            )
        }
        guard indices.count <= callerOutsSize else {
            throw VMError.verify(
                "\(ref.signature) uses \(indices.count) outgoing words but caller outs_size is \(callerOutsSize)"
            )
        }

        var args: [RVal] = []
        args.reserveCapacity(ref.prototype.parameters.count + (hasReceiver ? 1 : 0))
        var word = 0

        func value(at wordOffset: Int, descriptor: String, label: String) throws -> RVal {
            let idx = indices[wordOffset]
            guard idx >= 0, idx < regs.count else { throw VMError.verify("invoke register v\(idx) outside register file") }
            let value = regs[idx]
            guard Self.matches(value, descriptor: descriptor) else {
                throw VMError.verify("\(ref.signature) \(label) at v\(idx) does not match \(descriptor)")
            }
            let width = descriptor == "J" || descriptor == "D" ? 2 : 1
            if width == 2 {
                guard wordOffset + 1 < indices.count, indices[wordOffset + 1] == idx + 1 else {
                    throw VMError.verify("wide \(ref.signature) \(label) at v\(idx) is missing its second register word")
                }
                guard idx + 1 < regs.count else {
                    throw VMError.verify("wide \(ref.signature) \(label) exceeds the register file")
                }
            }
            if Self.isReferenceDescriptor(descriptor), Self.isNullReference(value) { return .null }
            return value
        }

        if hasReceiver {
            let receiver = try value(at: 0, descriptor: "Ljava/lang/Object;", label: "receiver")
            if receiver.isNull {
                throw DEXThrowable(HostBridge.string("NullPointerException"))
            }
            args.append(receiver)
            word = 1
        }
        for (argumentIndex, descriptor) in ref.prototype.parameters.enumerated() {
            args.append(try value(at: word, descriptor: descriptor, label: "argument \(argumentIndex)"))
            word += descriptor == "J" || descriptor == "D" ? 2 : 1
        }

        let receiverDescriptor = args.first.flatMap(Self.runtimeDescriptor)
        if kind.usesReceiverDispatch, let receiverDescriptor,
           let assignable = knownAssignable(receiverDescriptor, to: ref.declaringClass),
           !assignable {
            throw VMError.verify(
                "\(ref.signature) receiver \(receiverDescriptor) is not assignable to \(ref.declaringClass)"
            )
        }

        if kind.usesReceiverDispatch, let receiverDescriptor,
           let (targetDef, targetMethod) = try resolveDexVirtualMethod(
               receiverDescriptor: receiverDescriptor,
               name: ref.name,
               prototype: ref.prototype.descriptor
           ) {
            lastResult = try execute(def: targetDef, method: targetMethod, args: args)
            return
        }

        if kind.usesReceiverDispatch, let receiverDescriptor,
           let host = bridge.resolve(
               class: receiverDescriptor,
               ref.name,
               prototype: ref.prototype.descriptor,
               isStatic: false
           ) {
            lastResult = try validatedReturn(
                try host(self, args),
                prototype: ref.prototype,
                context: ref.signature
            )
            return
        }

        // Interpret only when the method's declaring class is actually
        // defined in this DEX; misparsed class_data indices must never
        // shadow host implementations (e.g. java.lang.Object.<init>).
        if dex.classIndexByDescriptor[ref.declaringClass] != nil,
           let (def, encoded) = dexMethodTable[methodIndex] {
            let encodedIsStatic = encoded.accessFlags & 0x8 != 0
            guard encodedIsStatic == isStaticInvocation else {
                throw VMError.verify(
                    "\(ref.signature) invoked as \(isStaticInvocation ? "static" : "instance") but encoded method is \(encodedIsStatic ? "static" : "instance")"
                )
            }
            if isStaticInvocation, ref.name != "<clinit>" {
                try ensureClassInitialized(ref.declaringClass)
            }
            lastResult = try execute(def: def, method: encoded, args: args)
            return
        }
        if let host = bridge.resolve(ref, isStatic: isStaticInvocation) {
            lastResult = try validatedReturn(
                try host(self, args),
                prototype: ref.prototype,
                context: ref.signature
            )
            return
        }
        throw VMError.unresolvedMethod(class: ref.declaringClass, signature: ref.signature)
    }

    private static func runtimeDescriptor(_ value: RVal) -> String? {
        switch value {
        case let .obj(object): return object.dexType
        case let .arr(array): return "[" + array.elemDescriptor
        case let .host(box):
            return "L" + box.className.replacingOccurrences(of: ".", with: "/") + ";"
        case .null, .int, .long, .float, .double: return nil
        }
    }

    /// Returns nil when the receiver's hierarchy leaves the parsed DEX and
    /// assignability therefore cannot be proven locally.
    private func knownAssignable(_ candidate: String, to expected: String) -> Bool? {
        guard dex.classIndexByDescriptor[candidate] != nil else { return nil }
        var pending = [candidate]
        var visited: Set<String> = []
        var reachedExternalType = false

        while let descriptor = pending.popLast() {
            if descriptor == expected { return true }
            guard visited.insert(descriptor).inserted else { continue }
            guard let classIndex = dex.classIndexByDescriptor[descriptor] else {
                reachedExternalType = true
                continue
            }
            let def = dex.classDefs[classIndex]
            if def.superclassIndex >= 0,
               def.superclassIndex < dex.typeDescriptors.count {
                pending.append(dex.typeDescriptors[def.superclassIndex])
            }
            for interfaceIndex in def.interfaceIndices
                where interfaceIndex >= 0 && interfaceIndex < dex.typeDescriptors.count {
                pending.append(dex.typeDescriptors[interfaceIndex])
            }
        }
        return reachedExternalType ? nil : false
    }

    /// Selects the most-specific DEX override for invoke-virtual/interface.
    /// Exact name + prototype identity is retained at every hierarchy level.
    private func resolveDexVirtualMethod(
        receiverDescriptor: String,
        name: String,
        prototype: String
    ) throws -> (DexFile.ClassDef, DexFile.EncodedMethod)? {
        var current: String? = receiverDescriptor
        var visited: Set<String> = []

        while let descriptor = current {
            guard visited.insert(descriptor).inserted else {
                throw VMError.verify("cyclic class hierarchy while dispatching \(name)\(prototype)")
            }
            guard let classIndex = dex.classIndexByDescriptor[descriptor] else { return nil }
            let def = dex.classDefs[classIndex]
            let matches = def.virtualMethods.filter {
                let candidate = dex.methodIds[$0.methodIndex]
                return candidate.name == name && candidate.prototype.descriptor == prototype
            }
            guard matches.count <= 1 else {
                throw VMError.verify("duplicate virtual method \(descriptor).\(name)\(prototype)")
            }
            if let method = matches.first {
                guard method.accessFlags & 0x8 == 0 else {
                    throw VMError.verify("static method encoded in virtual method list: \(descriptor).\(name)\(prototype)")
                }
                return (def, method)
            }
            guard def.superclassIndex >= 0,
                  def.superclassIndex < dex.typeDescriptors.count else { return nil }
            current = dex.typeDescriptors[def.superclassIndex]
        }
        return nil
    }

    // MARK: - arithmetic

    private func binop(_ op: UInt8, _ l: RVal, _ r: RVal) throws -> RVal {
        func i32(_ v: RVal) -> Int32 { if case let .int(x) = v { return x }; return 0 }
        func i64(_ v: RVal) -> Int64 { if case let .long(x) = v { return x }; return 0 }
        func f32(_ v: RVal) -> Float { if case let .float(x) = v { return x }; return 0 }
        func f64(_ v: RVal) -> Double { if case let .double(x) = v { return x }; return 0 }
        func arith(_ a: Int32, _ b: Int32) throws -> Int32 {
            switch op {
            case 0x90: return a &+ b
            case 0x91: return a &- b
            case 0x92: return a &* b
            case 0x93: return try javaDivide(a, by: b)
            case 0x94: return try javaRemainder(a, by: b)
            case 0x95: return a & b
            case 0x96: return a | b
            case 0x97: return a ^ b
            case 0x98: return a << (b & 31)
            case 0x99: return a >> (b & 31)
            case 0x9a: return Int32(bitPattern: UInt32(bitPattern: a) >> (b & 31))
            default: throw VMError.verify("bad int binop")
            }
        }
        switch op {
        case 0x90...0x9a:
            return .int(try arith(i32(l), i32(r)))
        case 0x9b...0xa2:
            let a = i64(l), b = i64(r)
            switch op {
            case 0x9b: return .long(a &+ b)
            case 0x9c: return .long(a &- b)
            case 0x9d: return .long(a &* b)
            case 0x9e: return .long(try javaDivide(a, by: b))
            case 0x9f: return .long(try javaRemainder(a, by: b))
            case 0xa0: return .long(a & b)
            case 0xa1: return .long(a | b)
            default:   return .long(a ^ b)
            }
        case 0xa3...0xa5:
            let a = i64(l), distance = Int(i32(r) & 63)
            if op == 0xa3 { return .long(a << distance) }
            if op == 0xa4 { return .long(a >> distance) }
            return .long(Int64(bitPattern: UInt64(bitPattern: a) >> distance))
        case 0xa6...0xaa:
            let a = f32(l), b = f32(r)
            switch op {
            case 0xa6: return .float(a + b)
            case 0xa7: return .float(a - b)
            case 0xa8: return .float(a * b)
            case 0xa9: return .float(a / b)
            default:   return .float(a.truncatingRemainder(dividingBy: b))
            }
        case 0xab...0xaf:
            let a = f64(l), b = f64(r)
            switch op {
            case 0xab: return .double(a + b)
            case 0xac: return .double(a - b)
            case 0xad: return .double(a * b)
            case 0xae: return .double(a / b)
            default:   return .double(a.truncatingRemainder(dividingBy: b))
            }
        default:
            throw VMError.verify("bad binop 0x\(String(op, radix: 16))")
        }
    }

    /// Literal ops: lit16 family 0xd0–0xd7, lit8 family 0xd8–0xe2.
    /// rsub is REVERSE subtract: result = lit - value.
    private func binopLiteral(_ op: UInt8, _ l: RVal, _ lit: Int32) throws -> RVal {
        guard case let .int(a) = l else { throw VMError.verify("binop-lit on non-int") }
        switch op {
        case 0xd0, 0xd8: return .int(a &+ lit)
        case 0xd1, 0xd9: return .int(lit &- a)
        case 0xd2, 0xda: return .int(a &* lit)
        case 0xd3, 0xdb: return .int(try javaDivide(a, by: lit))
        case 0xd4, 0xdc: return .int(try javaRemainder(a, by: lit))
        case 0xd5, 0xdd: return .int(a & lit)
        case 0xd6, 0xde: return .int(a | lit)
        case 0xd7, 0xdf: return .int(a ^ lit)
        case 0xe0: return .int(a << Int(lit & 31))
        case 0xe1: return .int(a >> Int(lit & 31))
        case 0xe2: return .int(Int32(bitPattern: UInt32(bitPattern: a) >> Int(lit & 31)))
        default: throw VMError.verify("bad lit-op 0x\(String(op, radix: 16))")
        }
    }

    private func javaDivide(_ a: Int32, by b: Int32) throws -> Int32 {
        guard b != 0 else { throw DEXThrowable(HostBridge.string("ArithmeticException: / by zero")) }
        return a == .min && b == -1 ? .min : a / b
    }

    private func javaRemainder(_ a: Int32, by b: Int32) throws -> Int32 {
        guard b != 0 else { throw DEXThrowable(HostBridge.string("ArithmeticException: / by zero")) }
        return a == .min && b == -1 ? 0 : a % b
    }

    private func javaDivide(_ a: Int64, by b: Int64) throws -> Int64 {
        guard b != 0 else { throw DEXThrowable(HostBridge.string("ArithmeticException: / by zero")) }
        return a == .min && b == -1 ? .min : a / b
    }

    private func javaRemainder(_ a: Int64, by b: Int64) throws -> Int64 {
        guard b != 0 else { throw DEXThrowable(HostBridge.string("ArithmeticException: / by zero")) }
        return a == .min && b == -1 ? 0 : a % b
    }

    // MARK: - switches / array data payloads

    private func u16(_ addr: Int, _ code: DexFile.CodeItem) throws -> UInt16 {
        guard addr >= 0, addr < code.insnsCount else {
            throw VMError.verify("payload address \(addr) outside code item")
        }
        let off = code.insnsOffset + addr * 2
        guard off >= 0, off + 1 < dex.source.count else {
            throw VMError.verify("truncated payload at address \(addr)")
        }
        return UInt16(dex.source[off]) | UInt16(dex.source[off + 1]) << 8
    }
    private func i32payload(_ addr: Int, _ code: DexFile.CodeItem) throws -> Int32 {
        Int32(bitPattern: UInt32(try u16(addr, code)) | UInt32(try u16(addr + 1, code)) << 16)
    }

    private func packedSwitchTarget(test: Int32, payloadAddr: Int, code: DexFile.CodeItem) throws -> Int? {
        guard try u16(payloadAddr, code) == 0x0100 else { throw VMError.verify("bad packed-switch payload") }
        let size = Int(try u16(payloadAddr + 1, code))
        guard size > 0 else { return nil }
        guard size <= (code.insnsCount - payloadAddr - 4) / 2 else {
            throw VMError.verify("truncated packed-switch payload")
        }
        let firstKey = try i32payload(payloadAddr + 2, code)
        let delta = Int64(test) - Int64(firstKey)
        guard delta >= 0, delta < Int64(size) else { return nil }
        return Int(try i32payload(payloadAddr + 4 + Int(delta) * 2, code))
    }

    private func sparseSwitchTarget(test: Int32, payloadAddr: Int, code: DexFile.CodeItem) throws -> Int? {
        guard try u16(payloadAddr, code) == 0x0200 else { throw VMError.verify("bad sparse-switch payload") }
        let size = Int(try u16(payloadAddr + 1, code))
        guard size <= (code.insnsCount - payloadAddr - 2) / 4 else {
            throw VMError.verify("truncated sparse-switch payload")
        }
        for i in 0..<size where try i32payload(payloadAddr + 2 + i * 2, code) == test {
            return Int(try i32payload(payloadAddr + 2 + size * 2 + i * 2, code))
        }
        return nil
    }

    private func fillArrayData(into arr: inout ArrInstance, payloadAddr: Int, code: DexFile.CodeItem) throws {
        guard try u16(payloadAddr, code) == 0x0300 else { throw VMError.verify("bad array-data payload") }
        let width = Int(try u16(payloadAddr + 1, code))
        guard [1, 2, 4, 8].contains(width) else { throw VMError.verify("array-data width \(width)") }
        let count = Int(UInt32(try u16(payloadAddr + 2, code)) | UInt32(try u16(payloadAddr + 3, code)) << 16)
        guard count == arr.elements.count else { throw VMError.verify("fill-array-data size mismatch") }
        let dataStart = payloadAddr + 4
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: width)
        guard !overflow, dataStart >= 0, (byteCount + 1) / 2 <= code.insnsCount - dataStart else {
            throw VMError.verify("truncated array-data payload")
        }
        for i in 0..<count {
            let addr = dataStart + (i * width + 1) / 2
            let raw: RVal
            switch width {
            case 1:
                let unit = try u16(dataStart + i / 2, code)
                raw = .int(Int32(UInt8(truncatingIfNeeded: unit >> (8 * (i % 2)))))
            case 2: raw = .int(Int32(bitPattern: UInt32(try u16(addr, code))))
            case 4: raw = .int(try i32payload(addr, code))
            case 8:
                let lo = UInt64(UInt32(try u16(addr, code)) | UInt32(try u16(addr + 1, code)) << 16)
                let hi = UInt64(UInt32(try u16(addr + 2, code)) | UInt32(try u16(addr + 3, code)) << 16)
                raw = .long(Int64(bitPattern: hi << 32 | lo))
            default: preconditionFailure("validated array-data width")
            }
            arr.elements[i] = raw
        }
    }

    // MARK: - type checks / narrowing

    static func typeCheck(_ value: RVal, ofType target: String) -> Bool {
        if value.isNull { return false }
        switch value {
        case let .obj(o):
            if o.dexType == target { return true }
            // Approximation until the host class hierarchy lands (M2).
            switch target {
            case "Ljava/lang/Object;", "Ljava/lang/Throwable;", "Ljava/lang/Exception;",
                 "Ljava/lang/RuntimeException;", "Ljava/lang/Error;", "Ljava/lang/CharSequence;":
                return true
            default: return false
            }
        case .arr: return target.hasPrefix("[")
        default: return false
        }
    }

    private func javaCmp(_ a: Int64, _ b: Int64) -> Int32 { a < b ? -1 : (a == b ? 0 : 1) }
    private func javaCmpF(_ a: Double, _ b: Double, nanIsLess: Bool) -> Int32 {
        if a.isNaN || b.isNaN { return nanIsLess ? -1 : 1 }
        return a < b ? -1 : (a == b ? 0 : 1)
    }
    private func javaNarrowToInt(_ f: Double) -> Int32 {
        if f.isNaN { return 0 }
        if f >= Double(Int32.max) { return Int32.max }
        if f <= Double(Int32.min) { return Int32.min }
        return Int32(f)
    }
    private func javaNarrowToLong(_ f: Double) -> Int64 {
        if f.isNaN { return 0 }
        if f >= Double(Int64.max) { return Int64.max }
        if f <= Double(Int64.min) { return Int64.min }
        return Int64(f)
    }
}

extension RVal {
    var isWide: Bool {
        switch self {
        case .long, .double: return true
        default: return false
        }
    }
}
