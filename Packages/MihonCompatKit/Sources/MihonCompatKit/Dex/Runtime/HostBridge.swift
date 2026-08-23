import Foundation
import SwiftSoup

/// Host method bridge: the only path from interpreted DEX to native Swift
/// (mission §23). Registrations are explicit; the VM never hardcodes classes.
public final class HostBridge {
    public typealias Method = (_ vm: DexInterpreter, _ args: [RVal]) throws -> RVal
    public typealias AsyncMethod = (_ vm: DexInterpreter, _ args: [RVal]) async throws -> RVal

    struct Registration {
        let isStatic: Bool
        let method: Method
    }

    struct AsyncRegistration {
        let isStatic: Bool
        let method: AsyncMethod
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

    private final class FormBodyBuilderBox {
        var fields: [CompatHTTPFormField] = []
        var utf8Bytes = 0
    }

    private struct CompressionInterceptorBox {
        let algorithms: [RVal]
    }

    private final class HeadersBuilderBox {
        var headers: [CompatHTTPHeader]

        init(headers: [CompatHTTPHeader] = []) {
            self.headers = headers
        }
    }

    private struct HeadersBox {
        let headers: [CompatHTTPHeader]
    }

    private struct HttpUrlBox {
        let value: String
        let host: String
        let pathSegments: [String]
    }

    private struct MediaTypeBox {
        let value: String
    }

    private final class CacheControlBuilderBox {
        var maxAgeSeconds: Int?
    }

    private struct CacheControlBox {
        let policy: CompatHTTPCachePolicy
    }

    private final class RequestBuilderBox {
        var url: String?
        var method = "GET"
        var headers: [CompatHTTPHeader] = []
        var body: CompatHTTPRequestBody?
        var cachePolicy: CompatHTTPCachePolicy?
    }

    private final class CallBox {
        let request: CompatHTTPRequest
        let client: OkHttpClientBox
        var isCancelled = false

        init(request: CompatHTTPRequest, client: OkHttpClientBox) {
            self.request = request
            self.client = client
        }
    }

    private final class ResponseBodyBox {
        let bytes: [UInt8]
        let contentType: String?
        var offset = 0
        var isClosed = false

        init(bytes: [UInt8], contentType: String?) {
            self.bytes = bytes
            self.contentType = contentType
        }
    }

    private final class ResponseBox {
        let value: CompatHTTPResponse
        let request: CompatHTTPRequest
        let body: RVal

        init(value: CompatHTTPResponse, request: CompatHTTPRequest, body: RVal) {
            self.value = value
            self.request = request
            self.body = body
        }
    }

    private final class SMangaBox {
        var value: SMangaCompat

        init(_ value: SMangaCompat = .init()) {
            self.value = value
        }
    }

    private struct MangasPageBox {
        let mangas: [RVal]
        let hasNextPage: Bool
    }

    private final class OkHttpClientBox {
        let interceptors: [RVal]
        let networkInterceptors: [RVal]

        init(interceptors: [RVal] = [], networkInterceptors: [RVal] = []) {
            self.interceptors = interceptors
            self.networkInterceptors = networkInterceptors
        }
    }

    private final class OkHttpClientBuilderBox {
        let interceptors: HostListBox
        let networkInterceptors: HostListBox

        init(interceptors: [RVal], networkInterceptors: [RVal]) {
            self.interceptors = HostListBox(interceptors, isMutable: true)
            self.networkInterceptors = HostListBox(networkInterceptors, isMutable: true)
        }
    }

    private struct NetworkHelperBox {
        let client: RVal
    }

    /// Exact `(declaring class, name, prototype)` registrations. Ignoring the
    /// prototype would let an untrusted overload reach the wrong native body.
    private var methods: [MethodKey: Registration] = [:]
    private var asyncMethods: [MethodKey: AsyncRegistration] = [:]
    /// Per-source network identities. They hold only pure request-building
    /// state and share only this bridge's explicitly injected transport.
    private var sourceNetworks: [ObjectIdentifier: RVal] = [:]
    private let transport: (any CompatHTTPTransport)?
    private let htmlPolicy: CompatHTMLPolicy

    /// Most recent request handed to OkHttpClient.newCall. This is an inert,
    /// transport-neutral value: reaching it never performs network I/O.
    public private(set) var lastPreparedRequest: CompatHTTPRequest?

    /// Static field storage for host classes (sget/sput on host classes).
    public var staticFields: [String: RVal] = [:]

    /// new-instance factories for host classes (StringBuilder, …).
    public var objectFactories: [String: (DexInterpreter) throws -> RVal] = [:]

    public init(
        transport: (any CompatHTTPTransport)? = nil,
        htmlPolicy: CompatHTMLPolicy = .init()
    ) {
        self.transport = transport
        self.htmlPolicy = htmlPolicy
    }

    public func register(class descriptor: String, _ methodName: String,
                         prototype: String, isStatic: Bool = false,
                         _ body: @escaping Method) {
        let key = MethodKey(classDescriptor: descriptor, name: methodName, prototype: prototype)
        asyncMethods.removeValue(forKey: key)
        methods[key] = Registration(isStatic: isStatic, method: body)
    }

    /// Registers a host capability that suspends without blocking the
    /// interpreter thread. It is executed only through a VM async entry point.
    public func registerAsync(class descriptor: String, _ methodName: String,
                              prototype: String, isStatic: Bool = false,
                              _ body: @escaping AsyncMethod) {
        let key = MethodKey(classDescriptor: descriptor, name: methodName, prototype: prototype)
        methods.removeValue(forKey: key)
        asyncMethods[key] = AsyncRegistration(isStatic: isStatic, method: body)
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

    func resolveAsync(class descriptor: String, _ methodName: String,
                      prototype: String, isStatic: Bool) -> AsyncMethod? {
        guard let registration = asyncMethods[
            MethodKey(classDescriptor: descriptor, name: methodName, prototype: prototype)
        ], registration.isStatic == isStatic else { return nil }
        return registration.method
    }

    func resolveAsync(_ reference: DexFile.MethodRef, isStatic: Bool) -> AsyncMethod? {
        resolveAsync(
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
    public static func minimal(
        transport: (any CompatHTTPTransport)? = nil,
        htmlPolicy: CompatHTMLPolicy = .init()
    ) -> HostBridge {
        let bridge = HostBridge(transport: transport, htmlPolicy: htmlPolicy)

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
        bridge.register(
            class: intrinsics,
            "areEqual",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Z",
            isStatic: true
        ) { _, args in
            let lhs = try argument(args, 0, "Intrinsics.areEqual")
            let rhs = try argument(args, 1, "Intrinsics.areEqual")
            return .int(javaValueEquals(lhs, rhs) ? 1 : 0)
        }
        bridge.register(
            class: "Lkotlin/coroutines/jvm/internal/SpillingKt;",
            "nullOutSpilledVariable",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
            isStatic: true
        ) { _, _ in .null }

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
            class: "Lkotlin/text/StringsKt;",
            "trim",
            prototype: "(Ljava/lang/CharSequence;)Ljava/lang/CharSequence;",
            isStatic: true
        ) { _, args in
            let value = vmStringValue(try argument(args, 0, "StringsKt.trim"))
            return string(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        bridge.register(
            class: "Ljava/net/URLEncoder;",
            "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true
        ) { _, args in
            let value = try requiredString(args, 0, "URLEncoder.encode")
            let charset = try requiredString(args, 1, "URLEncoder.encode")
            guard charset.caseInsensitiveCompare("UTF-8") == .orderedSame ||
                    charset.caseInsensitiveCompare("UTF8") == .orderedSame else {
                throw hostThrowable(
                    "Ljava/io/UnsupportedEncodingException;",
                    "unsupported URL-encoding charset"
                )
            }
            guard value.utf8.count <= 8_192 else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "URL-encoding input is too long"
                )
            }
            return string(formURLEncodeUTF8(value))
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
        Self.registerKotlinDurationSurface(bridge)
        Self.registerOkHttpRequestSurface(bridge)
        Self.registerOkHttpResponseSurface(bridge)
        Self.registerHTMLSurface(bridge)
        Self.registerSourceModelSurface(bridge)
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

    private static func requiredString(_ args: [RVal], _ index: Int,
                                       _ method: String) throws -> String {
        let value = try argument(args, index, method)
        guard let result = stringPayload(value) else {
            if value.isNull {
                throw DEXThrowable(string("NullPointerException: \(method) argument \(index)"))
            }
            throw VMError.verify("\(method) argument \(index) is not java.lang.String")
        }
        return result
    }

    private static func optionalString(_ args: [RVal], _ index: Int,
                                       _ method: String) throws -> String? {
        let value = try argument(args, index, method)
        if value.isNull { return nil }
        guard let result = stringPayload(value) else {
            throw VMError.verify("\(method) argument \(index) is not java.lang.String")
        }
        return result
    }

    private static func validateHTTPHeader(name: String, value: String,
                                           method: String) throws {
        let validName = !name.isEmpty && name.utf8.count <= 8_192 && name.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7e && $0.value != 0x3a
        }
        guard validName else {
            throw DEXThrowable(string("IllegalArgumentException: invalid header name in \(method)"))
        }
        guard value.utf8.count <= 65_536,
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x0a || $0.value == 0x0d }) else {
            throw DEXThrowable(string("IllegalArgumentException: invalid header value in \(method)"))
        }
    }

    private static func parsedHTTPURL(_ value: String) -> HttpUrlBox? {
        guard !value.isEmpty,
              value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              let components = URLComponents(string: value),
              let rawScheme = components.scheme,
              ["http", "https"].contains(rawScheme.lowercased()),
              let host = components.host,
              !host.isEmpty,
              components.url != nil else { return nil }

        let path = components.path
        let pathSegments: [String]
        if path.isEmpty || path == "/" {
            pathSegments = [""]
        } else {
            let body = path.hasPrefix("/") ? String(path.dropFirst()) : path
            pathSegments = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        }
        return HttpUrlBox(value: value, host: host, pathSegments: pathSegments)
    }

    private static func kotlinDurationSeconds(_ rawValue: Int64,
                                              method: String) throws -> Int {
        if rawValue == Int64.max { return Int(Int32.max) }
        let magnitude = rawValue >> 1
        guard magnitude >= 0 else {
            throw DEXThrowable(string("IllegalArgumentException: negative duration in \(method)"))
        }
        let seconds = rawValue & 1 == 0 ? magnitude / 1_000_000_000 : magnitude / 1_000
        return Int(min(seconds, Int64(Int32.max)))
    }

    private static func validMediaType(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let essence = value.split(separator: ";", maxSplits: 1).first ?? ""
        let parts = essence.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
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

    private static func registerKotlinDurationSurface(_ bridge: HostBridge) {
        let durationUnit = "Lkotlin/time/DurationUnit;"
        let units: [(name: String, nanoseconds: Int64, milliseconds: Int64?)] = [
            ("NANOSECONDS", 1, nil),
            ("MICROSECONDS", 1_000, nil),
            ("MILLISECONDS", 1_000_000, 1),
            ("SECONDS", 1_000_000_000, 1_000),
            ("MINUTES", 60_000_000_000, 60_000),
            ("HOURS", 3_600_000_000_000, 3_600_000),
            ("DAYS", 86_400_000_000_000, 86_400_000),
        ]
        for unit in units {
            bridge.staticFields["\(durationUnit)->\(unit.name)"] = .obj(ObjInstance(
                dexType: durationUnit,
                payload: unit.name,
                isHost: true
            ))
        }

        func encode(_ value: Int64, unitName: String) throws -> Int64 {
            guard let unit = units.first(where: { $0.name == unitName }) else {
                throw VMError.verify("DurationKt.toDuration unit")
            }
            let maximumNanoseconds: Int64 = 4_611_686_018_426_999_999
            let nanos = value.multipliedReportingOverflow(by: unit.nanoseconds)
            if !nanos.overflow,
               nanos.partialValue >= -maximumNanoseconds,
               nanos.partialValue <= maximumNanoseconds {
                return nanos.partialValue << 1
            }

            let milliseconds: Int64
            if let multiplier = unit.milliseconds {
                let product = value.multipliedReportingOverflow(by: multiplier)
                milliseconds = product.overflow
                    ? (value < 0 ? -(Int64.max >> 1) : Int64.max >> 1)
                    : product.partialValue
            } else {
                milliseconds = value / (unit.nanoseconds == 1 ? 1_000_000 : 1_000)
            }
            let clamped = min(max(milliseconds, -(Int64.max >> 1)), Int64.max >> 1)
            return (clamped << 1) | 1
        }

        for prototype in [
            "(ILkotlin/time/DurationUnit;)J",
            "(JLkotlin/time/DurationUnit;)J",
        ] {
            bridge.register(
                class: "Lkotlin/time/DurationKt;",
                "toDuration",
                prototype: prototype,
                isStatic: true
            ) { _, args in
                let value: Int64
                switch try argument(args, 0, "DurationKt.toDuration") {
                case let .int(number): value = Int64(number)
                case let .long(number): value = number
                default: throw VMError.verify("DurationKt.toDuration value")
                }
                guard case let .obj(unitObject) = try argument(args, 1, "DurationKt.toDuration"),
                      let unitName = unitObject.payload as? String else {
                    throw VMError.verify("DurationKt.toDuration unit")
                }
                return .long(try encode(value, unitName: unitName))
            }
        }
        bridge.register(
            class: "Lkotlin/time/Duration;",
            "getInWholeMilliseconds-impl",
            prototype: "(J)J",
            isStatic: true
        ) { _, args in
            guard case let .long(rawValue) = try argument(args, 0, "Duration.getInWholeMilliseconds") else {
                throw VMError.verify("Duration.getInWholeMilliseconds value")
            }
            return .long(rawValue & 1 == 0 ? (rawValue >> 1) / 1_000_000 : rawValue >> 1)
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

    private static func registerOkHttpRequestSurface(_ bridge: HostBridge) {
        let httpSource = "Leu/kanade/tachiyomi/source/online/HttpSource;"
        bridge.register(
            class: httpSource,
            "getNetwork",
            prototype: "()Leu/kanade/tachiyomi/network/NetworkHelper;"
        ) { [weak bridge] _, args in
            guard let bridge,
                  case let .obj(source) = try argument(args, 0, "HttpSource.getNetwork") else {
                throw VMError.verify("HttpSource.getNetwork receiver")
            }
            return bridge.networkHelper(for: source)
        }
        bridge.register(
            class: httpSource,
            "getHeaders",
            prototype: "()Lokhttp3/Headers;"
        ) { _, _ in
            .obj(ObjInstance(
                dexType: "Lokhttp3/Headers;",
                payload: HeadersBox(headers: []),
                isHost: true
            ))
        }
        bridge.register(
            class: httpSource,
            "headersBuilder",
            prototype: "()Lokhttp3/Headers$Builder;"
        ) { _, _ in
            .obj(ObjInstance(
                dexType: "Lokhttp3/Headers$Builder;",
                payload: HeadersBuilderBox(),
                isHost: true
            ))
        }
        bridge.register(
            class: "Leu/kanade/tachiyomi/network/NetworkHelper;",
            "getClient",
            prototype: "()Lokhttp3/OkHttpClient;"
        ) { _, args in
            guard case let .obj(helper) = try argument(args, 0, "NetworkHelper.getClient"),
                  let network = helper.payload as? NetworkHelperBox else {
                throw VMError.verify("NetworkHelper.getClient receiver")
            }
            return network.client
        }

        let okHttpClient = "Lokhttp3/OkHttpClient;"
        let okHttpClientBuilder = "Lokhttp3/OkHttpClient$Builder;"
        bridge.register(
            class: okHttpClient,
            "newBuilder",
            prototype: "()Lokhttp3/OkHttpClient$Builder;"
        ) { _, args in
            guard case let .obj(clientObject) = try argument(args, 0, "OkHttpClient.newBuilder"),
                  let client = clientObject.payload as? OkHttpClientBox else {
                throw VMError.verify("OkHttpClient.newBuilder receiver")
            }
            return .obj(ObjInstance(
                dexType: okHttpClientBuilder,
                payload: OkHttpClientBuilderBox(
                    interceptors: client.interceptors,
                    networkInterceptors: client.networkInterceptors
                ),
                isHost: true
            ))
        }
        bridge.register(
            class: okHttpClient,
            "newCall",
            prototype: "(Lokhttp3/Request;)Lokhttp3/Call;"
        ) { [weak bridge] _, args in
            guard case let .obj(clientObject) = try argument(args, 0, "OkHttpClient.newCall"),
                  let client = clientObject.payload as? OkHttpClientBox,
                  case let .obj(requestObject) = try argument(args, 1, "OkHttpClient.newCall"),
                  let request = requestObject.payload as? CompatHTTPRequest else {
                throw VMError.verify("OkHttpClient.newCall arguments")
            }
            bridge?.lastPreparedRequest = request
            return .obj(ObjInstance(
                dexType: "Lokhttp3/Call;",
                payload: CallBox(request: request, client: client),
                isHost: true
            ))
        }
        bridge.register(
            class: "Lokhttp3/Call;",
            "isCanceled",
            prototype: "()Z"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Call.isCanceled"),
                  let call = object.payload as? CallBox else {
                throw VMError.verify("Call.isCanceled receiver")
            }
            return .int(call.isCancelled ? 1 : 0)
        }
        bridge.register(class: "Lokhttp3/Call;", "cancel", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Call.cancel"),
                  let call = object.payload as? CallBox else {
                throw VMError.verify("Call.cancel receiver")
            }
            call.isCancelled = true
            return .null
        }
        if let transport = bridge.transport {
            for (name, requiresSuccess) in [("await", false), ("awaitSuccess", true)] {
                bridge.registerAsync(
                    class: "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;",
                    name,
                    prototype: "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                    isStatic: true
                ) { _, args in
                    guard case let .obj(object) = try argument(
                        args,
                        0,
                        "OkHttpExtensions.\(name)"
                    ), let call = object.payload as? CallBox else {
                        throw VMError.verify("OkHttpExtensions.\(name) call argument")
                    }
                    return try await execute(
                        call,
                        transport: transport,
                        requiresSuccess: requiresSuccess
                    )
                }
            }
        }
        bridge.register(
            class: okHttpClientBuilder,
            "interceptors",
            prototype: "()Ljava/util/List;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "OkHttpClient.Builder.interceptors"),
                  let builder = object.payload as? OkHttpClientBuilderBox else {
                throw VMError.verify("OkHttpClient.Builder.interceptors receiver")
            }
            return .obj(ObjInstance(
                dexType: "Ljava/util/List;",
                payload: builder.interceptors,
                isHost: true
            ))
        }
        bridge.register(
            class: okHttpClientBuilder,
            "networkInterceptors",
            prototype: "()Ljava/util/List;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "OkHttpClient.Builder.networkInterceptors"),
                  let builder = object.payload as? OkHttpClientBuilderBox else {
                throw VMError.verify("OkHttpClient.Builder.networkInterceptors receiver")
            }
            return .obj(ObjInstance(
                dexType: "Ljava/util/List;",
                payload: builder.networkInterceptors,
                isHost: true
            ))
        }
        let interceptorAdds: [(String, KeyPath<OkHttpClientBuilderBox, HostListBox>)] = [
            ("addInterceptor", \.interceptors),
            ("addNetworkInterceptor", \.networkInterceptors),
        ]
        for (name, keyPath) in interceptorAdds {
            bridge.register(
                class: okHttpClientBuilder,
                name,
                prototype: "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;"
            ) { _, args in
                guard case let .obj(object) = try argument(args, 0, "OkHttpClient.Builder.\(name)"),
                      let builder = object.payload as? OkHttpClientBuilderBox else {
                    throw VMError.verify("OkHttpClient.Builder.\(name) receiver")
                }
                let list = builder[keyPath: keyPath]
                try requireCollectionCapacity(list.elements.count + 1, "OkHttpClient.Builder.\(name)")
                list.elements.append(try argument(args, 1, "OkHttpClient.Builder.\(name)"))
                return .obj(object)
            }
        }
        bridge.register(
            class: okHttpClientBuilder,
            "build",
            prototype: "()Lokhttp3/OkHttpClient;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "OkHttpClient.Builder.build"),
                  let builder = object.payload as? OkHttpClientBuilderBox else {
                throw VMError.verify("OkHttpClient.Builder.build receiver")
            }
            return .obj(ObjInstance(
                dexType: okHttpClient,
                payload: OkHttpClientBox(
                    interceptors: builder.interceptors.elements,
                    networkInterceptors: builder.networkInterceptors.elements
                ),
                isHost: true
            ))
        }

        let compressionInterceptor = "Lokhttp3/CompressionInterceptor;"
        bridge.register(
            class: compressionInterceptor,
            "<init>",
            prototype: "([Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "CompressionInterceptor.<init>"),
                  case let .arr(algorithms) = try argument(args, 1, "CompressionInterceptor.<init>"),
                  algorithms.elements.count <= 16 else {
                throw VMError.verify("CompressionInterceptor constructor arguments")
            }
            object.payload = CompressionInterceptorBox(algorithms: algorithms.elements)
            return .null
        }

        let headers = "Lokhttp3/Headers;"
        let headersBuilder = "Lokhttp3/Headers$Builder;"
        bridge.register(
            class: headersBuilder,
            "set",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Headers.Builder.set"),
                  let builder = object.payload as? HeadersBuilderBox else {
                throw VMError.verify("Headers.Builder.set receiver")
            }
            let name = try requiredString(args, 1, "Headers.Builder.set")
            let value = try requiredString(args, 2, "Headers.Builder.set")
            try validateHTTPHeader(name: name, value: value, method: "Headers.Builder.set")
            var next = builder.headers.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
            guard next.count < 10_000 else {
                throw VMError.verify("Headers.Builder.set exceeds 10000 headers")
            }
            next.append(CompatHTTPHeader(name: name, value: value))
            let byteCount = next.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard byteCount <= 1_048_576 else {
                throw VMError.verify("Headers.Builder.set exceeds 1048576 UTF-8 bytes")
            }
            builder.headers = next
            return .obj(object)
        }
        bridge.register(
            class: headersBuilder,
            "build",
            prototype: "()Lokhttp3/Headers;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Headers.Builder.build"),
                  let builder = object.payload as? HeadersBuilderBox else {
                throw VMError.verify("Headers.Builder.build receiver")
            }
            return .obj(ObjInstance(
                dexType: headers,
                payload: HeadersBox(headers: builder.headers),
                isHost: true
            ))
        }

        let cacheControl = "Lokhttp3/CacheControl;"
        let cacheControlBuilder = "Lokhttp3/CacheControl$Builder;"
        bridge.objectFactories[cacheControlBuilder] = { _ in
            .obj(ObjInstance(
                dexType: cacheControlBuilder,
                payload: CacheControlBuilderBox(),
                isHost: true
            ))
        }
        bridge.register(class: cacheControlBuilder, "<init>", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "CacheControl.Builder.<init>") else {
                throw VMError.verify("CacheControl.Builder constructor receiver")
            }
            object.payload = CacheControlBuilderBox()
            return .null
        }
        bridge.register(
            class: cacheControlBuilder,
            "maxAge-LRDsOJo",
            prototype: "(J)Lokhttp3/CacheControl$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "CacheControl.Builder.maxAge"),
                  let builder = object.payload as? CacheControlBuilderBox,
                  case let .long(rawDuration) = try argument(args, 1, "CacheControl.Builder.maxAge") else {
                throw VMError.verify("CacheControl.Builder.maxAge arguments")
            }
            builder.maxAgeSeconds = try kotlinDurationSeconds(
                rawDuration,
                method: "CacheControl.Builder.maxAge"
            )
            return .obj(object)
        }
        bridge.register(
            class: cacheControlBuilder,
            "build",
            prototype: "()Lokhttp3/CacheControl;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "CacheControl.Builder.build"),
                  let builder = object.payload as? CacheControlBuilderBox else {
                throw VMError.verify("CacheControl.Builder.build receiver")
            }
            return .obj(ObjInstance(
                dexType: cacheControl,
                payload: CacheControlBox(
                    policy: CompatHTTPCachePolicy(maxAgeSeconds: builder.maxAgeSeconds)
                ),
                isHost: true
            ))
        }
        bridge.register(
            class: cacheControl,
            "maxAgeSeconds",
            prototype: "()I"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "CacheControl.maxAgeSeconds"),
                  let box = object.payload as? CacheControlBox else {
                throw VMError.verify("CacheControl.maxAgeSeconds receiver")
            }
            return .int(Int32(clamping: box.policy.maxAgeSeconds ?? -1))
        }

        let httpUrl = "Lokhttp3/HttpUrl;"
        let httpUrlCompanion = "Lokhttp3/HttpUrl$Companion;"
        bridge.staticFields["\(httpUrl)->Companion"] = .obj(ObjInstance(
            dexType: httpUrlCompanion,
            isHost: true
        ))
        bridge.register(
            class: httpUrlCompanion,
            "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;"
        ) { _, args in
            let value = try requiredString(args, 1, "HttpUrl.Companion.get")
            guard let parsed = parsedHTTPURL(value) else {
                throw DEXThrowable(string("IllegalArgumentException: invalid HTTP URL"))
            }
            return .obj(ObjInstance(dexType: httpUrl, payload: parsed, isHost: true))
        }
        bridge.register(
            class: httpUrlCompanion,
            "parse",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;"
        ) { _, args in
            let value = try requiredString(args, 1, "HttpUrl.Companion.parse")
            guard let parsed = parsedHTTPURL(value) else { return .null }
            return .obj(ObjInstance(dexType: httpUrl, payload: parsed, isHost: true))
        }
        bridge.register(class: httpUrl, "host", prototype: "()Ljava/lang/String;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.host"),
                  let url = object.payload as? HttpUrlBox else {
                throw VMError.verify("HttpUrl.host receiver")
            }
            return string(url.host)
        }
        bridge.register(class: httpUrl, "pathSegments", prototype: "()Ljava/util/List;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.pathSegments"),
                  let url = object.payload as? HttpUrlBox else {
                throw VMError.verify("HttpUrl.pathSegments receiver")
            }
            return hostList(url.pathSegments.map(string), isMutable: false)
        }
        bridge.register(class: httpUrl, "toString", prototype: "()Ljava/lang/String;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.toString"),
                  let url = object.payload as? HttpUrlBox else {
                throw VMError.verify("HttpUrl.toString receiver")
            }
            return string(url.value)
        }

        let mediaType = "Lokhttp3/MediaType;"
        let mediaTypeCompanion = "Lokhttp3/MediaType$Companion;"
        bridge.staticFields["\(mediaType)->Companion"] = .obj(ObjInstance(
            dexType: mediaTypeCompanion,
            isHost: true
        ))
        bridge.register(
            class: mediaTypeCompanion,
            "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/MediaType;"
        ) { _, args in
            let value = try requiredString(args, 1, "MediaType.Companion.get")
            guard validMediaType(value) else {
                throw DEXThrowable(string("IllegalArgumentException: invalid media type"))
            }
            return .obj(ObjInstance(
                dexType: mediaType,
                payload: MediaTypeBox(value: value),
                isHost: true
            ))
        }

        let requestBody = "Lokhttp3/RequestBody;"
        let requestBodyCompanion = "Lokhttp3/RequestBody$Companion;"
        bridge.staticFields["\(requestBody)->Companion"] = .obj(ObjInstance(
            dexType: requestBodyCompanion,
            isHost: true
        ))
        bridge.register(
            class: requestBodyCompanion,
            "create",
            prototype: "(Ljava/lang/String;Lokhttp3/MediaType;)Lokhttp3/RequestBody;"
        ) { _, args in
            let value = try requiredString(args, 1, "RequestBody.Companion.create")
            guard value.utf8.count <= 1_048_576 else {
                throw VMError.verify("RequestBody.Companion.create exceeds 1048576 UTF-8 bytes")
            }
            let mediaTypeValue: String?
            switch try argument(args, 2, "RequestBody.Companion.create") {
            case .null:
                mediaTypeValue = nil
            case let .obj(object):
                guard let box = object.payload as? MediaTypeBox else {
                    throw VMError.verify("RequestBody.Companion.create media type")
                }
                mediaTypeValue = box.value
            default:
                throw VMError.verify("RequestBody.Companion.create media type")
            }
            return .obj(ObjInstance(
                dexType: requestBody,
                payload: CompatHTTPRequestBody.text(value: value, mediaType: mediaTypeValue),
                isHost: true
            ))
        }

        let request = "Lokhttp3/Request;"
        let requestBuilder = "Lokhttp3/Request$Builder;"
        bridge.objectFactories[requestBuilder] = { _ in
            .obj(ObjInstance(
                dexType: requestBuilder,
                payload: RequestBuilderBox(),
                isHost: true
            ))
        }
        bridge.register(class: requestBuilder, "<init>", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.<init>") else {
                throw VMError.verify("Request.Builder constructor receiver")
            }
            object.payload = RequestBuilderBox()
            return .null
        }
        bridge.register(
            class: requestBuilder,
            "url",
            prototype: "(Lokhttp3/HttpUrl;)Lokhttp3/Request$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.url"),
                  let builder = object.payload as? RequestBuilderBox,
                  case let .obj(urlObject) = try argument(args, 1, "Request.Builder.url"),
                  let url = urlObject.payload as? HttpUrlBox else {
                throw VMError.verify("Request.Builder.url arguments")
            }
            builder.url = url.value
            return .obj(object)
        }
        bridge.register(
            class: requestBuilder,
            "headers",
            prototype: "(Lokhttp3/Headers;)Lokhttp3/Request$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.headers"),
                  let builder = object.payload as? RequestBuilderBox,
                  case let .obj(headersObject) = try argument(args, 1, "Request.Builder.headers"),
                  let value = headersObject.payload as? HeadersBox else {
                throw VMError.verify("Request.Builder.headers arguments")
            }
            builder.headers = value.headers
            return .obj(object)
        }
        bridge.register(
            class: requestBuilder,
            "cacheControl",
            prototype: "(Lokhttp3/CacheControl;)Lokhttp3/Request$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.cacheControl"),
                  let builder = object.payload as? RequestBuilderBox,
                  case let .obj(cacheObject) = try argument(args, 1, "Request.Builder.cacheControl"),
                  let value = cacheObject.payload as? CacheControlBox else {
                throw VMError.verify("Request.Builder.cacheControl arguments")
            }
            builder.cachePolicy = value.policy
            return .obj(object)
        }
        bridge.register(
            class: requestBuilder,
            "post",
            prototype: "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.post"),
                  let builder = object.payload as? RequestBuilderBox,
                  case let .obj(bodyObject) = try argument(args, 1, "Request.Builder.post"),
                  let body = bodyObject.payload as? CompatHTTPRequestBody else {
                throw VMError.verify("Request.Builder.post arguments")
            }
            builder.method = "POST"
            builder.body = body
            return .obj(object)
        }
        bridge.register(
            class: requestBuilder,
            "build",
            prototype: "()Lokhttp3/Request;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.Builder.build"),
                  let builder = object.payload as? RequestBuilderBox,
                  let url = builder.url else {
                throw DEXThrowable(string("IllegalStateException: Request.url is required"))
            }
            return .obj(ObjInstance(
                dexType: request,
                payload: CompatHTTPRequest(
                    url: url,
                    method: builder.method,
                    headers: builder.headers,
                    body: builder.body,
                    cachePolicy: builder.cachePolicy
                ),
                isHost: true
            ))
        }
        bridge.register(class: request, "cacheControl", prototype: "()Lokhttp3/CacheControl;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.cacheControl"),
                  let value = object.payload as? CompatHTTPRequest else {
                throw VMError.verify("Request.cacheControl receiver")
            }
            return .obj(ObjInstance(
                dexType: cacheControl,
                payload: CacheControlBox(policy: value.cachePolicy ?? CompatHTTPCachePolicy()),
                isHost: true
            ))
        }
        bridge.register(
            class: request,
            "header",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.header"),
                  let value = object.payload as? CompatHTTPRequest else {
                throw VMError.verify("Request.header receiver")
            }
            let name = try requiredString(args, 1, "Request.header")
            guard let header = value.headers.reversed().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return .null }
            return string(header.value)
        }
        bridge.register(class: request, "method", prototype: "()Ljava/lang/String;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.method"),
                  let value = object.payload as? CompatHTTPRequest else {
                throw VMError.verify("Request.method receiver")
            }
            return string(value.method)
        }
        bridge.register(class: request, "url", prototype: "()Lokhttp3/HttpUrl;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Request.url"),
                  let value = object.payload as? CompatHTTPRequest,
                  let parsed = parsedHTTPURL(value.url) else {
                throw VMError.verify("Request.url receiver")
            }
            return .obj(ObjInstance(dexType: httpUrl, payload: parsed, isHost: true))
        }

        let formBuilder = "Lokhttp3/FormBody$Builder;"
        bridge.objectFactories[formBuilder] = { _ in
            .obj(ObjInstance(
                dexType: formBuilder,
                payload: FormBodyBuilderBox(),
                isHost: true
            ))
        }
        bridge.register(
            class: formBuilder,
            "<init>",
            prototype: "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "FormBody.Builder.<init>"),
                  case let .int(mask) = try argument(args, 2, "FormBody.Builder.<init>") else {
                throw VMError.verify("FormBody.Builder constructor arguments")
            }
            let charset = try argument(args, 1, "FormBody.Builder.<init>")
            guard mask & 0x1 != 0 || charset.isNull else {
                throw VMError.verify("FormBody.Builder supports UTF-8/default charset only")
            }
            object.payload = FormBodyBuilderBox()
            return .null
        }
        bridge.register(
            class: formBuilder,
            "add",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "FormBody.Builder.add"),
                  let builder = object.payload as? FormBodyBuilderBox else {
                throw VMError.verify("FormBody.Builder.add receiver")
            }
            let name = try requiredString(args, 1, "FormBody.Builder.add")
            let value = try requiredString(args, 2, "FormBody.Builder.add")
            guard builder.fields.count < 10_000 else {
                throw VMError.verify("FormBody.Builder exceeds 10000 fields")
            }
            let addedBytes = name.utf8.count + value.utf8.count
            guard addedBytes <= 1_048_576 - builder.utf8Bytes else {
                throw VMError.verify("FormBody.Builder exceeds 1048576 UTF-8 bytes")
            }
            builder.fields.append(CompatHTTPFormField(name: name, value: value))
            builder.utf8Bytes += addedBytes
            return .obj(object)
        }
        bridge.register(
            class: formBuilder,
            "build",
            prototype: "()Lokhttp3/FormBody;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "FormBody.Builder.build"),
                  let builder = object.payload as? FormBodyBuilderBox else {
                throw VMError.verify("FormBody.Builder.build receiver")
            }
            return .obj(ObjInstance(
                dexType: "Lokhttp3/FormBody;",
                payload: CompatHTTPRequestBody.form(fields: builder.fields),
                isHost: true
            ))
        }
    }

    private static func registerOkHttpResponseSurface(_ bridge: HostBridge) {
        let response = "Lokhttp3/Response;"
        let responseBody = "Lokhttp3/ResponseBody;"
        let bufferedSource = "Lokio/BufferedSource;"
        let httpException = "Leu/kanade/tachiyomi/network/HttpException;"

        func responseBox(_ args: [RVal], _ method: String) throws -> ResponseBox {
            guard case let .obj(object) = try argument(args, 0, method),
                  let box = object.payload as? ResponseBox else {
                throw VMError.verify("\(method) receiver")
            }
            return box
        }

        func bodyBox(_ args: [RVal], _ method: String) throws -> ResponseBodyBox {
            guard case let .obj(object) = try argument(args, 0, method),
                  let box = object.payload as? ResponseBodyBox else {
                throw VMError.verify("\(method) receiver")
            }
            return box
        }

        func read(_ box: ResponseBodyBox, count: Int?, close: Bool,
                  method: String) throws -> [UInt8] {
            guard !box.isClosed else {
                throw DEXThrowable(string("IllegalStateException: \(method) on closed body"))
            }
            let remaining = box.bytes.count - box.offset
            let requested = count ?? remaining
            guard requested >= 0 else {
                throw DEXThrowable(string("IllegalArgumentException: negative byte count"))
            }
            let length = min(requested, remaining)
            let result = Array(box.bytes[box.offset..<(box.offset + length)])
            box.offset += length
            if close { box.isClosed = true }
            return result
        }

        bridge.register(class: response, "code", prototype: "()I") { _, args in
            .int(Int32(clamping: try responseBox(args, "Response.code").value.statusCode))
        }
        bridge.register(class: response, "isSuccessful", prototype: "()Z") { _, args in
            let code = try responseBox(args, "Response.isSuccessful").value.statusCode
            return .int((200..<300).contains(code) ? 1 : 0)
        }
        bridge.register(class: response, "body", prototype: "()Lokhttp3/ResponseBody;") { _, args in
            try responseBox(args, "Response.body").body
        }
        bridge.register(class: response, "headers", prototype: "()Lokhttp3/Headers;") { _, args in
            let headers = try responseBox(args, "Response.headers").value.headers
            return .obj(ObjInstance(
                dexType: "Lokhttp3/Headers;",
                payload: HeadersBox(headers: headers),
                isHost: true
            ))
        }
        bridge.register(class: response, "request", prototype: "()Lokhttp3/Request;") { _, args in
            let request = try responseBox(args, "Response.request").request
            return .obj(ObjInstance(
                dexType: "Lokhttp3/Request;",
                payload: request,
                isHost: true
            ))
        }
        bridge.register(
            class: response,
            "header",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;"
        ) { _, args in
            let box = try responseBox(args, "Response.header")
            let name = try requiredString(args, 1, "Response.header")
            guard let value = box.value.headers.reversed().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return .null }
            return string(value.value)
        }
        bridge.register(class: response, "close", prototype: "()V") { _, args in
            let box = try responseBox(args, "Response.close")
            guard case let .obj(bodyObject) = box.body,
                  let body = bodyObject.payload as? ResponseBodyBox else {
                throw VMError.verify("Response.close body")
            }
            body.isClosed = true
            return .null
        }
        bridge.register(
            class: response,
            "peekBody",
            prototype: "(J)Lokhttp3/ResponseBody;"
        ) { _, args in
            let box = try responseBox(args, "Response.peekBody")
            guard case let .long(rawCount) = try argument(args, 1, "Response.peekBody"),
                  rawCount >= 0 else {
                throw DEXThrowable(string("IllegalArgumentException: negative byte count"))
            }
            guard case let .obj(bodyObject) = box.body,
                  let body = bodyObject.payload as? ResponseBodyBox else {
                throw VMError.verify("Response.peekBody body")
            }
            let count = min(Int(clamping: rawCount), body.bytes.count - body.offset)
            return responseBodyValue(
                Array(body.bytes[body.offset..<(body.offset + count)]),
                contentType: body.contentType
            )
        }

        bridge.register(class: responseBody, "contentLength", prototype: "()J") { _, args in
            .long(Int64(try bodyBox(args, "ResponseBody.contentLength").bytes.count))
        }
        bridge.register(class: responseBody, "contentType", prototype: "()Lokhttp3/MediaType;") { _, args in
            guard let value = try bodyBox(args, "ResponseBody.contentType").contentType else {
                return .null
            }
            return .obj(ObjInstance(
                dexType: "Lokhttp3/MediaType;",
                payload: MediaTypeBox(value: value),
                isHost: true
            ))
        }
        bridge.register(class: responseBody, "string", prototype: "()Ljava/lang/String;") { _, args in
            let box = try bodyBox(args, "ResponseBody.string")
            return string(decodeResponseBody(
                try read(box, count: nil, close: true, method: "ResponseBody.string"),
                contentType: box.contentType
            ))
        }
        bridge.register(class: responseBody, "bytes", prototype: "()[B") { _, args in
            let bytes = try read(
                try bodyBox(args, "ResponseBody.bytes"),
                count: nil,
                close: true,
                method: "ResponseBody.bytes"
            )
            return byteArray(bytes)
        }
        bridge.register(class: responseBody, "source", prototype: "()Lokio/BufferedSource;") { _, args in
            let box = try bodyBox(args, "ResponseBody.source")
            guard !box.isClosed else {
                throw DEXThrowable(string("IllegalStateException: ResponseBody.source on closed body"))
            }
            return .obj(ObjInstance(
                dexType: bufferedSource,
                payload: box,
                isHost: true
            ))
        }
        bridge.register(class: responseBody, "close", prototype: "()V") { _, args in
            let box = try bodyBox(args, "ResponseBody.close")
            box.isClosed = true
            return .null
        }

        bridge.register(class: bufferedSource, "readUtf8", prototype: "()Ljava/lang/String;") { _, args in
            string(String(decoding: try read(
                try bodyBox(args, "BufferedSource.readUtf8"),
                count: nil,
                close: false,
                method: "BufferedSource.readUtf8"
            ), as: UTF8.self))
        }
        bridge.register(
            class: bufferedSource,
            "readUtf8",
            prototype: "(J)Ljava/lang/String;"
        ) { _, args in
            guard case let .long(count) = try argument(args, 1, "BufferedSource.readUtf8") else {
                throw VMError.verify("BufferedSource.readUtf8 byte count")
            }
            return string(String(decoding: try read(
                try bodyBox(args, "BufferedSource.readUtf8"),
                count: Int(clamping: count),
                close: false,
                method: "BufferedSource.readUtf8"
            ), as: UTF8.self))
        }
        bridge.register(class: bufferedSource, "readByteArray", prototype: "()[B") { _, args in
            byteArray(try read(
                try bodyBox(args, "BufferedSource.readByteArray"),
                count: nil,
                close: false,
                method: "BufferedSource.readByteArray"
            ))
        }
        bridge.register(class: bufferedSource, "readByteArray", prototype: "(J)[B") { _, args in
            guard case let .long(count) = try argument(args, 1, "BufferedSource.readByteArray") else {
                throw VMError.verify("BufferedSource.readByteArray byte count")
            }
            return byteArray(try read(
                try bodyBox(args, "BufferedSource.readByteArray"),
                count: Int(clamping: count),
                close: false,
                method: "BufferedSource.readByteArray"
            ))
        }
        bridge.register(class: bufferedSource, "exhausted", prototype: "()Z") { _, args in
            let box = try bodyBox(args, "BufferedSource.exhausted")
            guard !box.isClosed else {
                throw DEXThrowable(string("IllegalStateException: BufferedSource.exhausted on closed body"))
            }
            return .int(box.offset == box.bytes.count ? 1 : 0)
        }
        bridge.register(class: bufferedSource, "close", prototype: "()V") { _, args in
            let box = try bodyBox(args, "BufferedSource.close")
            box.isClosed = true
            return .null
        }

        bridge.register(
            class: "Lokhttp3/Headers;",
            "get",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Headers.get"),
                  let box = object.payload as? HeadersBox else {
                throw VMError.verify("Headers.get receiver")
            }
            let name = try requiredString(args, 1, "Headers.get")
            guard let value = box.headers.reversed().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return .null }
            return string(value.value)
        }
        bridge.register(class: "Lokhttp3/Headers;", "size", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Headers.size"),
                  let box = object.payload as? HeadersBox else {
                throw VMError.verify("Headers.size receiver")
            }
            return .int(Int32(clamping: box.headers.count))
        }
        bridge.register(class: httpException, "getCode", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpException.getCode"),
                  case let .int(code)? = object.fields["code"] else {
                throw VMError.verify("HttpException.getCode receiver")
            }
            return .int(code)
        }
    }

    private static func registerHTMLSurface(_ bridge: HostBridge) {
        let document = "Lorg/jsoup/nodes/Document;"
        let element = "Lorg/jsoup/nodes/Element;"
        let elements = "Lorg/jsoup/select/Elements;"
        let jsoupExtensions = "Leu/kanade/tachiyomi/util/JsoupExtensionsKt;"

        func box(_ args: [RVal], _ method: String) throws -> CompatHTMLElementBox {
            guard case let .obj(object) = try argument(args, 0, method),
                  let value = object.payload as? CompatHTMLElementBox else {
                throw VMError.verify("\(method) receiver")
            }
            return value
        }

        func value(
            _ node: SwiftSoup.Element,
            context: CompatHTMLContext,
            descriptor: String = element
        ) -> RVal {
            .obj(ObjInstance(
                dexType: descriptor,
                payload: CompatHTMLElementBox(context: context, element: node),
                isHost: true
            ))
        }

        func list(_ nodes: [SwiftSoup.Element], context: CompatHTMLContext) -> RVal {
            hostList(
                nodes.map { value($0, context: context) },
                isMutable: false,
                descriptor: elements
            )
        }

        func parseResponse(_ responseValue: RVal, htmlOverride: RVal) throws -> RVal {
            guard case let .obj(responseObject) = responseValue,
                  let response = responseObject.payload as? ResponseBox else {
                throw VMError.verify("JsoupExtensions.asJsoup response")
            }

            let html: String
            if htmlOverride.isNull {
                guard case let .obj(bodyObject) = response.body,
                      let body = bodyObject.payload as? ResponseBodyBox else {
                    throw VMError.verify("JsoupExtensions.asJsoup response body")
                }
                guard !body.isClosed else {
                    throw hostThrowable(
                        "Ljava/lang/IllegalStateException;",
                        "response body is closed"
                    )
                }
                let bytes = Array(body.bytes[body.offset...])
                body.offset = body.bytes.count
                body.isClosed = true
                html = decodeResponseBody(bytes, contentType: body.contentType)
            } else {
                html = try requiredString([htmlOverride], 0, "JsoupExtensions.asJsoup html")
            }

            do {
                let context = try CompatHTMLParser.parse(
                    html,
                    baseURL: response.value.finalURL,
                    policy: bridge.htmlPolicy
                )
                return value(context.document, context: context, descriptor: document)
            } catch {
                throw htmlThrowable(error)
            }
        }

        bridge.register(
            class: jsoupExtensions,
            "asJsoup",
            prototype: "(Lokhttp3/Response;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            isStatic: true
        ) { _, args in
            try parseResponse(
                try argument(args, 0, "JsoupExtensions.asJsoup"),
                htmlOverride: try argument(args, 1, "JsoupExtensions.asJsoup")
            )
        }
        bridge.register(
            class: jsoupExtensions,
            "asJsoup$default",
            prototype: "(Lokhttp3/Response;Ljava/lang/String;ILjava/lang/Object;)Lorg/jsoup/nodes/Document;",
            isStatic: true
        ) { _, args in
            guard case let .int(mask) = try argument(args, 2, "JsoupExtensions.asJsoup$default") else {
                throw VMError.verify("JsoupExtensions.asJsoup$default mask")
            }
            let override = mask & 1 == 0
                ? try argument(args, 1, "JsoupExtensions.asJsoup$default")
                : RVal.null
            return try parseResponse(
                try argument(args, 0, "JsoupExtensions.asJsoup$default"),
                htmlOverride: override
            )
        }

        for descriptor in [document, element] {
            bridge.register(
                class: descriptor,
                "select",
                prototype: "(Ljava/lang/String;)Lorg/jsoup/select/Elements;"
            ) { _, args in
                let receiver = try box(args, "\(descriptor).select")
                let query = try requiredString(args, 1, "\(descriptor).select")
                do {
                    return try list(
                        receiver.context.select(receiver.element, query: query),
                        context: receiver.context
                    )
                } catch {
                    throw htmlThrowable(error)
                }
            }
            bridge.register(
                class: descriptor,
                "selectFirst",
                prototype: "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;"
            ) { _, args in
                let receiver = try box(args, "\(descriptor).selectFirst")
                let query = try requiredString(args, 1, "\(descriptor).selectFirst")
                do {
                    guard let first = try receiver.context.select(
                        receiver.element,
                        query: query
                    ).first else { return .null }
                    return value(first, context: receiver.context)
                } catch {
                    throw htmlThrowable(error)
                }
            }
        }

        bridge.register(class: document, "location", prototype: "()Ljava/lang/String;") { _, args in
            let receiver = try box(args, "Document.location")
            do {
                return string(try receiver.context.boundedString(
                    receiver.context.document.location()
                ))
            } catch {
                throw htmlThrowable(error)
            }
        }

        let stringMethods: [(name: String, prototype: String, body: (SwiftSoup.Element) throws -> String)] = [
            ("attr", "(Ljava/lang/String;)Ljava/lang/String;", { _ in "" }),
            ("absUrl", "(Ljava/lang/String;)Ljava/lang/String;", { _ in "" }),
            ("data", "()Ljava/lang/String;", { $0.data() }),
            ("ownText", "()Ljava/lang/String;", { $0.ownText() }),
            ("tagName", "()Ljava/lang/String;", { $0.tagName() }),
            ("text", "()Ljava/lang/String;", { try $0.text() }),
        ]
        for method in stringMethods {
            bridge.register(class: element, method.name, prototype: method.prototype) { _, args in
                let receiver = try box(args, "Element.\(method.name)")
                do {
                    let result: String
                    switch method.name {
                    case "attr":
                        result = try receiver.element.attr(
                            requiredString(args, 1, "Element.attr")
                        )
                    case "absUrl":
                        result = try receiver.element.absUrl(
                            requiredString(args, 1, "Element.absUrl")
                        )
                    default:
                        result = try method.body(receiver.element)
                    }
                    return string(try receiver.context.boundedString(result))
                } catch {
                    throw htmlThrowable(error)
                }
            }
        }
        bridge.register(
            class: element,
            "children",
            prototype: "()Lorg/jsoup/select/Elements;"
        ) { _, args in
            let receiver = try box(args, "Element.children")
            return list(receiver.element.children().array(), context: receiver.context)
        }

        bridge.register(class: elements, "last", prototype: "()Lorg/jsoup/nodes/Element;") { _, args in
            try listBox(args, "Elements.last").elements.last ?? .null
        }
        bridge.register(class: elements, "first", prototype: "()Lorg/jsoup/nodes/Element;") { _, args in
            try listBox(args, "Elements.first").elements.first ?? .null
        }
        bridge.register(class: elements, "size", prototype: "()I") { _, args in
            .int(Int32(clamping: try listBox(args, "Elements.size").elements.count))
        }
    }

    private static func registerSourceModelSurface(_ bridge: HostBridge) {
        let smanga = "Leu/kanade/tachiyomi/source/model/SManga;"
        let companion = "Leu/kanade/tachiyomi/source/model/SManga$Companion;"
        let mangasPage = "Leu/kanade/tachiyomi/source/model/MangasPage;"

        func mangaBox(_ args: [RVal], _ method: String, index: Int = 0) throws -> SMangaBox {
            guard case let .obj(object) = try argument(args, index, method),
                  let box = object.payload as? SMangaBox else {
                throw VMError.verify("\(method) manga argument")
            }
            return box
        }

        let companionValue = RVal.obj(ObjInstance(dexType: companion, isHost: true))
        bridge.staticFields["\(smanga)->Companion"] = companionValue
        bridge.register(class: companion, "create", prototype: "()Leu/kanade/tachiyomi/source/model/SManga;") {
            _, _ in
            .obj(ObjInstance(dexType: smanga, payload: SMangaBox(), isHost: true))
        }

        let stringProperties: [(suffix: String, keyPath: WritableKeyPath<SMangaCompat, String>)] = [
            ("Url", \.url),
            ("Title", \.title),
        ]
        for property in stringProperties {
            bridge.register(
                class: smanga,
                "set\(property.suffix)",
                prototype: "(Ljava/lang/String;)V"
            ) { _, args in
                let box = try mangaBox(args, "SManga.set\(property.suffix)")
                box.value[keyPath: property.keyPath] = try requiredString(
                    args,
                    1,
                    "SManga.set\(property.suffix)"
                )
                return .null
            }
            bridge.register(
                class: smanga,
                "get\(property.suffix)",
                prototype: "()Ljava/lang/String;"
            ) { _, args in
                string(try mangaBox(args, "SManga.get\(property.suffix)").value[
                    keyPath: property.keyPath
                ])
            }
        }

        bridge.register(
            class: smanga,
            "setThumbnail_url",
            prototype: "(Ljava/lang/String;)V"
        ) { _, args in
            let box = try mangaBox(args, "SManga.setThumbnail_url")
            box.value.thumbnailURL = try optionalString(args, 1, "SManga.setThumbnail_url")
            return .null
        }
        bridge.register(
            class: smanga,
            "getThumbnail_url",
            prototype: "()Ljava/lang/String;"
        ) { _, args in
            guard let value = try mangaBox(args, "SManga.getThumbnail_url").value.thumbnailURL else {
                return .null
            }
            return string(value)
        }
        bridge.register(class: smanga, "setStatus", prototype: "(I)V") { _, args in
            let box = try mangaBox(args, "SManga.setStatus")
            guard case let .int(rawValue) = try argument(args, 1, "SManga.setStatus") else {
                throw VMError.verify("SManga.setStatus value")
            }
            box.value.status = MangaStatus(rawValue: Int(rawValue)) ?? .unknown
            return .null
        }
        bridge.register(class: smanga, "getStatus", prototype: "()I") { _, args in
            .int(Int32(try mangaBox(args, "SManga.getStatus").value.status.rawValue))
        }
        bridge.register(class: smanga, "setInitialized", prototype: "(Z)V") { _, args in
            let box = try mangaBox(args, "SManga.setInitialized")
            guard case let .int(value) = try argument(args, 1, "SManga.setInitialized") else {
                throw VMError.verify("SManga.setInitialized value")
            }
            box.value.initialized = value != 0
            return .null
        }
        bridge.register(class: smanga, "getInitialized", prototype: "()Z") { _, args in
            .int(try mangaBox(args, "SManga.getInitialized").value.initialized ? 1 : 0)
        }

        let optionalProperties: [(suffix: String, keyPath: WritableKeyPath<SMangaCompat, String?>)] = [
            ("Artist", \.artist),
            ("Author", \.author),
            ("Description", \.description),
        ]
        for property in optionalProperties {
            bridge.register(
                class: smanga,
                "set\(property.suffix)",
                prototype: "(Ljava/lang/String;)V"
            ) { _, args in
                let box = try mangaBox(args, "SManga.set\(property.suffix)")
                box.value[keyPath: property.keyPath] = try optionalString(
                    args,
                    1,
                    "SManga.set\(property.suffix)"
                )
                return .null
            }
            bridge.register(
                class: smanga,
                "get\(property.suffix)",
                prototype: "()Ljava/lang/String;"
            ) { _, args in
                guard let value = try mangaBox(args, "SManga.get\(property.suffix)").value[
                    keyPath: property.keyPath
                ] else { return .null }
                return string(value)
            }
        }
        bridge.register(class: smanga, "setGenre", prototype: "(Ljava/lang/String;)V") { _, args in
            let box = try mangaBox(args, "SManga.setGenre")
            box.value.genres = try optionalString(args, 1, "SManga.setGenre")?.split(
                separator: ","
            ).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty } ?? []
            return .null
        }
        bridge.register(class: smanga, "getGenre", prototype: "()Ljava/lang/String;") { _, args in
            let genres = try mangaBox(args, "SManga.getGenre").value.genres
            return genres.isEmpty ? .null : string(genres.joined(separator: ", "))
        }

        bridge.register(
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;",
            "setUrlWithoutDomain",
            prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/lang/String;)V"
        ) { _, args in
            let box = try mangaBox(args, "HttpSource.setUrlWithoutDomain", index: 1)
            let rawURL = try requiredString(args, 2, "HttpSource.setUrlWithoutDomain")
            guard rawURL.utf8.count <= 8_192 else {
                throw hostThrowable("Ljava/lang/IllegalArgumentException;", "manga URL is too long")
            }
            box.value.url = urlWithoutDomain(rawURL)
            return .null
        }

        bridge.objectFactories[mangasPage] = { _ in
            .obj(ObjInstance(dexType: mangasPage, isHost: true))
        }
        bridge.register(
            class: mangasPage,
            "<init>",
            prototype: "(Ljava/util/List;Z)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "MangasPage.<init>"),
                  case let .int(hasNextPage) = try argument(args, 2, "MangasPage.<init>") else {
                throw VMError.verify("MangasPage constructor arguments")
            }
            let mangas = try listBox(args, "MangasPage.<init>", index: 1).elements
            try requireCollectionCapacity(mangas.count, "MangasPage.<init>")
            object.payload = MangasPageBox(
                mangas: mangas,
                hasNextPage: hasNextPage != 0
            )
            return .null
        }
        for name in ["getMangas", "component1"] {
            bridge.register(
                class: mangasPage,
                name,
                prototype: "()Ljava/util/List;"
            ) { _, args in
                guard case let .obj(object) = try argument(args, 0, "MangasPage.\(name)"),
                      let box = object.payload as? MangasPageBox else {
                    throw VMError.verify("MangasPage.\(name) receiver")
                }
                return hostList(box.mangas, isMutable: false)
            }
        }
        for name in ["getHasNextPage", "component2"] {
            bridge.register(class: mangasPage, name, prototype: "()Z") { _, args in
                guard case let .obj(object) = try argument(args, 0, "MangasPage.\(name)"),
                      let box = object.payload as? MangasPageBox else {
                    throw VMError.verify("MangasPage.\(name) receiver")
                }
                return .int(box.hasNextPage ? 1 : 0)
            }
        }
    }

    /// Converts an interpreted tachiyomix `SManga` host value into the public
    /// app-facing compatibility model.
    public static func mangaCompat(from value: RVal) -> SMangaCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? SMangaBox else { return nil }
        return box.value
    }

    /// Converts an interpreted tachiyomix `MangasPage` host value into the
    /// public app-facing compatibility model without silently dropping entries.
    public static func mangasPageCompat(from value: RVal) -> MangasPageCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? MangasPageBox else { return nil }
        var mangas: [SMangaCompat] = []
        mangas.reserveCapacity(box.mangas.count)
        for manga in box.mangas {
            guard let converted = mangaCompat(from: manga) else { return nil }
            mangas.append(converted)
        }
        return MangasPageCompat(mangas: mangas, hasNextPage: box.hasNextPage)
    }

    private static func hostThrowable(_ descriptor: String, _ message: String) -> DEXThrowable {
        DEXThrowable(.obj(ObjInstance(
            dexType: descriptor,
            payload: message,
            isHost: true
        )))
    }

    private static func htmlThrowable(_ error: Swift.Error) -> DEXThrowable {
        let message = (error as? CompatHTMLError)?.description ?? "HTML operation failed"
        return hostThrowable("Ljava/lang/IllegalArgumentException;", message)
    }

    private static func urlWithoutDomain(_ rawURL: String) -> String {
        let escaped = rawURL.replacingOccurrences(of: " ", with: "%20")
        guard let components = URLComponents(string: escaped) else { return rawURL }
        var result = components.path
        if let query = components.query { result += "?" + query }
        if let fragment = components.fragment { result += "#" + fragment }
        return result
    }

    /// Matches `java.net.URLEncoder`'s legacy HTML-form safe set. In
    /// particular, spaces become `+`, `*` stays literal, and `~` is escaped.
    private static func formURLEncodeUTF8(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                result.append(byte)
            case 0x20:
                result.append(0x2B)
            default:
                result.append(0x25)
                result.append(hex[Int(byte >> 4)])
                result.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func execute(
        _ call: CallBox,
        transport: any CompatHTTPTransport,
        requiresSuccess: Bool
    ) async throws -> RVal {
        guard !call.isCancelled else { throw VMError.cancelled }
        do {
            try Task.checkCancellation()
            let response = try await transport.execute(call.request)
            try Task.checkCancellation()
            guard !call.isCancelled else { throw VMError.cancelled }
            if requiresSuccess, !(200..<300).contains(response.statusCode) {
                throw DEXThrowable(.obj(ObjInstance(
                    dexType: "Leu/kanade/tachiyomi/network/HttpException;",
                    fields: ["code": .int(Int32(clamping: response.statusCode))],
                    payload: "HTTP error \(response.statusCode)",
                    isHost: true
                )))
            }
            return responseValue(response, request: call.request)
        } catch is CancellationError {
            call.isCancelled = true
            throw VMError.cancelled
        } catch let error as VMError {
            throw error
        } catch let thrown as DEXThrowable {
            throw thrown
        } catch let error as CompatHTTPTransportError {
            if error == .cancelled {
                call.isCancelled = true
                throw VMError.cancelled
            }
            throw DEXThrowable(.obj(ObjInstance(
                dexType: "Ljava/io/IOException;",
                payload: error.description,
                isHost: true
            )))
        } catch {
            throw DEXThrowable(.obj(ObjInstance(
                dexType: "Ljava/io/IOException;",
                payload: "HTTP transport failed",
                isHost: true
            )))
        }
    }

    private static func responseValue(
        _ response: CompatHTTPResponse,
        request: CompatHTTPRequest
    ) -> RVal {
        let contentType = response.headers.reversed().first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let body = responseBodyValue(response.body, contentType: contentType)
        return .obj(ObjInstance(
            dexType: "Lokhttp3/Response;",
            payload: ResponseBox(value: response, request: request, body: body),
            isHost: true
        ))
    }

    private static func responseBodyValue(_ bytes: [UInt8], contentType: String?) -> RVal {
        .obj(ObjInstance(
            dexType: "Lokhttp3/ResponseBody;",
            payload: ResponseBodyBox(bytes: bytes, contentType: contentType),
            isHost: true
        ))
    }

    private static func byteArray(_ bytes: [UInt8]) -> RVal {
        .arr(ArrInstance(
            elemDescriptor: "B",
            elements: bytes.map { .int(Int32(Int8(bitPattern: $0))) }
        ))
    }

    private static func decodeResponseBody(_ bytes: [UInt8], contentType: String?) -> String {
        let charset = contentType?.split(separator: ";").dropFirst().compactMap { part -> String? in
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("charset") == .orderedSame else { return nil }
            return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }.first
        let encoding: String.Encoding
        switch charset {
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "utf-16", "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        default: encoding = .utf8
        }
        return String(data: Data(bytes), encoding: encoding)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private func networkHelper(for source: ObjInstance) -> RVal {
        let identity = ObjectIdentifier(source)
        if let existing = sourceNetworks[identity] { return existing }
        let baseInterceptors = [
            "UncaughtExceptionInterceptor",
            "UserAgentInterceptor",
            "CloudflareInterceptor",
        ].map {
            RVal.obj(ObjInstance(
                dexType: "Leu/kanade/tachiyomi/network/interceptor/\($0);",
                isHost: true
            ))
        }
        let client = RVal.obj(ObjInstance(
            dexType: "Lokhttp3/OkHttpClient;",
            payload: OkHttpClientBox(interceptors: baseInterceptors),
            isHost: true
        ))
        let helper = RVal.obj(ObjInstance(
            dexType: "Leu/kanade/tachiyomi/network/NetworkHelper;",
            payload: NetworkHelperBox(client: client),
            isHost: true
        ))
        sourceNetworks[identity] = helper
        return helper
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
        DexTypeHierarchy(dex: dex).assignability(
            from: descriptor,
            to: expected,
            strict: true
        ) == .yes
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
