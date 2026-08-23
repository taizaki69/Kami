import Foundation

/// Invocation families shared by static verification and runtime dispatch.
enum DexInvocationKind: Equatable {
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

    var usesRuntimeReceiver: Bool {
        switch self {
        case .virtual, .interface: return true
        case .superMethod, .direct, .staticMethod: return false
        }
    }
}

/// Exact method selection over the class and interface definitions present in
/// one DEX. Library boundaries remain explicitly unresolved so the interpreter
/// can defer to `HostBridge` without inventing inheritance relationships.
struct DexMethodResolver {
    struct ResolvedMethod {
        let definition: DexFile.ClassDef
        let method: DexFile.EncodedMethod
    }

    enum Lookup {
        case found(ResolvedMethod)
        case abstract
        case conflict([String])
        case missing
        case unresolved
    }

    private struct Declaration {
        let descriptor: String
        let definition: DexFile.ClassDef
        let method: DexFile.EncodedMethod

        var isAbstract: Bool {
            method.accessFlags & 0x400 != 0
        }

        var hasCode: Bool {
            method.codeOffset != 0
        }
    }

    let dex: DexFile
    let hierarchy: DexTypeHierarchy

    /// Normal virtual dispatch starts at the runtime class and walks its class
    /// chain. Interface defaults do not participate in an invoke-virtual lookup.
    func virtual(
        receiverDescriptor: String,
        name: String,
        prototype: String
    ) throws -> Lookup {
        let chain = try classChain(from: receiverDescriptor)
        if let declaration = try firstClassDeclaration(
            in: chain.definitions,
            name: name,
            prototype: prototype
        ) {
            return lookup(for: declaration)
        }
        return chain.unresolved ? .unresolved : .missing
    }

    /// Interface dispatch first honors concrete/abstract class declarations,
    /// then applies ART's maximally-specific default-method rules. A declaration
    /// in a subinterface masks the same signature in its superinterface even
    /// when the subinterface declaration is abstract.
    func interface(
        receiverDescriptor: String,
        name: String,
        prototype: String
    ) throws -> Lookup {
        let chain = try classChain(from: receiverDescriptor)
        if let declaration = try firstClassDeclaration(
            in: chain.definitions,
            name: name,
            prototype: prototype
        ) {
            return lookup(for: declaration)
        }

        let graph = try interfaceGraph(for: chain.definitions)
        let defaults = try resolveDefaults(
            in: graph.definitions,
            name: name,
            prototype: prototype
        )
        switch defaults {
        case .missing where chain.unresolved || graph.unresolved:
            return .unresolved
        default:
            return defaults
        }
    }

    /// Class invoke-super dispatch is relative to the lexical caller, never to
    /// the runtime receiver and never directly to the method_id's declaring
    /// ancestor. This is the vtable behavior that makes a grandparent method
    /// reference dispatch to an override in the caller's direct superclass.
    func classSuper(
        callerDescriptor: String,
        name: String,
        prototype: String
    ) throws -> Lookup {
        guard let callerIndex = dex.classIndexByDescriptor[callerDescriptor] else {
            return .unresolved
        }
        let caller = dex.classDefs[callerIndex]
        guard caller.superclassIndex >= 0,
              caller.superclassIndex < dex.typeDescriptors.count else {
            return .missing
        }
        return try virtual(
            receiverDescriptor: dex.typeDescriptors[caller.superclassIndex],
            name: name,
            prototype: prototype
        )
    }

    /// DEX 037+ interface invoke-super selects the most-specific declaration in
    /// the referenced interface's own graph. Class overrides and sibling
    /// interfaces intentionally do not participate.
    func interfaceSuper(
        targetInterface: String,
        name: String,
        prototype: String
    ) throws -> Lookup {
        let graph = try interfaceGraph(startingAt: [targetInterface])
        let result = try resolveDefaults(
            in: graph.definitions,
            name: name,
            prototype: prototype
        )
        if case .missing = result, graph.unresolved { return .unresolved }
        return result
    }

    /// Finds the method declaration that a method reference resolves to when
    /// all involved definitions are local. Used for invoke-kind verification.
    func referencedMethod(
        declaringType: String,
        name: String,
        prototype: String,
        kind: DexInvocationKind
    ) throws -> Lookup {
        guard let classIndex = dex.classIndexByDescriptor[declaringType] else {
            return .unresolved
        }
        let definition = dex.classDefs[classIndex]
        switch kind {
        case .direct, .staticMethod:
            let matchingMethods = definition.directMethods.filter {
                self.matches($0, name: name, prototype: prototype)
            }
            guard matchingMethods.count <= 1 else {
                throw duplicateMethodError(declaringType, name: name, prototype: prototype)
            }
            guard let method = matchingMethods.first else { return .missing }
            return lookup(for: Declaration(
                descriptor: declaringType,
                definition: definition,
                method: method
            ))
        case .virtual, .superMethod:
            if definition.accessFlags & 0x200 != 0 {
                return try interfaceSuper(
                    targetInterface: declaringType,
                    name: name,
                    prototype: prototype
                )
            }
            return try virtual(
                receiverDescriptor: declaringType,
                name: name,
                prototype: prototype
            )
        case .interface:
            return try interfaceSuper(
                targetInterface: declaringType,
                name: name,
                prototype: prototype
            )
        }
    }

    private func classChain(
        from descriptor: String
    ) throws -> (definitions: [DexFile.ClassDef], unresolved: Bool) {
        var definitions: [DexFile.ClassDef] = []
        var current: String? = descriptor
        var visited: Set<String> = []
        var unresolved = false

        while let value = current {
            guard visited.insert(value).inserted else {
                throw VMError.verify("cyclic class hierarchy at \(value)")
            }
            guard let classIndex = dex.classIndexByDescriptor[value] else {
                unresolved = !hierarchy.isKnown(value)
                break
            }
            let definition = dex.classDefs[classIndex]
            guard definition.accessFlags & 0x200 == 0 else {
                throw VMError.verify("interface \(value) used as a runtime class")
            }
            definitions.append(definition)
            if definition.superclassIndex >= 0,
               definition.superclassIndex < dex.typeDescriptors.count {
                current = dex.typeDescriptors[definition.superclassIndex]
            } else {
                current = nil
            }
        }
        return (definitions, unresolved)
    }

    private func firstClassDeclaration(
        in definitions: [DexFile.ClassDef],
        name: String,
        prototype: String
    ) throws -> Declaration? {
        for definition in definitions {
            let matchingMethods = definition.virtualMethods.filter {
                self.matches($0, name: name, prototype: prototype)
            }
            guard matchingMethods.count <= 1 else {
                throw duplicateMethodError(definition.descriptor, name: name, prototype: prototype)
            }
            if let method = matchingMethods.first {
                guard method.accessFlags & 0x8 == 0 else {
                    throw VMError.verify(
                        "static method encoded in virtual method list: "
                            + "\(definition.descriptor).\(name)\(prototype)"
                    )
                }
                return Declaration(
                    descriptor: definition.descriptor,
                    definition: definition,
                    method: method
                )
            }
        }
        return nil
    }

    private func interfaceGraph(
        for classes: [DexFile.ClassDef]
    ) throws -> (definitions: [DexFile.ClassDef], unresolved: Bool) {
        var roots: [String] = []
        for definition in classes {
            roots.append(contentsOf: definition.interfaceIndices.compactMap { index in
                index >= 0 && index < dex.typeDescriptors.count
                    ? dex.typeDescriptors[index]
                    : nil
            })
        }
        return try interfaceGraph(startingAt: roots)
    }

    private func interfaceGraph(
        startingAt roots: [String]
    ) throws -> (definitions: [DexFile.ClassDef], unresolved: Bool) {
        var pending = roots
        var visited: Set<String> = []
        var definitions: [DexFile.ClassDef] = []
        var unresolved = false

        while let descriptor = pending.popLast() {
            guard visited.insert(descriptor).inserted else { continue }
            guard let classIndex = dex.classIndexByDescriptor[descriptor] else {
                if !hierarchy.isKnown(descriptor) { unresolved = true }
                continue
            }
            let definition = dex.classDefs[classIndex]
            guard definition.accessFlags & 0x200 != 0 else {
                throw VMError.verify("non-interface \(descriptor) appears in an interface list")
            }
            definitions.append(definition)
            pending.append(contentsOf: definition.interfaceIndices.compactMap { index in
                index >= 0 && index < dex.typeDescriptors.count
                    ? dex.typeDescriptors[index]
                    : nil
            })
        }
        definitions.sort { $0.descriptor < $1.descriptor }
        return (definitions, unresolved)
    }

    private func resolveDefaults(
        in interfaces: [DexFile.ClassDef],
        name: String,
        prototype: String
    ) throws -> Lookup {
        var declarations: [Declaration] = []
        for definition in interfaces {
            let matchingMethods = definition.virtualMethods.filter {
                self.matches($0, name: name, prototype: prototype)
            }
            guard matchingMethods.count <= 1 else {
                throw duplicateMethodError(definition.descriptor, name: name, prototype: prototype)
            }
            if let method = matchingMethods.first {
                guard method.accessFlags & 0x8 == 0 else {
                    throw VMError.verify(
                        "static interface method encoded in virtual method list: "
                            + "\(definition.descriptor).\(name)\(prototype)"
                    )
                }
                declarations.append(Declaration(
                    descriptor: definition.descriptor,
                    definition: definition,
                    method: method
                ))
            }
        }
        guard !declarations.isEmpty else { return .missing }

        let maximal = declarations.filter { candidate in
            !declarations.contains { other in
                other.descriptor != candidate.descriptor
                    && hierarchy.assignability(
                        from: other.descriptor,
                        to: candidate.descriptor,
                        strict: true
                    ) == .yes
            }
        }

        var hasUnknownRelationship = false
        for leftIndex in maximal.indices {
            for rightIndex in maximal.indices where rightIndex > leftIndex {
                let left = maximal[leftIndex].descriptor
                let right = maximal[rightIndex].descriptor
                let leftToRight = hierarchy.assignability(from: left, to: right, strict: true)
                let rightToLeft = hierarchy.assignability(from: right, to: left, strict: true)
                if leftToRight == .unknown || rightToLeft == .unknown {
                    hasUnknownRelationship = true
                }
            }
        }
        if hasUnknownRelationship { return .unresolved }
        if maximal.contains(where: { !$0.isAbstract && !$0.hasCode }) {
            return .unresolved
        }
        let concrete = maximal.filter { !$0.isAbstract && $0.hasCode }
        guard !concrete.isEmpty else { return .abstract }
        if concrete.count == 1, let declaration = concrete.first {
            return .found(ResolvedMethod(
                definition: declaration.definition,
                method: declaration.method
            ))
        }

        return .conflict(concrete.map(\.descriptor).sorted())
    }

    private func lookup(for declaration: Declaration) -> Lookup {
        if declaration.isAbstract { return .abstract }
        if !declaration.hasCode { return .unresolved }
        return .found(ResolvedMethod(
            definition: declaration.definition,
            method: declaration.method
        ))
    }

    private func matches(
        _ method: DexFile.EncodedMethod,
        name: String,
        prototype: String
    ) -> Bool {
        let reference = dex.methodIds[method.methodIndex]
        return reference.name == name && reference.prototype.descriptor == prototype
    }

    private func duplicateMethodError(
        _ descriptor: String,
        name: String,
        prototype: String
    ) -> VMError {
        .verify("duplicate virtual method \(descriptor).\(name)\(prototype)")
    }
}
