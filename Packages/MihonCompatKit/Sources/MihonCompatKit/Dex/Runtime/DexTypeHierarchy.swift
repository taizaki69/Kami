import Foundation

/// Shared, conservative reference-type reasoning for verification and runtime
/// checks. Parsed DEX definitions are authoritative. A bounded host graph
/// covers the Java/Kotlin types modeled by `HostBridge`; unknown external
/// classes remain unresolved instead of being rejected speculatively.
struct DexTypeHierarchy {
    enum Assignability: Equatable {
        case yes
        case no
        case unknown
    }

    private struct TypeInfo {
        let superclass: String?
        let interfaces: [String]
        let isInterface: Bool

        var parents: [String] {
            if let superclass { return [superclass] + interfaces }
            return interfaces
        }
    }

    static let object = "Ljava/lang/Object;"
    static let throwable = "Ljava/lang/Throwable;"
    static let cloneable = "Ljava/lang/Cloneable;"
    static let serializable = "Ljava/io/Serializable;"

    let dex: DexFile

    func assignability(
        from candidate: String,
        to expected: String,
        strict: Bool = false
    ) -> Assignability {
        guard Self.isReferenceDescriptor(candidate),
              Self.isReferenceDescriptor(expected) else {
            return .no
        }
        if candidate == expected || expected == Self.object { return .yes }

        let candidateIsArray = candidate.hasPrefix("[")
        let expectedIsArray = expected.hasPrefix("[")
        if candidateIsArray || expectedIsArray {
            return arrayAssignability(
                from: candidate,
                to: expected,
                candidateIsArray: candidateIsArray,
                expectedIsArray: expectedIsArray,
                strict: strict
            )
        }

        // ART's ordinary verifier assignment deliberately accepts any
        // reference for a resolved interface. Runtime checks and catch types
        // request strict behavior instead.
        if !strict, isInterface(expected) == true { return .yes }

        var pending = [candidate]
        var visited: Set<String> = []
        var reachedUnknown = false
        while let current = pending.popLast() {
            if current == expected { return .yes }
            guard visited.insert(current).inserted else { continue }
            guard let info = typeInfo(current) else {
                reachedUnknown = true
                continue
            }
            pending.append(contentsOf: info.parents)
        }
        return reachedUnknown ? .unknown : .no
    }

    /// Computes a safe verifier join. When exact external hierarchy data is not
    /// available, `java.lang.Object` is the sound common reference type.
    func commonSupertype(_ lhs: String, _ rhs: String) -> String {
        if lhs == rhs { return lhs }
        if lhs == Self.object || rhs == Self.object { return Self.object }

        if lhs.hasPrefix("["), rhs.hasPrefix("[") {
            let leftComponent = String(lhs.dropFirst())
            let rightComponent = String(rhs.dropFirst())
            if Self.isReferenceDescriptor(leftComponent),
               Self.isReferenceDescriptor(rightComponent) {
                return "[" + commonSupertype(leftComponent, rightComponent)
            }
            return Self.object
        }

        if assignability(from: rhs, to: lhs, strict: true) == .yes { return lhs }
        if assignability(from: lhs, to: rhs, strict: true) == .yes { return rhs }

        let rightAncestors = Set(classAncestors(of: rhs))
        for ancestor in classAncestors(of: lhs) where rightAncestors.contains(ancestor) {
            return ancestor
        }
        return Self.object
    }

    func runtimeDescriptor(of value: RVal) -> String? {
        switch value {
        case let .obj(object):
            return object.dexType
        case let .arr(array):
            return "[" + array.elemDescriptor
        case let .host(box):
            return "L" + box.className.replacingOccurrences(of: ".", with: "/") + ";"
        case .null, .int, .long, .float, .double:
            return nil
        }
    }

    func isInstance(_ value: RVal, of expected: String) -> Bool {
        guard !value.isNull, let candidate = runtimeDescriptor(of: value) else { return false }
        return assignability(from: candidate, to: expected, strict: true) == .yes
    }

    /// A value crossing the interpreter's throwable boundary is known to be a
    /// throwable even when its external class hierarchy is unavailable. Keep
    /// unresolved values out of narrower typed catches, but let the universal
    /// `Throwable` handler observe them as ART would after class resolution.
    func catches(_ value: RVal, as expected: String) -> Bool {
        guard !value.isNull, let candidate = runtimeDescriptor(of: value) else { return false }
        let relation = assignability(from: candidate, to: expected, strict: true)
        return relation == .yes || (relation == .unknown && expected == Self.throwable)
    }

    /// Earlier host shims represented synthetic Java exceptions as String
    /// objects carrying an exception name. Normalize those at the interpreter
    /// boundary so catch dispatch and `move-exception` observe the real class.
    func normalizedThrowable(_ value: RVal) -> RVal {
        guard case let .obj(object) = value,
              object.dexType == "Ljava/lang/String;",
              let message = object.payload as? String,
              let descriptor = Self.syntheticExceptionDescriptor(for: message) else {
            return value
        }
        return .obj(ObjInstance(
            dexType: descriptor,
            payload: message,
            isHost: true
        ))
    }

    func isInterface(_ descriptor: String) -> Bool? {
        typeInfo(descriptor)?.isInterface
    }

    func isKnown(_ descriptor: String) -> Bool {
        typeInfo(descriptor) != nil
    }

    private func arrayAssignability(
        from candidate: String,
        to expected: String,
        candidateIsArray: Bool,
        expectedIsArray: Bool,
        strict: Bool
    ) -> Assignability {
        if candidateIsArray, !expectedIsArray {
            if expected == Self.object || expected == Self.cloneable || expected == Self.serializable {
                return .yes
            }
            if !strict, isInterface(expected) == true { return .yes }
            return typeInfo(expected) == nil ? .unknown : .no
        }
        if !candidateIsArray, expectedIsArray { return .no }

        let candidateComponent = String(candidate.dropFirst())
        let expectedComponent = String(expected.dropFirst())
        if candidateComponent == expectedComponent { return .yes }
        guard Self.isReferenceDescriptor(candidateComponent),
              Self.isReferenceDescriptor(expectedComponent) else {
            return .no
        }
        return assignability(from: candidateComponent, to: expectedComponent, strict: strict)
    }

    private func classAncestors(of descriptor: String) -> [String] {
        if descriptor.hasPrefix("[") { return [Self.object] }
        var result: [String] = []
        var current: String? = descriptor
        var visited: Set<String> = []
        var reachedThroughDeclaredSuperclass = false
        while let value = current, visited.insert(value).inserted {
            if value == Self.object {
                result.append(value)
                break
            }
            guard let info = typeInfo(value) else {
                // A DEX class's superclass_idx is authoritative even when the
                // referenced library class itself is not present in the APK.
                if reachedThroughDeclaredSuperclass { result.append(value) }
                if result.last != Self.object { result.append(Self.object) }
                break
            }
            if info.isInterface {
                if result.last != Self.object { result.append(Self.object) }
                break
            }
            result.append(value)
            current = info.superclass
            reachedThroughDeclaredSuperclass = current != nil
            if current == nil, value != Self.object { current = Self.object }
        }
        if result.last != Self.object { result.append(Self.object) }
        return result
    }

    private func typeInfo(_ descriptor: String) -> TypeInfo? {
        if let index = dex.classIndexByDescriptor[descriptor] {
            let definition = dex.classDefs[index]
            let superclass: String?
            if definition.superclassIndex >= 0,
               definition.superclassIndex < dex.typeDescriptors.count {
                superclass = dex.typeDescriptors[definition.superclassIndex]
            } else {
                superclass = nil
            }
            let interfaces = definition.interfaceIndices.compactMap { index in
                index >= 0 && index < dex.typeDescriptors.count
                    ? dex.typeDescriptors[index]
                    : nil
            }
            return TypeInfo(
                superclass: superclass,
                interfaces: interfaces,
                isInterface: definition.accessFlags & 0x200 != 0
            )
        }
        return Self.hostTypes[descriptor]
    }

    static func isReferenceDescriptor(_ descriptor: String) -> Bool {
        (descriptor.hasPrefix("L") && descriptor.hasSuffix(";"))
            || descriptor.hasPrefix("[")
    }

    private static func syntheticExceptionDescriptor(for message: String) -> String? {
        let simpleName = String(message.prefix { character in
            character != ":" && !character.isWhitespace
        })
        let special = [
            "PatternSyntaxException": "Ljava/util/regex/PatternSyntaxException;",
            "NoSuchElementException": "Ljava/util/NoSuchElementException;",
            "UninitializedPropertyAccessException": "Lkotlin/UninitializedPropertyAccessException;",
        ]
        if let descriptor = special[simpleName] { return descriptor }
        let descriptor = "Ljava/lang/\(simpleName);"
        guard let info = hostTypes[descriptor], !info.isInterface,
              descriptor != object,
              descriptor != "Ljava/lang/String;" else {
            return nil
        }
        return descriptor
    }

    /// Closed portions of the host compatibility hierarchy. Entries only claim
    /// relationships modeled by the runtime; absent types intentionally stay
    /// unresolved so real extensions can continue to soft-verify.
    private static let hostTypes: [String: TypeInfo] = {
        var result: [String: TypeInfo] = [:]

        func classType(
            _ descriptor: String,
            superclass: String = object,
            interfaces: [String] = []
        ) {
            result[descriptor] = TypeInfo(
                superclass: descriptor == object ? nil : superclass,
                interfaces: interfaces,
                isInterface: false
            )
        }

        func interfaceType(_ descriptor: String, extends: [String] = []) {
            result[descriptor] = TypeInfo(
                superclass: nil,
                interfaces: extends,
                isInterface: true
            )
        }

        classType(object)

        interfaceType(cloneable)
        interfaceType(serializable)
        interfaceType("Ljava/lang/Comparable;")
        interfaceType("Ljava/lang/CharSequence;")
        interfaceType("Ljava/lang/Appendable;")
        interfaceType("Ljava/lang/Runnable;")
        interfaceType("Ljava/lang/Iterable;")
        interfaceType("Ljava/util/Iterator;")
        interfaceType("Ljava/util/Collection;", extends: ["Ljava/lang/Iterable;"])
        interfaceType("Ljava/util/List;", extends: ["Ljava/util/Collection;"])
        interfaceType("Ljava/util/Set;", extends: ["Ljava/util/Collection;"])
        interfaceType("Ljava/util/Map;")
        interfaceType("Ljava/util/Map$Entry;")

        classType(throwable)
        classType("Ljava/lang/Exception;", superclass: throwable)
        classType("Ljava/lang/RuntimeException;", superclass: "Ljava/lang/Exception;")
        classType("Ljava/lang/Error;", superclass: throwable)
        classType("Ljava/lang/LinkageError;", superclass: "Ljava/lang/Error;")
        classType("Ljava/lang/IncompatibleClassChangeError;", superclass: "Ljava/lang/LinkageError;")
        classType("Ljava/lang/AbstractMethodError;", superclass: "Ljava/lang/IncompatibleClassChangeError;")
        classType("Ljava/lang/NoSuchMethodError;", superclass: "Ljava/lang/IncompatibleClassChangeError;")

        let runtimeExceptions = [
            "Ljava/lang/ArithmeticException;",
            "Ljava/lang/ArrayStoreException;",
            "Ljava/lang/ClassCastException;",
            "Ljava/lang/IllegalArgumentException;",
            "Ljava/lang/IllegalMonitorStateException;",
            "Ljava/lang/IllegalStateException;",
            "Ljava/lang/IndexOutOfBoundsException;",
            "Ljava/lang/NegativeArraySizeException;",
            "Ljava/lang/NullPointerException;",
            "Ljava/lang/SecurityException;",
            "Ljava/lang/UnsupportedOperationException;",
        ]
        for descriptor in runtimeExceptions {
            classType(descriptor, superclass: "Ljava/lang/RuntimeException;")
        }
        classType("Ljava/lang/ArrayIndexOutOfBoundsException;", superclass: "Ljava/lang/IndexOutOfBoundsException;")
        classType("Ljava/lang/StringIndexOutOfBoundsException;", superclass: "Ljava/lang/IndexOutOfBoundsException;")
        classType("Ljava/lang/NumberFormatException;", superclass: "Ljava/lang/IllegalArgumentException;")
        classType("Ljava/util/NoSuchElementException;", superclass: "Ljava/lang/RuntimeException;")
        classType("Ljava/util/ConcurrentModificationException;", superclass: "Ljava/lang/RuntimeException;")
        classType("Ljava/util/concurrent/CancellationException;", superclass: "Ljava/lang/IllegalStateException;")
        classType("Ljava/util/regex/PatternSyntaxException;", superclass: "Ljava/lang/IllegalArgumentException;")
        classType("Lkotlin/UninitializedPropertyAccessException;", superclass: "Ljava/lang/RuntimeException;")
        classType(
            "Leu/kanade/tachiyomi/network/HttpException;",
            superclass: "Ljava/lang/IllegalStateException;"
        )

        classType("Ljava/lang/ReflectiveOperationException;", superclass: "Ljava/lang/Exception;")
        for descriptor in [
            "Ljava/lang/ClassNotFoundException;",
            "Ljava/lang/IllegalAccessException;",
            "Ljava/lang/InstantiationException;",
            "Ljava/lang/NoSuchFieldException;",
            "Ljava/lang/NoSuchMethodException;",
        ] {
            classType(descriptor, superclass: "Ljava/lang/ReflectiveOperationException;")
        }
        classType("Ljava/io/IOException;", superclass: "Ljava/lang/Exception;")
        classType(
            "Ljava/io/UnsupportedEncodingException;",
            superclass: "Ljava/io/IOException;"
        )

        classType("Ljava/lang/String;", interfaces: [
            serializable, "Ljava/lang/Comparable;", "Ljava/lang/CharSequence;",
        ])
        classType("Ljava/lang/StringBuilder;", interfaces: [
            serializable, "Ljava/lang/Comparable;", "Ljava/lang/CharSequence;", "Ljava/lang/Appendable;",
        ])
        classType("Ljava/lang/StringBuffer;", interfaces: [
            serializable, "Ljava/lang/Comparable;", "Ljava/lang/CharSequence;", "Ljava/lang/Appendable;",
        ])
        classType("Ljava/lang/Class;", interfaces: [serializable])
        classType("Ljava/lang/Enum;", interfaces: ["Ljava/lang/Comparable;", serializable])
        classType("Ljava/lang/Number;", interfaces: [serializable])
        for descriptor in [
            "Ljava/lang/Byte;", "Ljava/lang/Double;", "Ljava/lang/Float;",
            "Ljava/lang/Integer;", "Ljava/lang/Long;", "Ljava/lang/Short;",
        ] {
            classType(descriptor, superclass: "Ljava/lang/Number;", interfaces: ["Ljava/lang/Comparable;"])
        }
        for descriptor in ["Ljava/lang/Boolean;", "Ljava/lang/Character;"] {
            classType(descriptor, interfaces: ["Ljava/lang/Comparable;", serializable])
        }

        classType("Ljava/util/AbstractCollection;", interfaces: ["Ljava/util/Collection;"])
        classType("Ljava/util/AbstractList;", superclass: "Ljava/util/AbstractCollection;", interfaces: ["Ljava/util/List;"])
        classType("Ljava/util/AbstractSet;", superclass: "Ljava/util/AbstractCollection;", interfaces: ["Ljava/util/Set;"])
        classType("Ljava/util/AbstractMap;", interfaces: ["Ljava/util/Map;"])
        classType("Ljava/util/ArrayList;", superclass: "Ljava/util/AbstractList;", interfaces: [cloneable, serializable])
        classType(
            "Lorg/jsoup/select/Elements;",
            superclass: "Ljava/util/ArrayList;"
        )
        classType("Lorg/jsoup/nodes/Element;")
        classType(
            "Lorg/jsoup/nodes/Document;",
            superclass: "Lorg/jsoup/nodes/Element;"
        )
        interfaceType(
            "Leu/kanade/tachiyomi/source/model/SManga;",
            extends: [serializable]
        )
        classType("Leu/kanade/tachiyomi/source/model/SManga$Companion;")
        classType("Leu/kanade/tachiyomi/source/model/MangasPage;")
        classType("Ljava/util/LinkedList;", superclass: "Ljava/util/AbstractList;", interfaces: ["Ljava/util/List;", cloneable, serializable])
        classType("Ljava/util/HashSet;", superclass: "Ljava/util/AbstractSet;", interfaces: [cloneable, serializable])
        classType("Ljava/util/LinkedHashSet;", superclass: "Ljava/util/HashSet;")
        classType("Ljava/util/HashMap;", superclass: "Ljava/util/AbstractMap;", interfaces: [cloneable, serializable])
        classType("Ljava/util/LinkedHashMap;", superclass: "Ljava/util/HashMap;")

        return result
    }()
}
