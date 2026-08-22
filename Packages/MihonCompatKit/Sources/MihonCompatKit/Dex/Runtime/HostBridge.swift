import Foundation

/// Host method bridge: the only path from interpreted DEX to native Swift
/// (mission §23). Registrations are explicit; the VM never hardcodes classes.
public final class HostBridge {
    public typealias Method = (_ vm: DexInterpreter, _ args: [RVal]) throws -> RVal

    struct Registration {
        let isStatic: Bool
        let method: Method
    }

    private struct MethodKey: Hashable {
        let classDescriptor: String
        let name: String
        let prototype: String
    }

    private struct KotlinFailure {
        let throwable: RVal
    }

    private struct KotlinPairBox {
        let first: RVal
        let second: RVal
    }

    private struct ReflectedField {
        let declaringClass: String
        let name: String
        let type: String
    }

    private final class KotlinLazyBox {
        let initializer: RVal
        var cached: RVal?

        init(initializer: RVal) {
            self.initializer = initializer
        }
    }

    private final class AtomicBooleanBox {
        var value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

    private final class AtomicIntegerBox {
        var value: Int32

        init(_ value: Int32) {
            self.value = value
        }
    }

    private final class HostMapBox {
        var entries: [(key: RVal, value: RVal)] = []
        let isMutable: Bool

        init(isMutable: Bool) {
            self.isMutable = isMutable
        }
    }

    private final class HostListBox {
        var elements: [RVal]
        var isMutable: Bool

        init(_ elements: [RVal] = [], isMutable: Bool) {
            self.elements = elements
            self.isMutable = isMutable
        }
    }

    private final class HostIteratorBox {
        let elements: [RVal]
        var index = 0

        init(_ elements: [RVal]) {
            self.elements = elements
        }
    }

    private final class KotlinRegexBox {
        let pattern: String
        let expression: NSRegularExpression

        init(pattern: String, expression: NSRegularExpression) {
            self.pattern = pattern
            self.expression = expression
        }
    }

    private struct FilterSortSelectionBox {
        let index: Int32
        let ascending: Bool
    }

    private struct FilterStateBox {
        let name: String
        let state: RVal
    }

    /// Exact `(declaring class, name, prototype)` registrations. Ignoring the
    /// prototype would let an untrusted overload reach the wrong native body.
    private var methods: [MethodKey: Registration] = [:]

    /// Static field storage for host classes (sget/sput on host classes).
    public var staticFields: [String: RVal] = [:]

    /// new-instance factories for host classes (StringBuilder, …).
    public var objectFactories: [String: (DexInterpreter) throws -> RVal] = [:]

    public init() {}

    public func register(class descriptor: String, _ methodName: String,
                         prototype: String, isStatic: Bool = false,
                         _ body: @escaping Method) {
        methods[MethodKey(classDescriptor: descriptor, name: methodName, prototype: prototype)] =
            Registration(isStatic: isStatic, method: body)
    }

    public func resolve(class descriptor: String, _ methodName: String,
                        prototype: String, isStatic: Bool) -> Method? {
        guard let registration = methods[
            MethodKey(classDescriptor: descriptor, name: methodName, prototype: prototype)
        ], registration.isStatic == isStatic else { return nil }
        return registration.method
    }

    public func resolve(_ reference: DexFile.MethodRef, isStatic: Bool) -> Method? {
        resolve(
            class: reference.declaringClass,
            reference.name,
            prototype: reference.prototype.descriptor,
            isStatic: isStatic
        )
    }

    private static func register(_ bridge: HostBridge, class descriptor: String,
                                 method name: String, prototypes: [String],
                                 isStatic: Bool = false,
                                 body: @escaping Method) {
        for prototype in prototypes {
            bridge.register(
                class: descriptor,
                name,
                prototype: prototype,
                isStatic: isStatic,
                body
            )
        }
    }

    /// Registers the minimal M1 host surface: Intrinsics null-checks and the
    /// object/String basics that real extension methods hit immediately.
    public static func minimal() -> HostBridge {
        let bridge = HostBridge()

        // Kotlin null checks are common in generated extension bytecode. They
        // return void for non-null values and surface a DEX exception for null.
        let intrinsics = "Lkotlin/jvm/internal/Intrinsics;"
        let nullChecks: [(String, [String])] = [
            ("checkNotNullParameter", ["(Ljava/lang/Object;Ljava/lang/String;)V"]),
            ("checkNotNull", ["(Ljava/lang/Object;)V", "(Ljava/lang/Object;Ljava/lang/String;)V"]),
            ("checkParameterIsNotNull", ["(Ljava/lang/Object;Ljava/lang/String;)V"]),
            ("checkExpressionValueIsNotNull", ["(Ljava/lang/Object;Ljava/lang/String;)V"]),
            ("checkNotNullExpressionValue", ["(Ljava/lang/Object;Ljava/lang/String;)V"]),
        ]
        for (name, prototypes) in nullChecks {
            register(
                bridge,
                class: intrinsics,
                method: name,
                prototypes: prototypes,
                isStatic: true
            ) { _, args in
                let value = try argument(args, 0, "Intrinsics.\(name)")
                guard !value.isNull else {
                    throw DEXThrowable(string("NullPointerException"))
                }
                return .null
            }
        }
        register(
            bridge,
            class: intrinsics,
            method: "throwNpe",
            prototypes: ["()V", "(Ljava/lang/String;)V"],
            isStatic: true
        ) { _, _ in
            throw DEXThrowable(string("NullPointerException"))
        }
        for name in ["throwUninitializedProperty", "throwUninitializedPropertyAccessException"] {
            bridge.register(
                class: intrinsics,
                name,
                prototype: "(Ljava/lang/String;)V",
                isStatic: true
            ) { _, args in
                let property = args.first.map(vmStringValue) ?? ""
                throw DEXThrowable(string("UninitializedPropertyAccessException: \(property)"))
            }
        }

        // Object identity basics.
        bridge.register(class: "Ljava/lang/Object;", "<init>", prototype: "()V") { _, _ in .null }
        bridge.register(
            class: "Ljava/lang/Object;",
            "equals",
            prototype: "(Ljava/lang/Object;)Z"
        ) { _, args in
            let receiver = try argument(args, 0, "Object.equals")
            let other = try argument(args, 1, "Object.equals")
            return .int(receiver === other ? 1 : 0)
        }
        bridge.register(class: "Ljava/lang/Object;", "hashCode", prototype: "()I") { _, args in
            if case let .obj(o) = try argument(args, 0, "Object.hashCode") {
                let h = UInt32(bitPattern: Int32(ObjectIdentifier(o).hashValue & 0x7FFFFFFF))
                return .int(Int32(bitPattern: h))
            }
            return .int(0)
        }
        bridge.register(
            class: "Ljava/lang/Object;",
            "toString",
            prototype: "()Ljava/lang/String;"
        ) { _, args in
            Self.string(vmStringValue(try argument(args, 0, "Object.toString")))
        }
        bridge.register(
            class: "Ljava/lang/Object;",
            "getClass",
            prototype: "()Ljava/lang/Class;"
        ) { vm, args in
            Self.classObject(for: try argument(args, 0, "Object.getClass"), vm: vm)
        }

        bridge.register(
            class: "Ljava/lang/Class;",
            "getDeclaredField",
            prototype: "(Ljava/lang/String;)Ljava/lang/reflect/Field;"
        ) { vm, args in
            guard case let .obj(classObject) = try argument(args, 0, "Class.getDeclaredField"),
                  let declaringClass = classObject.payload as? String else {
                throw VMError.verify("Class.getDeclaredField receiver")
            }
            let name = vmStringValue(try argument(args, 1, "Class.getDeclaredField"))
            if let field = vm.dex.fieldIds.first(where: {
                $0.declaringClass == declaringClass && $0.name == name
            }) {
                return Self.reflectedField(
                    declaringClass: field.declaringClass,
                    name: field.name,
                    type: field.type
                )
            }
            let reflectableSourceBases: Set<String> = [
                "Leu/kanade/tachiyomi/source/online/HttpSource;",
                "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;",
            ]
            guard reflectableSourceBases.contains(declaringClass) else {
                throw DEXThrowable(string("NoSuchFieldException: \(declaringClass).\(name)"))
            }
            // Host base-class state remains confined to the interpreted
            // object's field bag; reflection never exposes native Swift state.
            return Self.reflectedField(
                declaringClass: declaringClass,
                name: name,
                type: "Ljava/lang/Object;"
            )
        }
        bridge.register(
            class: "Ljava/lang/Class;",
            "getSimpleName",
            prototype: "()Ljava/lang/String;"
        ) { _, args in
            guard case let .obj(classObject) = try argument(args, 0, "Class.getSimpleName"),
                  let descriptor = classObject.payload as? String else {
                throw VMError.verify("Class.getSimpleName receiver")
            }
            let readable = DexFile.readableClassName(descriptor)
            return string(String(readable.split(separator: ".").last ?? Substring(readable)))
        }
        bridge.register(
            class: "Ljava/lang/reflect/Field;",
            "set",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)V"
        ) { vm, args in
            guard case let .obj(fieldObject) = try argument(args, 0, "Field.set"),
                  let field = fieldObject.payload as? ReflectedField else {
                throw VMError.verify("Field.set receiver")
            }
            guard case let .obj(target) = try argument(args, 1, "Field.set") else {
                throw DEXThrowable(string("NullPointerException: Field.set target"))
            }
            guard Self.isInstance(target.dexType, of: field.declaringClass, dex: vm.dex) else {
                throw DEXThrowable(string(
                    "IllegalArgumentException: \(target.dexType) is not \(field.declaringClass) for \(field.name):\(field.type)"
                ))
            }
            target.fields[field.name] = try argument(args, 2, "Field.set")
            return .null
        }
        bridge.register(
            class: "Ljava/lang/reflect/AccessibleObject;",
            "setAccessible",
            prototype: "(Z)V"
        ) { _, args in
            guard case .obj = try argument(args, 0, "AccessibleObject.setAccessible"),
                  case .int = try argument(args, 1, "AccessibleObject.setAccessible") else {
                throw VMError.verify("AccessibleObject.setAccessible arguments")
            }
            return .null
        }

        // java.lang.String surface (payload-backed).
        Self.registerStringSurface(bridge)
        Self.registerStringBuilder(bridge)

        // These abstract tachiyomix base classes are supplied by the host app,
        // not packaged in extension DEX files. Their empty construction surface
        // is enough for extension subclasses whose own getters are self-contained.
        for descriptor in [
            "Leu/kanade/tachiyomi/source/online/HttpSource;",
            "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;",
        ] {
            bridge.register(class: descriptor, "<init>", prototype: "()V") { _, _ in .null }
        }

        // Generated suspend state machines subclass this Kotlin runtime class.
        // The completion link is not observable until suspension/resumption;
        // synchronous extension paths only require deterministic construction.
        bridge.register(
            class: "Lkotlin/coroutines/jvm/internal/ContinuationImpl;",
            "<init>",
            prototype: "(Lkotlin/coroutines/Continuation;)V"
        ) { _, _ in .null }
        let suspendedMarker = RVal.obj(ObjInstance(
            dexType: "Lkotlin/coroutines/intrinsics/CoroutineSingletons;",
            payload: "COROUTINE_SUSPENDED",
            isHost: true
        ))
        bridge.register(
            class: "Lkotlin/coroutines/intrinsics/IntrinsicsKt;",
            "getCOROUTINE_SUSPENDED",
            prototype: "()Ljava/lang/Object;",
            isStatic: true
        ) { _, _ in suspendedMarker }
        bridge.register(
            class: "Lkotlin/ResultKt;",
            "createFailure",
            prototype: "(Ljava/lang/Throwable;)Ljava/lang/Object;",
            isStatic: true
        ) { _, args in
            let throwable = try argument(args, 0, "ResultKt.createFailure")
            return .obj(ObjInstance(
                dexType: "Lkotlin/Result$Failure;",
                payload: KotlinFailure(throwable: throwable),
                isHost: true
            ))
        }
        bridge.register(
            class: "Lkotlin/ResultKt;",
            "throwOnFailure",
            prototype: "(Ljava/lang/Object;)V",
            isStatic: true
        ) { _, args in
            let value = try argument(args, 0, "ResultKt.throwOnFailure")
            if case let .obj(object) = value {
                if let failure = object.payload as? KotlinFailure {
                    throw DEXThrowable(failure.throwable)
                }
                if object.dexType == "Lkotlin/Result$Failure;", let throwable = object.fields["exception"] {
                    throw DEXThrowable(throwable)
                }
            }
            return .null
        }
        bridge.register(
            class: "Lkotlin/TuplesKt;",
            "to",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Lkotlin/Pair;",
            isStatic: true
        ) { _, args in
            let first = try argument(args, 0, "TuplesKt.to")
            let second = try argument(args, 1, "TuplesKt.to")
            return .obj(ObjInstance(
                dexType: "Lkotlin/Pair;",
                payload: KotlinPairBox(first: first, second: second),
                isHost: true
            ))
        }
        let pairAccessors: [(String, KeyPath<KotlinPairBox, RVal>)] = [
            ("component1", \.first),
            ("getFirst", \.first),
            ("component2", \.second),
            ("getSecond", \.second),
        ]
        for (name, keyPath) in pairAccessors {
            bridge.register(
                class: "Lkotlin/Pair;",
                name,
                prototype: "()Ljava/lang/Object;"
            ) { _, args in
                guard case let .obj(object) = try argument(args, 0, "Pair.\(name)"),
                      let pair = object.payload as? KotlinPairBox else {
                    throw VMError.verify("Pair.\(name) receiver")
                }
                return pair[keyPath: keyPath]
            }
        }
        bridge.register(
            class: "Lkotlin/text/StringsKt;",
            "isBlank",
            prototype: "(Ljava/lang/CharSequence;)Z",
            isStatic: true
        ) { _, args in
            let value = vmStringValue(try argument(args, 0, "StringsKt.isBlank"))
            return .int(value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } ? 1 : 0)
        }
        bridge.register(
            class: "Lkotlin/jvm/internal/Ref$BooleanRef;",
            "<init>",
            prototype: "()V"
        ) { _, _ in .null }
        bridge.register(
            class: "Lkotlin/LazyKt;",
            "lazy",
            prototype: "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;",
            isStatic: true
        ) { _, args in
            let initializer = try argument(args, 0, "LazyKt.lazy")
            return Self.lazy(initializer)
        }
        bridge.register(
            class: "Lkotlin/LazyKt;",
            "lazy",
            prototype: "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;",
            isStatic: true
        ) { _, args in
            let initializer = try argument(args, 1, "LazyKt.lazy")
            return Self.lazy(initializer)
        }
        bridge.register(
            class: "Lkotlin/Lazy;",
            "getValue",
            prototype: "()Ljava/lang/Object;"
        ) { vm, args in
            guard case let .obj(object) = try argument(args, 0, "Lazy.getValue"),
                  let lazy = object.payload as? KotlinLazyBox else {
                throw VMError.verify("Lazy.getValue receiver")
            }
            if let cached = lazy.cached { return cached }
            guard case let .obj(initializer) = lazy.initializer else {
                throw VMError.verify("Lazy initializer is not a DEX object")
            }
            let value = try vm.call(
                classDescriptor: initializer.dexType,
                method: "invoke",
                prototype: "()Ljava/lang/Object;",
                args: [lazy.initializer]
            )
            lazy.cached = value
            return value
        }
        let atomicBoolean = "Ljava/util/concurrent/atomic/AtomicBoolean;"
        bridge.objectFactories[atomicBoolean] = { _ in
            .obj(ObjInstance(
                dexType: atomicBoolean,
                payload: AtomicBooleanBox(false),
                isHost: true
            ))
        }
        bridge.register(class: atomicBoolean, "<init>", prototype: "(Z)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicBoolean.<init>"),
                  case let .int(value) = try argument(args, 1, "AtomicBoolean.<init>") else {
                throw VMError.verify("AtomicBoolean constructor arguments")
            }
            object.payload = AtomicBooleanBox(value != 0)
            return .null
        }
        bridge.register(class: atomicBoolean, "compareAndSet", prototype: "(ZZ)Z") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicBoolean.compareAndSet"),
                  let box = object.payload as? AtomicBooleanBox,
                  case let .int(expected) = try argument(args, 1, "AtomicBoolean.compareAndSet"),
                  case let .int(update) = try argument(args, 2, "AtomicBoolean.compareAndSet") else {
                throw VMError.verify("AtomicBoolean.compareAndSet arguments")
            }
            guard box.value == (expected != 0) else { return .int(0) }
            box.value = update != 0
            return .int(1)
        }
        bridge.register(class: atomicBoolean, "set", prototype: "(Z)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicBoolean.set"),
                  let box = object.payload as? AtomicBooleanBox,
                  case let .int(value) = try argument(args, 1, "AtomicBoolean.set") else {
                throw VMError.verify("AtomicBoolean.set arguments")
            }
            box.value = value != 0
            return .null
        }
        let atomicInteger = "Ljava/util/concurrent/atomic/AtomicInteger;"
        bridge.objectFactories[atomicInteger] = { _ in
            .obj(ObjInstance(
                dexType: atomicInteger,
                payload: AtomicIntegerBox(0),
                isHost: true
            ))
        }
        bridge.register(class: atomicInteger, "<init>", prototype: "(I)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicInteger.<init>"),
                  case let .int(value) = try argument(args, 1, "AtomicInteger.<init>") else {
                throw VMError.verify("AtomicInteger constructor arguments")
            }
            object.payload = AtomicIntegerBox(value)
            return .null
        }
        bridge.register(class: atomicInteger, "get", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicInteger.get"),
                  let box = object.payload as? AtomicIntegerBox else {
                throw VMError.verify("AtomicInteger.get receiver")
            }
            return .int(box.value)
        }
        bridge.register(class: atomicInteger, "incrementAndGet", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicInteger.incrementAndGet"),
                  let box = object.payload as? AtomicIntegerBox else {
                throw VMError.verify("AtomicInteger.incrementAndGet receiver")
            }
            box.value &+= 1
            return .int(box.value)
        }
        bridge.register(class: atomicInteger, "set", prototype: "(I)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "AtomicInteger.set"),
                  let box = object.payload as? AtomicIntegerBox,
                  case let .int(value) = try argument(args, 1, "AtomicInteger.set") else {
                throw VMError.verify("AtomicInteger.set arguments")
            }
            box.value = value
            return .null
        }
        let concurrentMap = "Ljava/util/concurrent/ConcurrentHashMap;"
        bridge.objectFactories[concurrentMap] = { _ in
            .obj(ObjInstance(
                dexType: concurrentMap,
                payload: HostMapBox(isMutable: true),
                isHost: true
            ))
        }
        bridge.register(class: concurrentMap, "<init>", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "ConcurrentHashMap.<init>") else {
                throw VMError.verify("ConcurrentHashMap constructor receiver")
            }
            object.payload = HostMapBox(isMutable: true)
            return .null
        }
        bridge.register(
            class: concurrentMap,
            "putIfAbsent",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"
        ) { _, args in
            let box = try mapBox(args, "ConcurrentHashMap.putIfAbsent")
            guard box.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable map"))
            }
            let key = try argument(args, 1, "ConcurrentHashMap.putIfAbsent")
            let value = try argument(args, 2, "ConcurrentHashMap.putIfAbsent")
            guard !key.isNull, !value.isNull else {
                throw DEXThrowable(string("NullPointerException"))
            }
            if let existing = box.entries.first(where: { javaValueEquals($0.key, key) }) {
                return existing.value
            }
            try requireCollectionCapacity(box.entries.count + 1, "ConcurrentHashMap.putIfAbsent")
            box.entries.append((key, value))
            return .null
        }
        bridge.register(
            class: concurrentMap,
            "remove",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;"
        ) { _, args in
            let box = try mapBox(args, "ConcurrentHashMap.remove")
            guard box.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable map"))
            }
            let key = try argument(args, 1, "ConcurrentHashMap.remove")
            guard let index = box.entries.firstIndex(where: { javaValueEquals($0.key, key) }) else {
                return .null
            }
            return box.entries.remove(at: index).value
        }
        bridge.register(
            class: "Ljava/util/Map;",
            "put",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"
        ) { _, args in
            let box = try mapBox(args, "Map.put")
            guard box.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable map"))
            }
            let key = try argument(args, 1, "Map.put")
            let value = try argument(args, 2, "Map.put")
            if let index = box.entries.firstIndex(where: { javaValueEquals($0.key, key) }) {
                let previous = box.entries[index].value
                box.entries[index].value = value
                return previous
            }
            try requireCollectionCapacity(box.entries.count + 1, "Map.put")
            box.entries.append((key, value))
            return .null
        }
        bridge.register(class: "Ljava/util/Map;", "size", prototype: "()I") { _, args in
            .int(Int32(clamping: try mapBox(args, "Map.size").entries.count))
        }
        Self.registerPrimitiveBoxes(bridge)
        Self.registerCollectionSurface(bridge)
        Self.registerFilterSurface(bridge)
        bridge.register(
            class: "Ljava/time/format/DateTimeFormatter;",
            "ofPattern",
            prototype: "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatter;",
            isStatic: true
        ) { _, args in
            let pattern = vmStringValue(try argument(args, 0, "DateTimeFormatter.ofPattern"))
            guard !pattern.isEmpty else {
                throw DEXThrowable(string("IllegalArgumentException: empty date pattern"))
            }
            return .obj(ObjInstance(
                dexType: "Ljava/time/format/DateTimeFormatter;",
                payload: pattern,
                isHost: true
            ))
        }
        let regex = "Lkotlin/text/Regex;"
        bridge.objectFactories[regex] = { _ in
            .obj(ObjInstance(dexType: regex, isHost: true))
        }
        bridge.register(class: regex, "<init>", prototype: "(Ljava/lang/String;)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Regex.<init>") else {
                throw VMError.verify("Regex constructor receiver")
            }
            let pattern = vmStringValue(try argument(args, 1, "Regex.<init>"))
            do {
                object.payload = KotlinRegexBox(
                    pattern: pattern,
                    expression: try NSRegularExpression(pattern: pattern)
                )
                return .null
            } catch {
                throw DEXThrowable(string("PatternSyntaxException: \(error)"))
            }
        }
        let sortSelection = "Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;"
        bridge.objectFactories[sortSelection] = { _ in
            .obj(ObjInstance(dexType: sortSelection, isHost: true))
        }
        bridge.register(class: sortSelection, "<init>", prototype: "(IZ)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Sort.Selection.<init>"),
                  case let .int(index) = try argument(args, 1, "Filter.Sort.Selection.<init>"),
                  case let .int(ascending) = try argument(args, 2, "Filter.Sort.Selection.<init>") else {
                throw VMError.verify("Filter.Sort.Selection constructor arguments")
            }
            object.payload = FilterSortSelectionBox(index: index, ascending: ascending != 0)
            return .null
        }
        bridge.register(class: sortSelection, "getIndex", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Sort.Selection.getIndex"),
                  let selection = object.payload as? FilterSortSelectionBox else {
                throw VMError.verify("Filter.Sort.Selection.getIndex receiver")
            }
            return .int(selection.index)
        }
        bridge.register(class: sortSelection, "getAscending", prototype: "()Z") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Sort.Selection.getAscending"),
                  let selection = object.payload as? FilterSortSelectionBox else {
                throw VMError.verify("Filter.Sort.Selection.getAscending receiver")
            }
            return .int(selection.ascending ? 1 : 0)
        }
        return bridge
    }

    /// StringBuilder: payload carries [String]; capacity ignored in M1.
    static func registerStringBuilder(_ bridge: HostBridge) {
        let d = "Ljava/lang/StringBuilder;"
        bridge.objectFactories[d] = { _ in
            .obj(ObjInstance(dexType: d, payload: "", isHost: true))
        }
        func text(_ v: RVal) -> String { vmStringValue(v) }
        bridge.register(class: d, "<init>", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "StringBuilder.<init>") else {
                throw VMError.verify("StringBuilder constructor receiver")
            }
            object.payload = ""
            return .null
        }
        bridge.register(class: d, "<init>", prototype: "(I)V") { _, args in
            guard case .obj = try argument(args, 0, "StringBuilder.<init>") else {
                throw VMError.verify("StringBuilder constructor receiver")
            }
            return .null // capacity is intentionally ignored
        }
        register(
            bridge,
            class: d,
            method: "<init>",
            prototypes: ["(Ljava/lang/String;)V", "(Ljava/lang/CharSequence;)V"]
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "StringBuilder.<init>") else {
                throw VMError.verify("StringBuilder constructor receiver")
            }
            object.payload = text(try argument(args, 1, "StringBuilder.<init>"))
            return .null
        }

        let appendResult = "Ljava/lang/StringBuilder;"
        let textAppendParameters = [
            "Ljava/lang/String;", "Ljava/lang/Object;", "Ljava/lang/CharSequence;",
            "I", "J", "F", "D",
        ]
        register(
            bridge,
            class: d,
            method: "append",
            prototypes: textAppendParameters.map { "(\($0))\(appendResult)" }
        ) { _, args in
            guard case let .obj(o) = try argument(args, 0, "StringBuilder.append") else {
                throw VMError.verify("append receiver")
            }
            let current = (o.payload as? String) ?? ""
            o.payload = current + text(try argument(args, 1, "StringBuilder.append"))
            return .obj(o)
        }
        bridge.register(class: d, "append", prototype: "(Z)\(appendResult)") { _, args in
            guard case let .obj(object) = try argument(args, 0, "StringBuilder.append") else {
                throw VMError.verify("append receiver")
            }
            guard case let .int(value) = try argument(args, 1, "StringBuilder.append") else {
                throw VMError.verify("append boolean argument")
            }
            object.payload = ((object.payload as? String) ?? "") + (value == 0 ? "false" : "true")
            return .obj(object)
        }
        bridge.register(class: d, "append", prototype: "(C)\(appendResult)") { _, args in
            guard case let .obj(object) = try argument(args, 0, "StringBuilder.append") else {
                throw VMError.verify("append receiver")
            }
            guard case let .int(value) = try argument(args, 1, "StringBuilder.append") else {
                throw VMError.verify("append character argument")
            }
            let character = String(decoding: [UInt16(truncatingIfNeeded: value)], as: UTF16.self)
            object.payload = ((object.payload as? String) ?? "") + character
            return .obj(object)
        }
        bridge.register(class: d, "toString", prototype: "()Ljava/lang/String;") { _, args in
            Self.string(text(try argument(args, 0, "StringBuilder.toString")))
        }
        bridge.register(class: d, "length", prototype: "()I") { _, args in
            .int(Int32(text(try argument(args, 0, "StringBuilder.length")).utf16.count))
        }
        bridge.register(class: d, "isEmpty", prototype: "()Z") { _, args in
            .int(text(try argument(args, 0, "StringBuilder.isEmpty")).isEmpty ? 1 : 0)
        }
    }

    static func string(_ s: String) -> RVal {
        .obj(ObjInstance(dexType: "Ljava/lang/String;", payload: s, isHost: true))
    }

    private static func argument(_ args: [RVal], _ index: Int, _ method: String) throws -> RVal {
        guard index >= 0, index < args.count else {
            throw VMError.verify("\(method) expected argument \(index), got \(args.count) values")
        }
        return args[index]
    }

    private static func stringPayload(_ value: RVal) -> String? {
        guard case let .obj(object) = value,
              object.dexType == "Ljava/lang/String;" else { return nil }
        return object.payload as? String
    }

    static func registerStringSurface(_ bridge: HostBridge) {
        let d = "Ljava/lang/String;"
        bridge.register(class: d, "length", prototype: "()I") { _, args in
            .int(Int32(vmStringValue(try argument(args, 0, "String.length")).utf16.count))
        }
        bridge.register(class: d, "isEmpty", prototype: "()Z") { _, args in
            .int(vmStringValue(try argument(args, 0, "String.isEmpty")).isEmpty ? 1 : 0)
        }
        bridge.register(class: d, "charAt", prototype: "(I)C") { _, args in
            let receiver = try argument(args, 0, "String.charAt")
            guard case let .int(i) = try argument(args, 1, "String.charAt") else {
                throw VMError.verify("charAt non-int index")
            }
            let units = Array(vmStringValue(receiver).utf16)
            guard i >= 0, Int(i) < units.count else {
                throw DEXThrowable(Self.string("StringIndexOutOfBoundsException"))
            }
            return .int(Int32(units[Int(i)]))
        }
        bridge.register(class: d, "equals", prototype: "(Ljava/lang/Object;)Z") { _, args in
            let lhs = try argument(args, 0, "String.equals")
            let rhs = try argument(args, 1, "String.equals")
            return .int(stringPayload(lhs) == stringPayload(rhs) && stringPayload(lhs) != nil ? 1 : 0)
        }
        bridge.register(class: d, "hashCode", prototype: "()I") { _, args in
            // Java string hash: s[0]*31^(n-1) + …
            var h: Int32 = 0
            for u in vmStringValue(try argument(args, 0, "String.hashCode")).utf16 { h = 31 &* h &+ Int32(u) }
            return .int(h)
        }
        bridge.register(class: d, "concat", prototype: "(Ljava/lang/String;)Ljava/lang/String;") { _, args in
            let lhs = try argument(args, 0, "String.concat")
            let rhs = try argument(args, 1, "String.concat")
            return Self.string(vmStringValue(lhs) + vmStringValue(rhs))
        }
        bridge.register(class: d, "toString", prototype: "()Ljava/lang/String;") { _, args in
            Self.string(vmStringValue(try argument(args, 0, "String.toString")))
        }
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

    private static func reflectedField(declaringClass: String, name: String, type: String) -> RVal {
        .obj(ObjInstance(
            dexType: "Ljava/lang/reflect/Field;",
            payload: ReflectedField(declaringClass: declaringClass, name: name, type: type),
            isHost: true
        ))
    }

    private static func lazy(_ initializer: RVal) -> RVal {
        .obj(ObjInstance(
            dexType: "Lkotlin/Lazy;",
            payload: KotlinLazyBox(initializer: initializer),
            isHost: true
        ))
    }

    private static func mapBox(_ args: [RVal], _ method: String) throws -> HostMapBox {
        guard case let .obj(object) = try argument(args, 0, method),
              let box = object.payload as? HostMapBox else {
            throw VMError.verify("\(method) receiver")
        }
        return box
    }

    private static func listBox(_ args: [RVal], _ method: String,
                                index: Int = 0) throws -> HostListBox {
        guard case let .obj(object) = try argument(args, index, method),
              let box = object.payload as? HostListBox else {
            throw VMError.verify("\(method) list argument")
        }
        return box
    }

    private static func hostList(_ elements: [RVal], isMutable: Bool,
                                 descriptor: String = "Ljava/util/List;") -> RVal {
        .obj(ObjInstance(
            dexType: descriptor,
            payload: HostListBox(elements, isMutable: isMutable),
            isHost: true
        ))
    }

    private static func boxedBoolean(_ value: Bool) -> RVal {
        .obj(ObjInstance(
            dexType: "Ljava/lang/Boolean;",
            payload: value,
            isHost: true
        ))
    }

    private static func boxedInteger(_ value: Int32) -> RVal {
        .obj(ObjInstance(
            dexType: "Ljava/lang/Integer;",
            payload: value,
            isHost: true
        ))
    }

    private static func registerPrimitiveBoxes(_ bridge: HostBridge) {
        bridge.register(
            class: "Ljava/lang/Boolean;",
            "valueOf",
            prototype: "(Z)Ljava/lang/Boolean;",
            isStatic: true
        ) { _, args in
            guard case let .int(value) = try argument(args, 0, "Boolean.valueOf") else {
                throw VMError.verify("Boolean.valueOf argument")
            }
            return boxedBoolean(value != 0)
        }
        bridge.register(class: "Ljava/lang/Boolean;", "booleanValue", prototype: "()Z") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Boolean.booleanValue"),
                  let value = object.payload as? Bool else {
                throw VMError.verify("Boolean.booleanValue receiver")
            }
            return .int(value ? 1 : 0)
        }
        bridge.register(
            class: "Ljava/lang/Boolean;",
            "hashCode",
            prototype: "(Z)I",
            isStatic: true
        ) { _, args in
            guard case let .int(value) = try argument(args, 0, "Boolean.hashCode") else {
                throw VMError.verify("Boolean.hashCode argument")
            }
            return .int(value == 0 ? 1237 : 1231)
        }
        bridge.register(
            class: "Lkotlin/coroutines/jvm/internal/Boxing;",
            "boxBoolean",
            prototype: "(Z)Ljava/lang/Boolean;",
            isStatic: true
        ) { _, args in
            guard case let .int(value) = try argument(args, 0, "Boxing.boxBoolean") else {
                throw VMError.verify("Boxing.boxBoolean argument")
            }
            return boxedBoolean(value != 0)
        }
        bridge.register(
            class: "Ljava/lang/Integer;",
            "valueOf",
            prototype: "(I)Ljava/lang/Integer;",
            isStatic: true
        ) { _, args in
            guard case let .int(value) = try argument(args, 0, "Integer.valueOf") else {
                throw VMError.verify("Integer.valueOf argument")
            }
            return boxedInteger(value)
        }
        bridge.register(class: "Ljava/lang/Integer;", "intValue", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Integer.intValue"),
                  let value = object.payload as? Int32 else {
                throw VMError.verify("Integer.intValue receiver")
            }
            return .int(value)
        }
    }

    private static func requireCollectionCapacity(_ count: Int, _ method: String) throws {
        guard count <= 1_000_000 else {
            throw VMError.verify("\(method) exceeds 1000000 collection elements")
        }
    }

    private static func registerCollectionSurface(_ bridge: HostBridge) {
        let collections = "Lkotlin/collections/CollectionsKt;"
        bridge.register(
            class: collections,
            "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            guard case let .arr(array) = try argument(args, 0, "CollectionsKt.listOf") else {
                throw VMError.verify("CollectionsKt.listOf array argument")
            }
            return hostList(array.elements, isMutable: false)
        }
        bridge.register(
            class: collections,
            "mutableListOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            guard case let .arr(array) = try argument(args, 0, "CollectionsKt.mutableListOf") else {
                throw VMError.verify("CollectionsKt.mutableListOf array argument")
            }
            return hostList(array.elements, isMutable: true)
        }
        bridge.register(
            class: collections,
            "emptyList",
            prototype: "()Ljava/util/List;",
            isStatic: true
        ) { _, _ in hostList([], isMutable: false) }
        bridge.register(
            class: collections,
            "listOfNotNull",
            prototype: "(Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            let value = try argument(args, 0, "CollectionsKt.listOfNotNull")
            return hostList(value.isNull ? [] : [value], isMutable: false)
        }
        bridge.register(
            class: collections,
            "firstOrNull",
            prototype: "(Ljava/util/List;)Ljava/lang/Object;",
            isStatic: true
        ) { _, args in
            try listBox(args, "CollectionsKt.firstOrNull").elements.first ?? .null
        }
        bridge.register(
            class: collections,
            "collectionSizeOrDefault",
            prototype: "(Ljava/lang/Iterable;I)I",
            isStatic: true
        ) { _, args in
            if case let .obj(object) = try argument(args, 0, "CollectionsKt.collectionSizeOrDefault"),
               let list = object.payload as? HostListBox {
                return .int(Int32(clamping: list.elements.count))
            }
            guard case let .int(defaultValue) = try argument(
                args, 1, "CollectionsKt.collectionSizeOrDefault"
            ) else {
                throw VMError.verify("CollectionsKt.collectionSizeOrDefault default argument")
            }
            return .int(defaultValue)
        }
        bridge.register(
            class: collections,
            "createListBuilder",
            prototype: "()Ljava/util/List;",
            isStatic: true
        ) { _, _ in hostList([], isMutable: true) }
        bridge.register(
            class: collections,
            "build",
            prototype: "(Ljava/util/List;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            let list = try listBox(args, "CollectionsKt.build")
            list.isMutable = false
            return try argument(args, 0, "CollectionsKt.build")
        }
        bridge.register(
            class: collections,
            "addAll",
            prototype: "(Ljava/util/Collection;Ljava/lang/Iterable;)Z",
            isStatic: true
        ) { _, args in
            let destination = try listBox(args, "CollectionsKt.addAll")
            let source = try listBox(args, "CollectionsKt.addAll", index: 1)
            guard destination.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable list"))
            }
            try requireCollectionCapacity(
                destination.elements.count + source.elements.count,
                "CollectionsKt.addAll"
            )
            guard !source.elements.isEmpty else { return .int(0) }
            destination.elements.append(contentsOf: source.elements)
            return .int(1)
        }

        let mutableListClasses = [
            "Ljava/util/ArrayList;",
            "Ljava/util/concurrent/CopyOnWriteArrayList;",
        ]
        for descriptor in mutableListClasses {
            bridge.objectFactories[descriptor] = { _ in
                hostList([], isMutable: true, descriptor: descriptor)
            }
            bridge.register(class: descriptor, "<init>", prototype: "()V") { _, args in
                let list = try listBox(args, "\(descriptor).<init>")
                list.elements.removeAll(keepingCapacity: false)
                list.isMutable = true
                return .null
            }
        }
        bridge.register(class: "Ljava/util/ArrayList;", "<init>", prototype: "(I)V") { _, args in
            let list = try listBox(args, "ArrayList.<init>")
            guard case let .int(capacity) = try argument(args, 1, "ArrayList.<init>"), capacity >= 0 else {
                throw DEXThrowable(string("IllegalArgumentException: negative ArrayList capacity"))
            }
            try requireCollectionCapacity(Int(capacity), "ArrayList.<init>")
            list.elements.removeAll(keepingCapacity: false)
            list.elements.reserveCapacity(Int(capacity))
            list.isMutable = true
            return .null
        }

        let addClasses = [
            "Ljava/util/Collection;", "Ljava/util/List;", "Ljava/util/ArrayList;",
            "Ljava/util/concurrent/CopyOnWriteArrayList;",
        ]
        for descriptor in addClasses {
            bridge.register(
                class: descriptor,
                "add",
                prototype: "(Ljava/lang/Object;)Z"
            ) { _, args in
                let list = try listBox(args, "\(descriptor).add")
                guard list.isMutable else {
                    throw DEXThrowable(string("UnsupportedOperationException: immutable list"))
                }
                try requireCollectionCapacity(list.elements.count + 1, "\(descriptor).add")
                list.elements.append(try argument(args, 1, "\(descriptor).add"))
                return .int(1)
            }
        }
        for descriptor in ["Ljava/util/List;", "Ljava/util/ArrayList;"] {
            bridge.register(class: descriptor, "get", prototype: "(I)Ljava/lang/Object;") { _, args in
                let list = try listBox(args, "\(descriptor).get")
                guard case let .int(index) = try argument(args, 1, "\(descriptor).get"),
                      index >= 0, Int(index) < list.elements.count else {
                    throw DEXThrowable(string("IndexOutOfBoundsException"))
                }
                return list.elements[Int(index)]
            }
        }
        bridge.register(
            class: "Ljava/util/List;",
            "addAll",
            prototype: "(Ljava/util/Collection;)Z"
        ) { _, args in
            let destination = try listBox(args, "List.addAll")
            let source = try listBox(args, "List.addAll", index: 1)
            guard destination.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable list"))
            }
            try requireCollectionCapacity(destination.elements.count + source.elements.count, "List.addAll")
            guard !source.elements.isEmpty else { return .int(0) }
            destination.elements.append(contentsOf: source.elements)
            return .int(1)
        }
        bridge.register(
            class: "Ljava/util/List;",
            "remove",
            prototype: "(Ljava/lang/Object;)Z"
        ) { _, args in
            let list = try listBox(args, "List.remove")
            guard list.isMutable else {
                throw DEXThrowable(string("UnsupportedOperationException: immutable list"))
            }
            let target = try argument(args, 1, "List.remove")
            guard let index = list.elements.firstIndex(where: { javaValueEquals($0, target) }) else {
                return .int(0)
            }
            list.elements.remove(at: index)
            return .int(1)
        }
        for descriptor in ["Ljava/util/Collection;", "Ljava/util/ArrayList;"] {
            bridge.register(class: descriptor, "isEmpty", prototype: "()Z") { _, args in
                .int(try listBox(args, "\(descriptor).isEmpty").elements.isEmpty ? 1 : 0)
            }
        }
        bridge.register(class: "Ljava/util/ArrayList;", "size", prototype: "()I") { _, args in
            .int(Int32(clamping: try listBox(args, "ArrayList.size").elements.count))
        }
        bridge.register(
            class: "Ljava/util/ArrayList;",
            "toArray",
            prototype: "([Ljava/lang/Object;)[Ljava/lang/Object;"
        ) { _, args in
            let list = try listBox(args, "ArrayList.toArray")
            guard case let .arr(destination) = try argument(args, 1, "ArrayList.toArray") else {
                throw VMError.verify("ArrayList.toArray destination")
            }
            if destination.elements.count < list.elements.count {
                return .arr(ArrInstance(elemDescriptor: destination.elemDescriptor, elements: list.elements))
            }
            for index in list.elements.indices { destination.elements[index] = list.elements[index] }
            if destination.elements.count > list.elements.count {
                destination.elements[list.elements.count] = .null
            }
            return .arr(destination)
        }

        let iterableClasses = [
            "Ljava/lang/Iterable;",
            "Ljava/util/concurrent/CopyOnWriteArrayList;",
        ]
        for descriptor in iterableClasses {
            bridge.register(
                class: descriptor,
                "iterator",
                prototype: "()Ljava/util/Iterator;"
            ) { _, args in
                let list = try listBox(args, "\(descriptor).iterator")
                return .obj(ObjInstance(
                    dexType: "Ljava/util/Iterator;",
                    payload: HostIteratorBox(list.elements),
                    isHost: true
                ))
            }
        }
        bridge.register(class: "Ljava/util/Iterator;", "hasNext", prototype: "()Z") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Iterator.hasNext"),
                  let iterator = object.payload as? HostIteratorBox else {
                throw VMError.verify("Iterator.hasNext receiver")
            }
            return .int(iterator.index < iterator.elements.count ? 1 : 0)
        }
        bridge.register(
            class: "Ljava/util/Iterator;",
            "next",
            prototype: "()Ljava/lang/Object;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Iterator.next"),
                  let iterator = object.payload as? HostIteratorBox else {
                throw VMError.verify("Iterator.next receiver")
            }
            guard iterator.index < iterator.elements.count else {
                throw DEXThrowable(string("NoSuchElementException"))
            }
            defer { iterator.index += 1 }
            return iterator.elements[iterator.index]
        }
        bridge.register(
            class: "Lkotlin/collections/MapsKt;",
            "emptyMap",
            prototype: "()Ljava/util/Map;",
            isStatic: true
        ) { _, _ in
            .obj(ObjInstance(
                dexType: "Ljava/util/Map;",
                payload: HostMapBox(isMutable: false),
                isHost: true
            ))
        }
    }

    private static func registerFilterSurface(_ bridge: HostBridge) {
        let checkBox = "Leu/kanade/tachiyomi/source/model/Filter$CheckBox;"
        let group = "Leu/kanade/tachiyomi/source/model/Filter$Group;"
        let header = "Leu/kanade/tachiyomi/source/model/Filter$Header;"
        let separator = "Leu/kanade/tachiyomi/source/model/Filter$Separator;"
        let sort = "Leu/kanade/tachiyomi/source/model/Filter$Sort;"
        let textFilter = "Leu/kanade/tachiyomi/source/model/Filter$Text;"
        let filterList = "Leu/kanade/tachiyomi/source/model/FilterList;"
        for descriptor in [checkBox, group, header, separator, sort, textFilter, filterList] {
            bridge.objectFactories[descriptor] = { _ in
                .obj(ObjInstance(dexType: descriptor, isHost: true))
            }
        }

        bridge.register(
            class: checkBox,
            "<init>",
            prototype: "(Ljava/lang/String;ZILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.CheckBox.<init>"),
                  case let .int(rawState) = try argument(args, 2, "Filter.CheckBox.<init>"),
                  case let .int(mask) = try argument(args, 3, "Filter.CheckBox.<init>") else {
                throw VMError.verify("Filter.CheckBox constructor arguments")
            }
            let state = mask & 0x2 == 0 ? rawState != 0 : false
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.CheckBox.<init>")),
                state: boxedBoolean(state)
            )
            return .null
        }
        bridge.register(class: checkBox, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.CheckBox.getState")
        }

        bridge.register(
            class: group,
            "<init>",
            prototype: "(Ljava/lang/String;Ljava/util/List;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Group.<init>") else {
                throw VMError.verify("Filter.Group constructor receiver")
            }
            _ = try listBox(args, "Filter.Group.<init>", index: 2)
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.Group.<init>")),
                state: try argument(args, 2, "Filter.Group.<init>")
            )
            return .null
        }
        bridge.register(class: group, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Group.getState")
        }

        bridge.register(
            class: header,
            "<init>",
            prototype: "(Ljava/lang/String;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Header.<init>") else {
                throw VMError.verify("Filter.Header constructor receiver")
            }
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.Header.<init>")),
                state: .null
            )
            return .null
        }
        bridge.register(
            class: separator,
            "<init>",
            prototype: "(Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Separator.<init>") else {
                throw VMError.verify("Filter.Separator constructor receiver")
            }
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.Separator.<init>")),
                state: .null
            )
            return .null
        }

        bridge.register(
            class: sort,
            "<init>",
            prototype: "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Sort.<init>"),
                  case .arr = try argument(args, 2, "Filter.Sort.<init>") else {
                throw VMError.verify("Filter.Sort constructor arguments")
            }
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.Sort.<init>")),
                state: try argument(args, 3, "Filter.Sort.<init>")
            )
            return .null
        }
        bridge.register(class: sort, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Sort.getState")
        }

        bridge.register(
            class: textFilter,
            "<init>",
            prototype: "(Ljava/lang/String;Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.Text.<init>"),
                  case let .int(mask) = try argument(args, 3, "Filter.Text.<init>") else {
                throw VMError.verify("Filter.Text constructor arguments")
            }
            let state = mask & 0x2 == 0
                ? try argument(args, 2, "Filter.Text.<init>")
                : string("")
            object.payload = FilterStateBox(
                name: vmStringValue(try argument(args, 1, "Filter.Text.<init>")),
                state: state
            )
            return .null
        }
        bridge.register(class: textFilter, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Text.getState")
        }

        bridge.register(
            class: filterList,
            "<init>",
            prototype: "(Ljava/util/List;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "FilterList.<init>") else {
                throw VMError.verify("FilterList constructor receiver")
            }
            let source = try listBox(args, "FilterList.<init>", index: 1)
            object.payload = HostListBox(source.elements, isMutable: true)
            return .null
        }
        bridge.register(
            class: filterList,
            "<init>",
            prototype: "([Leu/kanade/tachiyomi/source/model/Filter;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "FilterList.<init>"),
                  case let .arr(array) = try argument(args, 1, "FilterList.<init>") else {
                throw VMError.verify("FilterList array constructor arguments")
            }
            object.payload = HostListBox(array.elements, isMutable: true)
            return .null
        }
        bridge.register(
            class: filterList,
            "iterator",
            prototype: "()Ljava/util/Iterator;"
        ) { _, args in
            let list = try listBox(args, "FilterList.iterator")
            return .obj(ObjInstance(
                dexType: "Ljava/util/Iterator;",
                payload: HostIteratorBox(list.elements),
                isHost: true
            ))
        }
    }

    private static func filterState(_ args: [RVal], _ method: String) throws -> RVal {
        guard case let .obj(object) = try argument(args, 0, method),
              let filter = object.payload as? FilterStateBox else {
            throw VMError.verify("\(method) receiver")
        }
        return filter.state
    }

    private static func javaValueEquals(_ lhs: RVal, _ rhs: RVal) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.int(a), .int(b)): return a == b
        case let (.long(a), .long(b)): return a == b
        case let (.float(a), .float(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.obj(a), .obj(b)):
            if a.dexType == "Ljava/lang/String;", b.dexType == "Ljava/lang/String;" {
                return (a.payload as? String) == (b.payload as? String)
            }
            return a === b
        case let (.arr(a), .arr(b)): return a === b
        default: return false
        }
    }

    private static func isInstance(_ descriptor: String, of expected: String, dex: DexFile) -> Bool {
        var current: String? = descriptor
        var visited: Set<String> = []
        while let candidate = current, visited.insert(candidate).inserted {
            if candidate == expected { return true }
            guard let index = dex.classIndexByDescriptor[candidate] else { return false }
            let superclassIndex = dex.classDefs[index].superclassIndex
            guard superclassIndex >= 0, superclassIndex < dex.typeDescriptors.count else { return false }
            current = dex.typeDescriptors[superclassIndex]
        }
        return false
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
