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

    private struct KotlinDeferredBox {
        let scope: RVal
        let block: RVal
    }

    private enum FilterKind {
        case header
        case separator
        case select
        case text
        case checkBox
        case triState
        case group
        case sort
    }

    private final class FilterStateBox {
        let kind: FilterKind
        let name: String
        let values: [String]
        var state: RVal

        init(kind: FilterKind, name: String, values: [String] = [], state: RVal) {
            self.kind = kind
            self.name = name
            self.values = values
            self.state = state
        }
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

    private final class HttpUrlBuilderBox {
        let baseURL: String
        var queryParameters: [(name: String, value: String?)] = []
        var addedURLBytes = 0

        init(baseURL: String) {
            self.baseURL = baseURL
        }
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

    private struct KotlinMatchResultBox {
        let value: String
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

    private final class SChapterBox {
        var value: SChapterCompat

        init(_ value: SChapterCompat = .init()) {
            self.value = value
        }
    }

    private final class PageBox {
        var value: PageCompat
        var uri: RVal

        init(value: PageCompat, uri: RVal = .null) {
            self.value = value
            self.uri = uri
        }
    }

    private struct MangasPageBox {
        let mangas: [RVal]
        let hasNextPage: Bool
    }

    private struct SMangaUpdateBox {
        let manga: RVal
        let chapters: [RVal]
    }

    private final class SerialDescriptorBox {
        let serialName: String
        let expectedElementCount: Int
        var elements: [(name: String, isOptional: Bool)] = []

        init(serialName: String, expectedElementCount: Int) {
            self.serialName = serialName
            self.expectedElementCount = expectedElementCount
        }
    }

    private final class JSONValueDecoderBox {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }
    }

    private final class JSONCompositeDecoderBox {
        let object: [String: Any]
        let descriptor: SerialDescriptorBox
        let presentIndices: [Int]
        var nextPresentIndex = 0

        init(object: [String: Any], descriptor: SerialDescriptorBox) {
            self.object = object
            self.descriptor = descriptor
            self.presentIndices = descriptor.elements.indices.filter {
                object[descriptor.elements[$0].name] != nil
            }
        }

        func value(at index: Int) -> Any? {
            guard descriptor.elements.indices.contains(index) else { return nil }
            return object[descriptor.elements[index].name]
        }
    }

    private struct ArrayListSerializerBox {
        let elementSerializer: RVal
    }

    private struct JSONStringSerializerBox {}

    private struct JSONConfigurationBox {
        let encodeDefaults: Bool
    }

    private final class JSONBuilderBox {
        var encodeDefaults: Bool

        init(encodeDefaults: Bool) {
            self.encodeDefaults = encodeDefaults
        }
    }

    private final class JSONObjectBuilderBox {
        var values: [String: String] = [:]
        var utf8Bytes = 0
    }

    private struct JSONObjectBox {
        let values: [String: String]
    }

    private indirect enum JSONEncodedValue {
        case null
        case bool(Bool)
        case string(String)
        case int(Int32)
        case float(Float)
        case array([JSONEncodedValue])
        case object([(key: String, value: JSONEncodedValue)])
    }

    private final class JSONEncodingState {
        var value: JSONEncodedValue?
    }

    private final class JSONValueEncoderBox {
        let state: JSONEncodingState
        let depth: Int
        let encodeDefaults: Bool

        init(state: JSONEncodingState, depth: Int, encodeDefaults: Bool) {
            self.state = state
            self.depth = depth
            self.encodeDefaults = encodeDefaults
        }
    }

    private final class JSONCompositeEncoderBox {
        let state: JSONEncodingState
        let descriptor: SerialDescriptorBox
        let depth: Int
        let encodeDefaults: Bool
        var values: [Int: JSONEncodedValue] = [:]

        init(
            state: JSONEncodingState,
            descriptor: SerialDescriptorBox,
            depth: Int,
            encodeDefaults: Bool
        ) {
            self.state = state
            self.descriptor = descriptor
            self.depth = depth
            self.encodeDefaults = encodeDefaults
        }
    }

    private struct LocalDateBox {
        let year: Int
        let month: Int
        let day: Int
    }

    private struct ZoneIDBox {
        let timeZone: TimeZone
    }

    private struct EpochMillisecondsBox {
        let value: Int64
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
        bridge.register(
            class: "Lkotlin/io/CloseableKt;",
            "closeFinally",
            prototype: "(Ljava/io/Closeable;Ljava/lang/Throwable;)V",
            isStatic: true
        ) { vm, args in
            let operation = "CloseableKt.closeFinally"
            let closeable = try argument(args, 0, operation)
            if closeable.isNull { return .null }
            guard case let .obj(object) = closeable else {
                throw VMError.verify("\(operation) receiver")
            }
            guard let close = bridge.resolve(
                class: object.dexType,
                "close",
                prototype: "()V",
                isStatic: false
            ) else {
                throw VMError.unresolvedMethod(
                    class: object.dexType,
                    signature: "close()V"
                )
            }
            let cause = try argument(args, 1, operation)
            if cause.isNull {
                _ = try close(vm, [closeable])
            } else {
                // Kotlin preserves the primary throwable when cleanup fails.
                // The suppressed exception list is not otherwise observable
                // through the current bounded extension surface.
                do {
                    _ = try close(vm, [closeable])
                } catch is DEXThrowable {}
            }
            return .null
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
        Self.registerByteEncodingSurface(bridge)
        Self.registerStringBuilder(bridge)
        Self.registerCoroutineSurface(bridge)

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
            class: "Lkotlin/Result;",
            "constructor-impl",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
            isStatic: true
        ) { _, args in
            try argument(args, 0, "Result.constructor-impl")
        }
        bridge.register(
            class: "Lkotlin/Result;",
            "isFailure-impl",
            prototype: "(Ljava/lang/Object;)Z",
            isStatic: true
        ) { _, args in
            let value = try argument(args, 0, "Result.isFailure-impl")
            if case let .obj(object) = value,
               object.payload is KotlinFailure || object.dexType == "Lkotlin/Result$Failure;" {
                return .int(1)
            }
            return .int(0)
        }
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
            "equals",
            prototype: "(Ljava/lang/String;Ljava/lang/String;Z)Z",
            isStatic: true
        ) { _, args in
            let operation = "StringsKt.equals"
            func nullableString(_ index: Int) throws -> String? {
                let value = try argument(args, index, operation)
                if value.isNull { return nil }
                guard let result = stringPayload(value) else {
                    throw VMError.verify("\(operation) argument \(index)")
                }
                return result
            }
            let left = try nullableString(0)
            let right = try nullableString(1)
            guard case let .int(rawIgnoreCase) = try argument(args, 2, operation) else {
                throw VMError.verify("\(operation) ignoreCase")
            }
            guard let left, let right else {
                return .int(left == nil && right == nil ? 1 : 0)
            }
            let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
            guard left.utf8.count <= maximumBytes, right.utf8.count <= maximumBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "equals input is too long"
                )
            }
            let matches = rawIgnoreCase == 0
                ? left == right
                : left.compare(right, options: [.caseInsensitive]) == .orderedSame
            return .int(matches ? 1 : 0)
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
        for (name, beforeLast) in [
            ("substringAfter$default", false),
            ("substringBeforeLast$default", true),
        ] {
            bridge.register(
                class: "Lkotlin/text/StringsKt;",
                name,
                prototype: "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
                isStatic: true
            ) { _, args in
                let operation = "StringsKt.\(name)"
                let value = try requiredString(args, 0, operation)
                let delimiter = try requiredString(args, 1, operation)
                guard case let .int(mask) = try argument(args, 3, operation) else {
                    throw VMError.verify("\(operation) default mask")
                }
                let missingValue = mask & 0x02 != 0
                    ? value
                    : try requiredString(args, 2, operation)
                let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
                guard value.utf8.count <= maximumBytes,
                      delimiter.utf8.count <= maximumBytes,
                      missingValue.utf8.count <= maximumBytes else {
                    throw hostThrowable(
                        "Ljava/lang/IllegalArgumentException;",
                        "substring input is too long"
                    )
                }
                let options: String.CompareOptions = beforeLast ? [.backwards] : []
                guard let range = value.range(of: delimiter, options: options) else {
                    return string(missingValue)
                }
                let result = beforeLast
                    ? String(value[..<range.lowerBound])
                    : String(value[range.upperBound...])
                return string(result)
            }
        }
        for (name, beforeLast) in [
            ("substringAfterLast$default", false),
            ("substringBeforeLast$default", true),
        ] {
            bridge.register(
                class: "Lkotlin/text/StringsKt;",
                name,
                prototype: "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
                isStatic: true
            ) { _, args in
                let operation = "StringsKt.\(name)"
                let value = try requiredString(args, 0, operation)
                guard case let .int(rawDelimiter) = try argument(args, 1, operation),
                      case let .int(mask) = try argument(args, 3, operation) else {
                    throw VMError.verify("\(operation) arguments")
                }
                let missingValue = mask & 0x02 != 0
                    ? value
                    : try requiredString(args, 2, operation)
                let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
                guard value.utf8.count <= maximumBytes,
                      missingValue.utf8.count <= maximumBytes else {
                    throw hostThrowable(
                        "Ljava/lang/IllegalArgumentException;",
                        "substring input is too long"
                    )
                }
                guard rawDelimiter >= 0,
                      rawDelimiter <= 0xFFFF,
                      let scalar = UnicodeScalar(UInt32(rawDelimiter)),
                      let range = value.range(of: String(scalar), options: [.backwards]) else {
                    return string(missingValue)
                }
                let result = beforeLast
                    ? String(value[..<range.lowerBound])
                    : String(value[range.upperBound...])
                return string(result)
            }
        }
        for (name, backwards) in [
            ("startsWith$default", false),
            ("endsWith$default", true),
        ] {
            bridge.register(
                class: "Lkotlin/text/StringsKt;",
                name,
                prototype: "(Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Z",
                isStatic: true
            ) { _, args in
                let operation = "StringsKt.\(name)"
                let source = try requiredString(args, 0, operation)
                let affix = try requiredString(args, 1, operation)
                guard case let .int(rawIgnoreCase) = try argument(args, 2, operation),
                      case let .int(mask) = try argument(args, 3, operation) else {
                    throw VMError.verify("\(operation) arguments")
                }
                let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
                guard source.utf8.count <= maximumBytes,
                      affix.utf8.count <= maximumBytes else {
                    throw hostThrowable(
                        "Ljava/lang/IllegalArgumentException;",
                        "prefix or suffix input is too long"
                    )
                }
                let ignoreCase = mask & 0x02 != 0 ? false : rawIgnoreCase != 0
                var options: String.CompareOptions = [.anchored]
                if ignoreCase { options.insert(.caseInsensitive) }
                let searchRange: Range<String.Index>
                if backwards {
                    options.insert(.backwards)
                    searchRange = source.startIndex..<source.endIndex
                } else {
                    searchRange = source.startIndex..<source.endIndex
                }
                let matches = source.range(
                    of: affix,
                    options: options,
                    range: searchRange
                ) != nil
                return .int(matches ? 1 : 0)
            }
        }
        bridge.register(
            class: "Lkotlin/text/StringsKt;",
            "split$default",
            prototype: "(Ljava/lang/CharSequence;[Ljava/lang/String;ZIILjava/lang/Object;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            let operation = "StringsKt.split$default"
            let source = try requiredString(args, 0, operation)
            guard case let .arr(delimiterArray) = try argument(args, 1, operation),
                  case let .int(rawIgnoreCase) = try argument(args, 2, operation),
                  case let .int(rawLimit) = try argument(args, 3, operation),
                  case let .int(mask) = try argument(args, 4, operation) else {
                throw VMError.verify("\(operation) arguments")
            }
            try requireCollectionCapacity(delimiterArray.elements.count, operation)
            let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
            guard source.utf8.count <= maximumBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "split input is too long"
                )
            }
            let delimiters = try delimiterArray.elements.enumerated().map { index, value in
                guard let delimiter = stringPayload(value),
                      delimiter.utf8.count <= bridge.htmlPolicy.maximumSelectorBytes else {
                    throw VMError.verify("\(operation) delimiter \(index)")
                }
                return delimiter
            }
            let ignoreCase = mask & 0x02 != 0 ? false : rawIgnoreCase != 0
            let limit = mask & 0x04 != 0 ? 0 : Int(rawLimit)
            guard limit >= 0 else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "split limit must be non-negative"
                )
            }
            guard !delimiters.isEmpty else {
                return hostList([string(source)], isMutable: false)
            }

            let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            var pieces: [RVal] = []
            var pieceStart = source.startIndex
            var searchStart = source.startIndex
            var searchExhausted = false
            while !searchExhausted && (limit == 0 || pieces.count < limit - 1) {
                var match: Range<String.Index>?
                var matchedDelimiterIndex = Int.max
                for (index, delimiter) in delimiters.enumerated() {
                    let range: Range<String.Index>?
                    if delimiter.isEmpty {
                        range = searchStart..<searchStart
                    } else {
                        range = source.range(
                            of: delimiter,
                            options: options,
                            range: searchStart..<source.endIndex
                        )
                    }
                    guard let range else { continue }
                    if match == nil || range.lowerBound < match!.lowerBound ||
                        (range.lowerBound == match!.lowerBound && index < matchedDelimiterIndex) {
                        match = range
                        matchedDelimiterIndex = index
                    }
                }
                guard let match else { break }
                pieces.append(string(String(source[pieceStart..<match.lowerBound])))
                try requireCollectionCapacity(pieces.count + 1, operation)
                pieceStart = match.upperBound
                if match.isEmpty {
                    if searchStart < source.endIndex {
                        searchStart = source.index(after: searchStart)
                    } else {
                        searchExhausted = true
                    }
                } else {
                    searchStart = match.upperBound
                }
            }
            pieces.append(string(String(source[pieceStart...])))
            try requireCollectionCapacity(pieces.count, operation)
            return hostList(pieces, isMutable: false)
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
        Self.registerSerializationSurface(bridge)
        Self.registerJSONElementSurface(bridge)
        Self.registerKotlinDurationSurface(bridge)
        Self.registerOkHttpRequestSurface(bridge)
        Self.registerOkHttpResponseSurface(bridge)
        Self.registerHTMLSurface(bridge)
        Self.registerSourceModelSurface(bridge)
        Self.registerJavaTimeSurface(bridge)
        let regex = "Lkotlin/text/Regex;"
        bridge.objectFactories[regex] = { _ in
            .obj(ObjInstance(dexType: regex, isHost: true))
        }
        bridge.register(class: regex, "<init>", prototype: "(Ljava/lang/String;)V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Regex.<init>") else {
                throw VMError.verify("Regex constructor receiver")
            }
            let pattern = try requiredString(args, 1, "Regex.<init>")
            guard pattern.utf8.count <= bridge.htmlPolicy.maximumSelectorBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "regex pattern is too long"
                )
            }
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
        bridge.register(
            class: regex,
            "find$default",
            prototype: "(Lkotlin/text/Regex;Ljava/lang/CharSequence;IILjava/lang/Object;)Lkotlin/text/MatchResult;",
            isStatic: true
        ) { _, args in
            let operation = "Regex.find$default"
            guard case let .obj(regexObject) = try argument(args, 0, operation),
                  let regexBox = regexObject.payload as? KotlinRegexBox,
                  case let .int(rawStartIndex) = try argument(args, 2, operation),
                  case let .int(mask) = try argument(args, 3, operation) else {
                throw VMError.verify("\(operation) arguments")
            }
            let input = try requiredString(args, 1, operation)
            guard input.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "regex input is too long"
                )
            }
            let startIndex = mask & 0x02 != 0 ? 0 : Int(rawStartIndex)
            let utf16Count = input.utf16.count
            guard startIndex >= 0, startIndex <= utf16Count else {
                throw hostThrowable(
                    "Ljava/lang/IndexOutOfBoundsException;",
                    "regex start index is out of bounds"
                )
            }
            let searchRange = NSRange(
                location: startIndex,
                length: utf16Count - startIndex
            )
            guard let match = regexBox.expression.firstMatch(
                in: input,
                range: searchRange
            ), let range = Range(match.range, in: input) else {
                return .null
            }
            let value = String(input[range])
            guard value.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "regex match is too long"
                )
            }
            return .obj(ObjInstance(
                dexType: "Lkotlin/text/MatchResult;",
                payload: KotlinMatchResultBox(value: value),
                isHost: true
            ))
        }
        bridge.register(
            class: "Lkotlin/text/MatchResult;",
            "getValue",
            prototype: "()Ljava/lang/String;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "MatchResult.getValue"),
                  let match = object.payload as? KotlinMatchResultBox else {
                throw VMError.verify("MatchResult.getValue receiver")
            }
            return string(match.value)
        }
        return bridge
    }

    /// Exact structured-coroutine surface reached by current lib 1.6 source
    /// update wrappers. `async` is represented lazily and `await` interprets
    /// the captured DEX lambda on the same VM, preserving verifier, call-depth,
    /// instruction-budget, cancellation, and host-capability boundaries.
    private static func registerCoroutineSurface(_ bridge: HostBridge) {
        let scope = "Lkotlinx/coroutines/CoroutineScope;"
        let deferred = "Lkotlinx/coroutines/Deferred;"

        bridge.register(
            class: "Lkotlin/coroutines/jvm/internal/SuspendLambda;",
            "<init>",
            prototype: "(ILkotlin/coroutines/Continuation;)V"
        ) { _, args in
            guard case .obj = try argument(args, 0, "SuspendLambda.<init>"),
                  case .int = try argument(args, 1, "SuspendLambda.<init>") else {
                throw VMError.verify("SuspendLambda constructor arguments")
            }
            _ = try argument(args, 2, "SuspendLambda.<init>")
            return .null
        }

        bridge.register(
            class: "Lkotlinx/coroutines/CoroutineScopeKt;",
            "coroutineScope",
            prototype: "(Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            isStatic: true
        ) { vm, args in
            guard case let .obj(block) = try argument(args, 0, "CoroutineScope.coroutineScope") else {
                throw VMError.verify("CoroutineScope.coroutineScope block")
            }
            let scopeValue = RVal.obj(ObjInstance(dexType: scope, isHost: true))
            return try vm.call(
                classDescriptor: block.dexType,
                method: "invoke",
                prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                args: [
                    .obj(block),
                    scopeValue,
                    try argument(args, 1, "CoroutineScope.coroutineScope"),
                ]
            )
        }

        bridge.register(
            class: "Lkotlinx/coroutines/BuildersKt;",
            "async$default",
            prototype: "(Lkotlinx/coroutines/CoroutineScope;Lkotlin/coroutines/CoroutineContext;Lkotlinx/coroutines/CoroutineStart;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Lkotlinx/coroutines/Deferred;",
            isStatic: true
        ) { _, args in
            guard case let .obj(scopeObject) = try argument(args, 0, "BuildersKt.async$default"),
                  scopeObject.dexType == scope,
                  case let .obj(block) = try argument(args, 3, "BuildersKt.async$default"),
                  case let .int(mask) = try argument(args, 4, "BuildersKt.async$default"),
                  mask & 0x3 == 0x3,
                  try argument(args, 5, "BuildersKt.async$default").isNull else {
                throw VMError.verify("BuildersKt.async$default arguments")
            }
            return .obj(ObjInstance(
                dexType: deferred,
                payload: KotlinDeferredBox(scope: .obj(scopeObject), block: .obj(block)),
                isHost: true
            ))
        }

        bridge.register(
            class: deferred,
            "await",
            prototype: "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ) { vm, args in
            guard case let .obj(object) = try argument(args, 0, "Deferred.await"),
                  let deferred = object.payload as? KotlinDeferredBox,
                  case let .obj(block) = deferred.block else {
                throw VMError.verify("Deferred.await receiver")
            }
            return try vm.call(
                classDescriptor: block.dexType,
                method: "invoke",
                prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                args: [
                    deferred.block,
                    deferred.scope,
                    try argument(args, 1, "Deferred.await"),
                ]
            )
        }
    }

    /// String-valued JsonObject subset used by tachiyomix manga/chapter memo
    /// fields. This deliberately does not expose arbitrary JSON mutation.
    private static func registerJSONElementSurface(_ bridge: HostBridge) {
        let builder = "Lkotlinx/serialization/json/JsonObjectBuilder;"
        let jsonObject = "Lkotlinx/serialization/json/JsonObject;"
        let primitive = "Lkotlinx/serialization/json/JsonPrimitive;"

        bridge.objectFactories[builder] = { _ in
            .obj(ObjInstance(
                dexType: builder,
                payload: JSONObjectBuilderBox(),
                isHost: true
            ))
        }
        bridge.register(class: builder, "<init>", prototype: "()V") { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonObjectBuilder.<init>") else {
                throw VMError.verify("JsonObjectBuilder constructor receiver")
            }
            object.payload = JSONObjectBuilderBox()
            return .null
        }
        bridge.register(
            class: "Lkotlinx/serialization/json/JsonElementBuildersKt;",
            "put",
            prototype: "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;",
            isStatic: true
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonObjectBuilder.put"),
                  let box = object.payload as? JSONObjectBuilderBox else {
                throw VMError.verify("JsonObjectBuilder.put receiver")
            }
            let key = try requiredString(args, 1, "JsonObjectBuilder.put")
            let value = try requiredString(args, 2, "JsonObjectBuilder.put")
            guard key.utf8.count <= 4_096,
                  value.utf8.count <= 4_096,
                  box.values[key] != nil || box.values.count < 512 else {
                throw VMError.verify("JsonObjectBuilder.put entry bounds")
            }
            let previousBytes = box.values[key].map { key.utf8.count + $0.utf8.count } ?? 0
            let nextBytes = box.utf8Bytes - previousBytes + key.utf8.count + value.utf8.count
            guard nextBytes <= 1_048_576 else {
                throw VMError.verify("JsonObjectBuilder.put exceeds 1048576 UTF-8 bytes")
            }
            box.values[key] = value
            box.utf8Bytes = nextBytes
            return .obj(ObjInstance(dexType: primitive, payload: value, isHost: true))
        }
        bridge.register(class: builder, "build", prototype: "()Lkotlinx/serialization/json/JsonObject;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonObjectBuilder.build"),
                  let box = object.payload as? JSONObjectBuilderBox else {
                throw VMError.verify("JsonObjectBuilder.build receiver")
            }
            return .obj(ObjInstance(
                dexType: jsonObject,
                payload: JSONObjectBox(values: box.values),
                isHost: true
            ))
        }
        bridge.register(
            class: jsonObject,
            "get",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonObject.get"),
                  let box = object.payload as? JSONObjectBox else {
                throw VMError.verify("JsonObject.get receiver")
            }
            let key = try requiredString(args, 1, "JsonObject.get")
            guard let value = box.values[key] else { return .null }
            return .obj(ObjInstance(dexType: primitive, payload: value, isHost: true))
        }
        bridge.register(
            class: "Lkotlinx/serialization/json/JsonElementKt;",
            "getJsonPrimitive",
            prototype: "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonPrimitive;",
            isStatic: true
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonElement.getJsonPrimitive"),
                  object.dexType == primitive,
                  object.payload is String else {
                throw DEXThrowable(string("IllegalArgumentException: JsonElement is not a primitive"))
            }
            return .obj(object)
        }
        bridge.register(class: primitive, "getContent", prototype: "()Ljava/lang/String;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonPrimitive.getContent"),
                  let value = object.payload as? String else {
                throw VMError.verify("JsonPrimitive.getContent receiver")
            }
            return string(value)
        }
    }

    /// Minimal dependency-injection entry used by keiyoushi's serialization
    /// helpers. The injected value is deliberately only a host `Json` object;
    /// no general service locator or app-global dependency surface is exposed.
    private static func registerSerializationSurface(_ bridge: HostBridge) {
        let decoder = "Lkotlinx/serialization/encoding/Decoder;"
        let compositeDecoder = "Lkotlinx/serialization/encoding/CompositeDecoder;"
        let encoder = "Lkotlinx/serialization/encoding/Encoder;"
        let compositeEncoder = "Lkotlinx/serialization/encoding/CompositeEncoder;"

        func serializationThrowable(_ message: String) -> DEXThrowable {
            hostThrowable("Lkotlinx/serialization/SerializationException;", message)
        }

        func isJSONBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            let encoding = String(cString: number.objCType)
            return encoding == "c" || encoding == "B"
        }

        func validateJSON(_ root: Any) throws {
            var stack: [(value: Any, depth: Int)] = [(root, 1)]
            var nodes = 0
            var objectMembers = 0
            while let item = stack.popLast() {
                nodes += 1
                guard nodes <= bridge.htmlPolicy.maximumNodes else {
                    throw serializationThrowable("JSON value exceeds node limit")
                }
                guard item.depth <= bridge.htmlPolicy.maximumDepth else {
                    throw serializationThrowable("JSON value exceeds depth limit")
                }
                if let object = item.value as? [String: Any] {
                    objectMembers += object.count
                    guard objectMembers <= bridge.htmlPolicy.maximumAttributes else {
                        throw serializationThrowable("JSON value exceeds member limit")
                    }
                    for (key, value) in object {
                        guard key.utf8.count <= bridge.htmlPolicy.maximumSelectorBytes else {
                            throw serializationThrowable("JSON object key is too long")
                        }
                        stack.append((value, item.depth + 1))
                    }
                } else if let array = item.value as? [Any] {
                    guard array.count <= bridge.htmlPolicy.maximumNodes else {
                        throw serializationThrowable("JSON array exceeds element limit")
                    }
                    for value in array {
                        stack.append((value, item.depth + 1))
                    }
                } else if let value = item.value as? String {
                    guard value.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                        throw serializationThrowable("JSON string is too long")
                    }
                } else if item.value is NSNumber || item.value is NSNull {
                    continue
                } else {
                    throw serializationThrowable("unsupported JSON value")
                }
            }
        }

        func decoderValue(_ value: Any) -> RVal {
            .obj(ObjInstance(
                dexType: decoder,
                payload: JSONValueDecoderBox(value),
                isHost: true
            ))
        }

        func renderJSON(_ root: JSONEncodedValue) throws -> String {
            let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
            var output = ""
            var outputBytes = 0
            var nodes = 0
            var objectMembers = 0

            func append(_ value: String) throws {
                let total = outputBytes.addingReportingOverflow(value.utf8.count)
                guard !total.overflow, total.partialValue <= maximumBytes else {
                    throw serializationThrowable("encoded JSON is too long")
                }
                output.append(value)
                outputBytes = total.partialValue
            }

            func appendString(_ value: String) throws {
                guard value.utf8.count <= maximumBytes else {
                    throw serializationThrowable("JSON string is too long")
                }
                try append("\"")
                for scalar in value.unicodeScalars {
                    switch scalar.value {
                    case 0x08: try append("\\b")
                    case 0x09: try append("\\t")
                    case 0x0A: try append("\\n")
                    case 0x0C: try append("\\f")
                    case 0x0D: try append("\\r")
                    case 0x22: try append("\\\"")
                    case 0x5C: try append("\\\\")
                    case 0x00...0x1F:
                        try append(String(format: "\\u%04x", scalar.value))
                    default:
                        try append(String(scalar))
                    }
                }
                try append("\"")
            }

            func render(_ value: JSONEncodedValue, depth: Int) throws {
                nodes += 1
                guard nodes <= bridge.htmlPolicy.maximumNodes else {
                    throw serializationThrowable("encoded JSON exceeds node limit")
                }
                guard depth <= bridge.htmlPolicy.maximumDepth else {
                    throw serializationThrowable("encoded JSON exceeds depth limit")
                }
                switch value {
                case .null:
                    try append("null")
                case let .bool(value):
                    try append(value ? "true" : "false")
                case let .string(value):
                    try appendString(value)
                case let .int(value):
                    try append(String(value))
                case let .float(value):
                    guard value.isFinite else {
                        throw serializationThrowable("JSON float is out of range")
                    }
                    try append(String(value))
                case let .array(values):
                    guard values.count <= bridge.htmlPolicy.maximumNodes else {
                        throw serializationThrowable("encoded JSON array exceeds element limit")
                    }
                    try append("[")
                    for (index, element) in values.enumerated() {
                        if index > 0 { try append(",") }
                        try render(element, depth: depth + 1)
                    }
                    try append("]")
                case let .object(entries):
                    objectMembers += entries.count
                    guard objectMembers <= bridge.htmlPolicy.maximumAttributes else {
                        throw serializationThrowable("encoded JSON exceeds member limit")
                    }
                    try append("{")
                    for (index, entry) in entries.enumerated() {
                        guard entry.key.utf8.count <= bridge.htmlPolicy.maximumSelectorBytes else {
                            throw serializationThrowable("encoded JSON object key is too long")
                        }
                        if index > 0 { try append(",") }
                        try appendString(entry.key)
                        try append(":")
                        try render(entry.value, depth: depth + 1)
                    }
                    try append("}")
                }
            }

            try render(root, depth: 1)
            return output
        }

        func encoderValue(
            state: JSONEncodingState,
            depth: Int,
            encodeDefaults: Bool
        ) -> RVal {
            .obj(ObjInstance(
                dexType: encoder,
                payload: JSONValueEncoderBox(
                    state: state,
                    depth: depth,
                    encodeDefaults: encodeDefaults
                ),
                isHost: true
            ))
        }

        func serialize(
            _ strategy: RVal,
            value: RVal,
            vm: DexInterpreter,
            depth: Int = 1,
            encodeDefaults: Bool = false
        ) throws -> JSONEncodedValue {
            guard depth <= bridge.htmlPolicy.maximumDepth else {
                throw serializationThrowable("encoded JSON exceeds depth limit")
            }
            if case let .obj(object) = strategy,
               object.payload is JSONStringSerializerBox {
                let value = try requiredString([value], 0, "JSON string encode")
                guard value.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                    throw serializationThrowable("JSON string is too long")
                }
                return .string(value)
            }
            if case let .obj(object) = strategy,
               let listSerializer = object.payload as? ArrayListSerializerBox {
                let list = try listBox([value], "JSON list encode")
                try requireCollectionCapacity(list.elements.count, "JSON list encode")
                return .array(try list.elements.map {
                    try serialize(
                        listSerializer.elementSerializer,
                        value: $0,
                        vm: vm,
                        depth: depth + 1,
                        encodeDefaults: encodeDefaults
                    )
                })
            }
            guard case let .obj(serializer) = strategy else {
                throw serializationThrowable("invalid serialization strategy")
            }
            let state = JSONEncodingState()
            _ = try vm.call(
                classDescriptor: serializer.dexType,
                method: "serialize",
                prototype: "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V",
                args: [
                    strategy,
                    encoderValue(
                        state: state,
                        depth: depth,
                        encodeDefaults: encodeDefaults
                    ),
                    value,
                ]
            )
            guard let encoded = state.value else {
                throw serializationThrowable("serializer produced no JSON value")
            }
            return encoded
        }

        func deserialize(
            _ strategy: RVal,
            value: Any,
            vm: DexInterpreter
        ) throws -> RVal {
            if case let .obj(object) = strategy,
               object.payload is JSONStringSerializerBox {
                guard let value = value as? String else {
                    throw serializationThrowable("expected JSON string")
                }
                return string(value)
            }
            if case let .obj(object) = strategy,
               let listSerializer = object.payload as? ArrayListSerializerBox {
                guard let array = value as? [Any] else {
                    throw serializationThrowable("expected JSON array")
                }
                try requireCollectionCapacity(array.count, "JSON list decode")
                var elements: [RVal] = []
                elements.reserveCapacity(array.count)
                for element in array {
                    elements.append(try deserialize(
                        listSerializer.elementSerializer,
                        value: element,
                        vm: vm
                    ))
                }
                return hostList(elements, isMutable: false)
            }
            guard case let .obj(serializer) = strategy else {
                throw serializationThrowable("invalid deserialization strategy")
            }
            return try vm.call(
                classDescriptor: serializer.dexType,
                method: "deserialize",
                prototype: "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;",
                args: [strategy, decoderValue(value)]
            )
        }

        func composite(_ args: [RVal], _ method: String) throws -> JSONCompositeDecoderBox {
            guard case let .obj(object) = try argument(args, 0, method),
                  let box = object.payload as? JSONCompositeDecoderBox else {
                throw VMError.verify("\(method) receiver")
            }
            return box
        }

        func element(
            _ args: [RVal],
            _ method: String
        ) throws -> Any {
            let value = try nullableElement(args, method)
            guard !(value is NSNull) else {
                throw serializationThrowable("unexpected null JSON element")
            }
            return value
        }

        func nullableElement(
            _ args: [RVal],
            _ method: String
        ) throws -> Any {
            let box = try composite(args, method)
            guard case let .int(rawIndex) = try argument(args, 2, method),
                  rawIndex >= 0,
                  let value = box.value(at: Int(rawIndex)) else {
                throw serializationThrowable("missing or invalid JSON element")
            }
            return value
        }

        func encodingElement(
            _ args: [RVal],
            _ method: String
        ) throws -> (box: JSONCompositeEncoderBox, index: Int) {
            guard case let .obj(encoderObject) = try argument(args, 0, method),
                  let box = encoderObject.payload as? JSONCompositeEncoderBox,
                  case let .obj(descriptorObject) = try argument(args, 1, method),
                  let descriptor = descriptorObject.payload as? SerialDescriptorBox,
                  descriptor === box.descriptor,
                  case let .int(rawIndex) = try argument(args, 2, method),
                  rawIndex >= 0,
                  descriptor.elements.indices.contains(Int(rawIndex)) else {
                throw serializationThrowable("invalid JSON encoding element")
            }
            let index = Int(rawIndex)
            guard box.values[index] == nil else {
                throw serializationThrowable("JSON element was encoded more than once")
            }
            return (box, index)
        }

        func setEncodedElement(
            _ args: [RVal],
            _ method: String,
            value: JSONEncodedValue
        ) throws {
            let target = try encodingElement(args, method)
            target.box.values[target.index] = value
        }

        let json = "Lkotlinx/serialization/json/Json;"
        let jsonBuilder = "Lkotlinx/serialization/json/JsonBuilder;"
        bridge.objectFactories[json] = { _ in
            .obj(ObjInstance(
                dexType: json,
                payload: JSONConfigurationBox(encodeDefaults: false),
                isHost: true
            ))
        }
        bridge.objectFactories[jsonBuilder] = { _ in
            .obj(ObjInstance(
                dexType: jsonBuilder,
                payload: JSONBuilderBox(encodeDefaults: false),
                isHost: true
            ))
        }
        bridge.register(
            class: jsonBuilder,
            "setEncodeDefaults",
            prototype: "(Z)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "JsonBuilder.setEncodeDefaults"),
                  let builder = object.payload as? JSONBuilderBox,
                  case let .int(value) = try argument(args, 1, "JsonBuilder.setEncodeDefaults") else {
                throw VMError.verify("JsonBuilder.setEncodeDefaults arguments")
            }
            builder.encodeDefaults = value != 0
            return .null
        }

        func configuredJSON(
            base: RVal,
            action: RVal,
            vm: DexInterpreter,
            operation: String
        ) throws -> RVal {
            let inheritedDefaults: Bool
            if base.isNull {
                inheritedDefaults = false
            } else if case let .obj(object) = base,
                      object.dexType == json {
                inheritedDefaults = (object.payload as? JSONConfigurationBox)?.encodeDefaults ?? false
            } else {
                throw VMError.verify("\(operation) base Json")
            }
            guard case let .obj(actionObject) = action else {
                throw VMError.verify("\(operation) builder action")
            }
            let builderBox = JSONBuilderBox(encodeDefaults: inheritedDefaults)
            let builderValue = RVal.obj(ObjInstance(
                dexType: jsonBuilder,
                payload: builderBox,
                isHost: true
            ))
            _ = try vm.call(
                classDescriptor: actionObject.dexType,
                method: "invoke",
                prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
                args: [action, builderValue]
            )
            return .obj(ObjInstance(
                dexType: json,
                payload: JSONConfigurationBox(encodeDefaults: builderBox.encodeDefaults),
                isHost: true
            ))
        }

        bridge.register(
            class: "Lkotlinx/serialization/json/JsonKt;",
            "Json$default",
            prototype: "(Lkotlinx/serialization/json/Json;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Lkotlinx/serialization/json/Json;",
            isStatic: true
        ) { vm, args in
            guard case let .int(mask) = try argument(args, 2, "JsonKt.Json$default"),
                  try argument(args, 3, "JsonKt.Json$default").isNull else {
                throw VMError.verify("JsonKt.Json$default arguments")
            }
            let base: RVal = mask & 0x1 != 0
                ? .null
                : try argument(args, 0, "JsonKt.Json$default")
            return try configuredJSON(
                base: base,
                action: try argument(args, 1, "JsonKt.Json$default"),
                vm: vm,
                operation: "JsonKt.Json$default"
            )
        }

        let scope = RVal.obj(ObjInstance(
            dexType: "Luy/kohesive/injekt/api/InjektScope;",
            isHost: true
        ))
        bridge.register(
            class: "Luy/kohesive/injekt/InjektKt;",
            "getInjekt",
            prototype: "()Luy/kohesive/injekt/api/InjektScope;",
            isStatic: true
        ) { _, _ in scope }
        bridge.register(
            class: "Luy/kohesive/injekt/api/FullTypeReference;",
            "<init>",
            prototype: "()V"
        ) { _, _ in .null }
        bridge.register(
            class: "Luy/kohesive/injekt/api/FullTypeReference;",
            "getType",
            prototype: "()Ljava/lang/reflect/Type;"
        ) { _, _ in
            .obj(ObjInstance(
                dexType: "Ljava/lang/reflect/Type;",
                isHost: true
            ))
        }
        bridge.register(
            class: "Luy/kohesive/injekt/api/InjektFactory;",
            "getInstance",
            prototype: "(Ljava/lang/reflect/Type;)Ljava/lang/Object;"
        ) { _, _ in
            .obj(ObjInstance(
                dexType: json,
                payload: JSONConfigurationBox(encodeDefaults: false),
                isHost: true
            ))
        }

        let generatedDescriptor =
            "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;"
        bridge.objectFactories[generatedDescriptor] = { _ in
            .obj(ObjInstance(dexType: generatedDescriptor, isHost: true))
        }
        bridge.register(
            class: generatedDescriptor,
            "<init>",
            prototype: "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;I)V"
        ) { _, args in
            guard case let .obj(object) = try argument(
                args, 0, "PluginGeneratedSerialDescriptor.<init>"
            ), case let .int(elementCount) = try argument(
                args, 3, "PluginGeneratedSerialDescriptor.<init>"
            ) else {
                throw VMError.verify("PluginGeneratedSerialDescriptor constructor arguments")
            }
            let serialName = try requiredString(
                args, 1, "PluginGeneratedSerialDescriptor.<init>"
            )
            guard serialName.utf8.count <= 4_096,
                  elementCount >= 0, elementCount <= 1_024 else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "serialization descriptor exceeds limits"
                )
            }
            object.payload = SerialDescriptorBox(
                serialName: serialName,
                expectedElementCount: Int(elementCount)
            )
            return .null
        }
        bridge.register(
            class: generatedDescriptor,
            "addElement",
            prototype: "(Ljava/lang/String;Z)V"
        ) { _, args in
            guard case let .obj(object) = try argument(
                args, 0, "PluginGeneratedSerialDescriptor.addElement"
            ), let descriptor = object.payload as? SerialDescriptorBox,
                  case let .int(isOptional) = try argument(
                    args, 2, "PluginGeneratedSerialDescriptor.addElement"
                  ) else {
                throw VMError.verify("PluginGeneratedSerialDescriptor.addElement arguments")
            }
            let name = try requiredString(
                args, 1, "PluginGeneratedSerialDescriptor.addElement"
            )
            guard name.utf8.count <= 4_096,
                  descriptor.elements.count < descriptor.expectedElementCount else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "serialization descriptor element exceeds limits"
                )
            }
            descriptor.elements.append((name, isOptional != 0))
            return .null
        }

        let arrayListSerializer = "Lkotlinx/serialization/internal/ArrayListSerializer;"
        let stringSerializer = "Lkotlinx/serialization/internal/StringSerializer;"
        bridge.staticFields["\(stringSerializer)->INSTANCE"] = .obj(ObjInstance(
            dexType: stringSerializer,
            payload: JSONStringSerializerBox(),
            isHost: true
        ))
        bridge.objectFactories[arrayListSerializer] = { _ in
            .obj(ObjInstance(dexType: arrayListSerializer, isHost: true))
        }
        bridge.register(
            class: arrayListSerializer,
            "<init>",
            prototype: "(Lkotlinx/serialization/KSerializer;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(
                args, 0, "ArrayListSerializer.<init>"
            ) else { throw VMError.verify("ArrayListSerializer receiver") }
            object.payload = ArrayListSerializerBox(elementSerializer: try argument(
                args, 1, "ArrayListSerializer.<init>"
            ))
            return .null
        }

        bridge.register(
            class: json,
            "encodeToString",
            prototype: "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;"
        ) { vm, args in
            guard case let .obj(jsonObject) = try argument(args, 0, "Json.encodeToString"),
                  jsonObject.dexType == json else {
                throw VMError.verify("Json.encodeToString receiver")
            }
            let encodeDefaults =
                (jsonObject.payload as? JSONConfigurationBox)?.encodeDefaults ?? false
            let encoded = try serialize(
                try argument(args, 1, "Json.encodeToString"),
                value: try argument(args, 2, "Json.encodeToString"),
                vm: vm,
                encodeDefaults: encodeDefaults
            )
            return string(try renderJSON(encoded))
        }
        bridge.register(
            class: json,
            "decodeFromString",
            prototype: "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;"
        ) { vm, args in
            let source = try requiredString(args, 2, "Json.decodeFromString")
            guard source.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw serializationThrowable("JSON input is too long")
            }
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(
                    with: Data(source.utf8),
                    options: [.fragmentsAllowed]
                )
            } catch {
                throw serializationThrowable("malformed JSON")
            }
            try validateJSON(root)
            return try deserialize(
                try argument(args, 1, "Json.decodeFromString"),
                value: root,
                vm: vm
            )
        }
        bridge.register(
            class: "Lkotlinx/serialization/json/okio/OkioStreamsKt;",
            "decodeFromBufferedSource",
            prototype: "(Lkotlinx/serialization/json/Json;Lkotlinx/serialization/DeserializationStrategy;Lokio/BufferedSource;)Ljava/lang/Object;",
            isStatic: true
        ) { vm, args in
            let operation = "OkioStreamsKt.decodeFromBufferedSource"
            guard case let .obj(jsonObject) = try argument(args, 0, operation),
                  jsonObject.dexType == "Lkotlinx/serialization/json/Json;",
                  case .obj = try argument(args, 1, operation),
                  case let .obj(sourceObject) = try argument(args, 2, operation),
                  sourceObject.dexType == "Lokio/BufferedSource;",
                  let source = sourceObject.payload as? ResponseBodyBox else {
                throw VMError.verify("\(operation) arguments")
            }
            guard !source.isClosed else {
                throw hostThrowable(
                    "Ljava/lang/IllegalStateException;",
                    "decodeFromBufferedSource on closed source"
                )
            }
            let remaining = source.bytes.count - source.offset
            guard remaining <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw serializationThrowable("JSON input is too long")
            }
            let bytes = Array(source.bytes[source.offset...])
            source.offset = source.bytes.count
            guard let text = String(data: Data(bytes), encoding: .utf8) else {
                throw serializationThrowable("JSON input is not valid UTF-8")
            }
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(
                    with: Data(text.utf8),
                    options: [.fragmentsAllowed]
                )
            } catch {
                throw serializationThrowable("malformed JSON")
            }
            try validateJSON(root)
            return try deserialize(
                try argument(args, 1, operation),
                value: root,
                vm: vm
            )
        }

        bridge.register(
            class: encoder,
            "beginStructure",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeEncoder;"
        ) { _, args in
            guard case let .obj(valueObject) = try argument(args, 0, "Encoder.beginStructure"),
                  let value = valueObject.payload as? JSONValueEncoderBox,
                  case let .obj(descriptorObject) = try argument(
                    args, 1, "Encoder.beginStructure"
                  ), let descriptor = descriptorObject.payload as? SerialDescriptorBox,
                  descriptor.elements.count == descriptor.expectedElementCount else {
                throw serializationThrowable("invalid JSON object structure")
            }
            return .obj(ObjInstance(
                dexType: compositeEncoder,
                payload: JSONCompositeEncoderBox(
                    state: value.state,
                    descriptor: descriptor,
                    depth: value.depth,
                    encodeDefaults: value.encodeDefaults
                ),
                isHost: true
            ))
        }
        bridge.register(
            class: compositeEncoder,
            "shouldEncodeElementDefault",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z"
        ) { _, args in
            let target = try encodingElement(
                args,
                "CompositeEncoder.shouldEncodeElementDefault"
            )
            return .int(target.box.encodeDefaults ? 1 : 0)
        }
        bridge.register(
            class: compositeEncoder,
            "encodeBooleanElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;IZ)V"
        ) { _, args in
            guard case let .int(value) = try argument(
                args, 3, "CompositeEncoder.encodeBooleanElement"
            ) else { throw serializationThrowable("expected JSON boolean") }
            try setEncodedElement(
                args,
                "CompositeEncoder.encodeBooleanElement",
                value: .bool(value != 0)
            )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "encodeStringElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILjava/lang/String;)V"
        ) { _, args in
            let value = try requiredString(args, 3, "CompositeEncoder.encodeStringElement")
            guard value.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw serializationThrowable("JSON string is too long")
            }
            try setEncodedElement(
                args,
                "CompositeEncoder.encodeStringElement",
                value: .string(value)
            )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "encodeIntElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;II)V"
        ) { _, args in
            guard case let .int(value) = try argument(
                args, 3, "CompositeEncoder.encodeIntElement"
            ) else { throw serializationThrowable("expected JSON integer") }
            try setEncodedElement(
                args,
                "CompositeEncoder.encodeIntElement",
                value: .int(value)
            )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "encodeFloatElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;IF)V"
        ) { _, args in
            guard case let .float(value) = try argument(
                args, 3, "CompositeEncoder.encodeFloatElement"
            ), value.isFinite else { throw serializationThrowable("expected finite JSON float") }
            try setEncodedElement(
                args,
                "CompositeEncoder.encodeFloatElement",
                value: .float(value)
            )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "encodeSerializableElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V"
        ) { vm, args in
            let target = try encodingElement(args, "CompositeEncoder.encodeSerializableElement")
            let value = try argument(args, 4, "CompositeEncoder.encodeSerializableElement")
            guard !value.isNull else {
                throw serializationThrowable("unexpected null JSON element")
            }
            target.box.values[target.index] = try serialize(
                try argument(args, 3, "CompositeEncoder.encodeSerializableElement"),
                value: value,
                vm: vm,
                depth: target.box.depth + 1,
                encodeDefaults: target.box.encodeDefaults
            )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "encodeNullableSerializableElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V"
        ) { vm, args in
            let target = try encodingElement(
                args, "CompositeEncoder.encodeNullableSerializableElement"
            )
            let value = try argument(args, 4, "CompositeEncoder.encodeNullableSerializableElement")
            target.box.values[target.index] = value.isNull
                ? .null
                : try serialize(
                    try argument(args, 3, "CompositeEncoder.encodeNullableSerializableElement"),
                    value: value,
                    vm: vm,
                    depth: target.box.depth + 1,
                    encodeDefaults: target.box.encodeDefaults
                )
            return .null
        }
        bridge.register(
            class: compositeEncoder,
            "endStructure",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V"
        ) { _, args in
            guard case let .obj(encoderObject) = try argument(
                args, 0, "CompositeEncoder.endStructure"
            ), let box = encoderObject.payload as? JSONCompositeEncoderBox,
                  case let .obj(descriptorObject) = try argument(
                    args, 1, "CompositeEncoder.endStructure"
                  ), let descriptor = descriptorObject.payload as? SerialDescriptorBox,
                  descriptor === box.descriptor,
                  box.state.value == nil else {
                throw serializationThrowable("invalid JSON encoder completion")
            }
            let entries = try box.values.keys.sorted().map { index -> (
                key: String,
                value: JSONEncodedValue
            ) in
                guard descriptor.elements.indices.contains(index),
                      let value = box.values[index] else {
                    throw serializationThrowable("invalid encoded JSON element")
                }
                return (descriptor.elements[index].name, value)
            }
            box.state.value = .object(entries)
            return .null
        }

        bridge.register(
            class: decoder,
            "beginStructure",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;"
        ) { _, args in
            guard case let .obj(valueObject) = try argument(args, 0, "Decoder.beginStructure"),
                  let value = valueObject.payload as? JSONValueDecoderBox,
                  let object = value.value as? [String: Any],
                  case let .obj(descriptorObject) = try argument(
                    args, 1, "Decoder.beginStructure"
                  ), let descriptor = descriptorObject.payload as? SerialDescriptorBox else {
                throw serializationThrowable("expected JSON object structure")
            }
            return .obj(ObjInstance(
                dexType: compositeDecoder,
                payload: JSONCompositeDecoderBox(object: object, descriptor: descriptor),
                isHost: true
            ))
        }
        bridge.register(
            class: compositeDecoder,
            "decodeSequentially",
            prototype: "()Z"
        ) { _, _ in .int(0) }
        bridge.register(
            class: compositeDecoder,
            "decodeElementIndex",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;)I"
        ) { _, args in
            let box = try composite(args, "CompositeDecoder.decodeElementIndex")
            guard box.nextPresentIndex < box.presentIndices.count else {
                return .int(-1)
            }
            let index = box.presentIndices[box.nextPresentIndex]
            box.nextPresentIndex += 1
            return .int(Int32(index))
        }
        bridge.register(
            class: compositeDecoder,
            "decodeBooleanElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z"
        ) { _, args in
            let rawValue = try element(args, "CompositeDecoder.decodeBooleanElement")
            guard isJSONBoolean(rawValue), let value = rawValue as? Bool else {
                throw serializationThrowable("expected JSON boolean")
            }
            return .int(value ? 1 : 0)
        }
        bridge.register(
            class: compositeDecoder,
            "decodeIntElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)I"
        ) { _, args in
            let value = try element(args, "CompositeDecoder.decodeIntElement")
            guard !isJSONBoolean(value), let number = value as? NSNumber else {
                throw serializationThrowable("expected JSON integer")
            }
            let result = number.doubleValue
            guard result.isFinite, result.rounded(.towardZero) == result,
                  result >= Double(Int32.min), result <= Double(Int32.max) else {
                throw serializationThrowable("JSON integer is out of range")
            }
            return .int(Int32(result))
        }
        bridge.register(
            class: compositeDecoder,
            "decodeLongElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)J"
        ) { _, args in
            let value = try element(args, "CompositeDecoder.decodeLongElement")
            guard !isJSONBoolean(value), let number = value as? NSNumber else {
                throw serializationThrowable("expected JSON long integer")
            }
            let result: Int64
            if let exact = Int64(number.stringValue) {
                result = exact
            } else {
                let double = number.doubleValue
                guard double.isFinite,
                      double.rounded(.towardZero) == double,
                      double >= -9_223_372_036_854_775_808,
                      double < 9_223_372_036_854_775_808 else {
                    throw serializationThrowable("JSON long integer is out of range")
                }
                result = Int64(double)
            }
            return .long(result)
        }
        bridge.register(
            class: compositeDecoder,
            "decodeFloatElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)F"
        ) { _, args in
            let value = try element(args, "CompositeDecoder.decodeFloatElement")
            guard !isJSONBoolean(value), let number = value as? NSNumber else {
                throw serializationThrowable("expected JSON number")
            }
            let result = number.floatValue
            guard result.isFinite else {
                throw serializationThrowable("JSON float is out of range")
            }
            return .float(result)
        }
        bridge.register(
            class: compositeDecoder,
            "decodeStringElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Ljava/lang/String;"
        ) { _, args in
            guard let value = try element(
                args, "CompositeDecoder.decodeStringElement"
            ) as? String else {
                throw serializationThrowable("expected JSON string")
            }
            return string(value)
        }
        bridge.register(
            class: compositeDecoder,
            "decodeSerializableElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;"
        ) { vm, args in
            try deserialize(
                try argument(args, 3, "CompositeDecoder.decodeSerializableElement"),
                value: try element(args, "CompositeDecoder.decodeSerializableElement"),
                vm: vm
            )
        }
        bridge.register(
            class: compositeDecoder,
            "decodeNullableSerializableElement",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;"
        ) { vm, args in
            let value = try nullableElement(
                args, "CompositeDecoder.decodeNullableSerializableElement"
            )
            if value is NSNull {
                return .null
            }
            return try deserialize(
                try argument(args, 3, "CompositeDecoder.decodeNullableSerializableElement"),
                value: value,
                vm: vm
            )
        }
        bridge.register(
            class: compositeDecoder,
            "endStructure",
            prototype: "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V"
        ) { _, _ in .null }
        bridge.register(
            class: "Lkotlinx/serialization/internal/PluginExceptionsKt;",
            "throwMissingFieldException",
            prototype: "(IILkotlinx/serialization/descriptors/SerialDescriptor;)V",
            isStatic: true
        ) { _, _ in
            throw serializationThrowable("required JSON field is missing")
        }
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
        let locale = "Ljava/util/Locale;"
        bridge.staticFields["\(locale)->ROOT"] = .obj(ObjInstance(
            dexType: locale,
            payload: "ROOT",
            isHost: true
        ))
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
        bridge.register(
            class: d,
            "toLowerCase",
            prototype: "(Ljava/util/Locale;)Ljava/lang/String;"
        ) { _, args in
            let value = try requiredString(args, 0, "String.toLowerCase")
            guard case let .obj(localeObject) = try argument(args, 1, "String.toLowerCase"),
                  localeObject.dexType == locale,
                  localeObject.payload as? String == "ROOT" else {
                throw VMError.verify("String.toLowerCase supports Locale.ROOT only")
            }
            let lowered = value.lowercased()
            guard lowered.utf8.count <= bridge.htmlPolicy.maximumExtractedStringBytes else {
                throw DEXThrowable(string(
                    "IllegalArgumentException: lowercase output is too long"
                ))
            }
            return string(lowered)
        }
    }

    /// Exact UTF-8 -> Okio ByteString -> Base64 path used by current
    /// lib 1.6 API-backed sources. Both raw and encoded values remain bounded;
    /// no filesystem, native code, or arbitrary charset implementation is
    /// exposed through this surface.
    private static func registerByteEncodingSurface(_ bridge: HostBridge) {
        let charset = "Ljava/nio/charset/Charset;"
        let byteString = "Lokio/ByteString;"
        let companion = "Lokio/ByteString$Companion;"
        let maximumBytes = 1_048_576

        let utf8 = RVal.obj(ObjInstance(
            dexType: charset,
            payload: "UTF-8",
            isHost: true
        ))
        bridge.staticFields["Lkotlin/text/Charsets;->UTF_8"] = utf8
        bridge.staticFields["Ljava/nio/charset/StandardCharsets;->UTF_8"] = utf8

        bridge.register(
            class: "Ljava/lang/String;",
            "getBytes",
            prototype: "(Ljava/nio/charset/Charset;)[B"
        ) { _, args in
            let value = try requiredString(args, 0, "String.getBytes")
            guard case let .obj(charsetObject) = try argument(args, 1, "String.getBytes"),
                  charsetObject.dexType == charset,
                  let charsetName = charsetObject.payload as? String,
                  charsetName.caseInsensitiveCompare("UTF-8") == .orderedSame else {
                throw DEXThrowable(string(
                    "UnsupportedCharsetException: String.getBytes supports UTF-8 only"
                ))
            }
            let bytes = Array(value.utf8)
            guard bytes.count <= maximumBytes else {
                throw DEXThrowable(string(
                    "IllegalArgumentException: UTF-8 value exceeds 1048576 bytes"
                ))
            }
            return byteArray(bytes)
        }

        let companionValue = RVal.obj(ObjInstance(
            dexType: companion,
            isHost: true
        ))
        bridge.staticFields["\(byteString)->Companion"] = companionValue
        bridge.register(
            class: companion,
            "of$default",
            prototype: "(Lokio/ByteString$Companion;[BIIILjava/lang/Object;)Lokio/ByteString;",
            isStatic: true
        ) { _, args in
            guard case let .obj(companionObject) = try argument(args, 0, "ByteString.Companion.of$default"),
                  companionObject.dexType == companion,
                  case let .arr(array) = try argument(args, 1, "ByteString.Companion.of$default"),
                  array.elemDescriptor == "B",
                  array.elements.count <= maximumBytes,
                  case let .int(rawOffset) = try argument(args, 2, "ByteString.Companion.of$default"),
                  case let .int(rawCount) = try argument(args, 3, "ByteString.Companion.of$default"),
                  case let .int(mask) = try argument(args, 4, "ByteString.Companion.of$default"),
                  try argument(args, 5, "ByteString.Companion.of$default").isNull else {
                throw VMError.verify("ByteString.Companion.of$default arguments")
            }
            let offset = mask & 0x1 != 0 ? 0 : Int(rawOffset)
            let count = mask & 0x2 != 0 ? array.elements.count : Int(rawCount)
            guard offset >= 0,
                  count >= 0,
                  offset <= array.elements.count,
                  count <= array.elements.count - offset else {
                throw DEXThrowable(string(
                    "ArrayIndexOutOfBoundsException: ByteString range"
                ))
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for value in array.elements[offset..<(offset + count)] {
                guard case let .int(rawByte) = value,
                      rawByte >= Int32(Int8.min),
                      rawByte <= Int32(UInt8.max) else {
                    throw VMError.verify("ByteString byte array contents")
                }
                bytes.append(UInt8(truncatingIfNeeded: rawByte))
            }
            return .obj(ObjInstance(
                dexType: byteString,
                payload: bytes,
                isHost: true
            ))
        }
        bridge.register(class: byteString, "base64", prototype: "()Ljava/lang/String;") { _, args in
            guard case let .obj(object) = try argument(args, 0, "ByteString.base64"),
                  object.dexType == byteString,
                  let bytes = object.payload as? [UInt8],
                  bytes.count <= maximumBytes else {
                throw VMError.verify("ByteString.base64 receiver")
            }
            return string(Data(bytes).base64EncodedString())
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

    private static func boxedLong(_ value: Int64) -> RVal {
        .obj(ObjInstance(
            dexType: "Ljava/lang/Long;",
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
        bridge.register(
            class: "Ljava/lang/Long;",
            "valueOf",
            prototype: "(J)Ljava/lang/Long;",
            isStatic: true
        ) { _, args in
            guard case let .long(value) = try argument(args, 0, "Long.valueOf") else {
                throw VMError.verify("Long.valueOf argument")
            }
            return boxedLong(value)
        }
        bridge.register(class: "Ljava/lang/Number;", "intValue", prototype: "()I") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Number.intValue") else {
                throw VMError.verify("Number.intValue receiver")
            }
            if let value = object.payload as? Int32 { return .int(value) }
            if let value = object.payload as? Int64 {
                return .int(Int32(truncatingIfNeeded: value))
            }
            throw VMError.verify("Number.intValue receiver")
        }
        bridge.register(class: "Ljava/lang/Number;", "longValue", prototype: "()J") { _, args in
            guard case let .obj(object) = try argument(args, 0, "Number.longValue") else {
                throw VMError.verify("Number.longValue receiver")
            }
            if let value = object.payload as? Int64 { return .long(value) }
            if let value = object.payload as? Int32 { return .long(Int64(value)) }
            throw VMError.verify("Number.longValue receiver")
        }
    }

    private static func requireCollectionCapacity(_ count: Int, _ method: String) throws {
        guard count <= 1_000_000 else {
            throw VMError.verify("\(method) exceeds 1000000 collection elements")
        }
    }

    private static func registerJavaTimeSurface(_ bridge: HostBridge) {
        let dateFormatter = "Ljava/time/format/DateTimeFormatter;"
        let localDate = "Ljava/time/LocalDate;"
        let zoneID = "Ljava/time/ZoneId;"
        let zonedDateTime = "Ljava/time/ZonedDateTime;"
        let instant = "Ljava/time/Instant;"
        let kotlinInstant = "Lkotlin/time/Instant;"
        let kotlinInstantCompanion = "Lkotlin/time/Instant$Companion;"

        bridge.staticFields["\(kotlinInstant)->Companion"] = .obj(ObjInstance(
            dexType: kotlinInstantCompanion,
            isHost: true
        ))
        bridge.register(
            class: kotlinInstantCompanion,
            "parseOrNull",
            prototype: "(Ljava/lang/CharSequence;)Lkotlin/time/Instant;"
        ) { _, args in
            let input = try requiredString(args, 1, "kotlin.time.Instant.parseOrNull")
            guard input.utf8.count <= 256 else { return .null }
            let options: [ISO8601DateFormatter.Options] = [
                [.withInternetDateTime, .withFractionalSeconds],
                [.withInternetDateTime],
            ]
            var parsed: Date?
            for option in options {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = option
                if let value = formatter.date(from: input) {
                    parsed = value
                    break
                }
            }
            guard parsed != nil else { return .null }

            // Date stores fractional seconds as a binary floating-point value.
            // Derive milliseconds from the decimal ISO fraction so Kotlin's
            // exact truncation semantics cannot lose one millisecond to drift.
            let fractionStart = input.firstIndex(of: ".")
            let fractionEnd = fractionStart.map { start in
                input[input.index(after: start)...].firstIndex(where: { !$0.isNumber })
                    ?? input.endIndex
            }
            let fraction = fractionStart.flatMap { start in
                fractionEnd.map { String(input[input.index(after: start)..<$0]) }
            } ?? ""
            let normalized: String
            if let fractionStart, let fractionEnd {
                normalized = String(input[..<fractionStart]) + String(input[fractionEnd...])
            } else {
                normalized = input
            }
            let wholeFormatter = ISO8601DateFormatter()
            wholeFormatter.formatOptions = [.withInternetDateTime]
            guard let wholeDate = wholeFormatter.date(from: normalized) else { return .null }
            let seconds = wholeDate.timeIntervalSince1970.rounded()
            guard seconds.isFinite,
                  seconds >= Double(Int64.min / 1_000),
                  seconds <= Double(Int64.max / 1_000) else { return .null }
            let wholeMilliseconds = Int64(seconds).multipliedReportingOverflow(by: 1_000)
            guard !wholeMilliseconds.overflow else { return .null }
            let fractionMilliseconds = Int64(String((fraction + "000").prefix(3))) ?? 0
            let milliseconds = wholeMilliseconds.partialValue.addingReportingOverflow(
                fractionMilliseconds
            )
            guard !milliseconds.overflow else { return .null }
            return .obj(ObjInstance(
                dexType: kotlinInstant,
                payload: EpochMillisecondsBox(value: milliseconds.partialValue),
                isHost: true
            ))
        }
        bridge.register(
            class: kotlinInstant,
            "toEpochMilliseconds",
            prototype: "()J"
        ) { _, args in
            guard case let .obj(object) = try argument(
                args, 0, "kotlin.time.Instant.toEpochMilliseconds"
            ), let epoch = object.payload as? EpochMillisecondsBox else {
                throw VMError.verify("kotlin.time.Instant.toEpochMilliseconds receiver")
            }
            return .long(epoch.value)
        }

        bridge.register(
            class: dateFormatter,
            "ofPattern",
            prototype: "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatter;",
            isStatic: true
        ) { _, args in
            let pattern = try requiredString(args, 0, "DateTimeFormatter.ofPattern")
            guard !pattern.isEmpty, pattern.utf8.count <= 256 else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "invalid date pattern"
                )
            }
            return .obj(ObjInstance(
                dexType: dateFormatter,
                payload: pattern,
                isHost: true
            ))
        }
        bridge.register(
            class: localDate,
            "parse",
            prototype: "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalDate;",
            isStatic: true
        ) { _, args in
            let input = try requiredString(args, 0, "LocalDate.parse")
            guard input.utf8.count <= 256,
                  case let .obj(formatObject) = try argument(args, 1, "LocalDate.parse"),
                  let pattern = formatObject.payload as? String else {
                throw hostThrowable(
                    "Ljava/time/format/DateTimeParseException;",
                    "invalid local date"
                )
            }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            formatter.isLenient = false
            guard let parsed = formatter.date(from: input),
                  formatter.string(from: parsed) == input else {
                throw hostThrowable(
                    "Ljava/time/format/DateTimeParseException;",
                    "invalid local date"
                )
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = calendar.dateComponents([.year, .month, .day], from: parsed)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                throw hostThrowable(
                    "Ljava/time/format/DateTimeParseException;",
                    "invalid local date"
                )
            }
            return .obj(ObjInstance(
                dexType: localDate,
                payload: LocalDateBox(year: year, month: month, day: day),
                isHost: true
            ))
        }
        bridge.register(
            class: zoneID,
            "systemDefault",
            prototype: "()Ljava/time/ZoneId;",
            isStatic: true
        ) { _, _ in
            .obj(ObjInstance(
                dexType: zoneID,
                payload: ZoneIDBox(timeZone: .current),
                isHost: true
            ))
        }
        bridge.register(
            class: localDate,
            "atStartOfDay",
            prototype: "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;"
        ) { _, args in
            guard case let .obj(dateObject) = try argument(args, 0, "LocalDate.atStartOfDay"),
                  let date = dateObject.payload as? LocalDateBox,
                  case let .obj(zoneObject) = try argument(args, 1, "LocalDate.atStartOfDay"),
                  let zone = zoneObject.payload as? ZoneIDBox else {
                throw VMError.verify("LocalDate.atStartOfDay arguments")
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone.timeZone
            guard let start = calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: zone.timeZone,
                year: date.year,
                month: date.month,
                day: date.day,
                hour: 0,
                minute: 0,
                second: 0
            )) else {
                throw hostThrowable(
                    "Ljava/time/DateTimeException;",
                    "invalid zoned date"
                )
            }
            let milliseconds = Int64((start.timeIntervalSince1970 * 1_000).rounded())
            return .obj(ObjInstance(
                dexType: zonedDateTime,
                payload: EpochMillisecondsBox(value: milliseconds),
                isHost: true
            ))
        }
        bridge.register(
            class: "Ljava/time/chrono/ChronoZonedDateTime;",
            "toInstant",
            prototype: "()Ljava/time/Instant;"
        ) { _, args in
            guard case let .obj(object) = try argument(
                args, 0, "ChronoZonedDateTime.toInstant"
            ), let epoch = object.payload as? EpochMillisecondsBox else {
                throw VMError.verify("ChronoZonedDateTime.toInstant receiver")
            }
            return .obj(ObjInstance(
                dexType: instant,
                payload: epoch,
                isHost: true
            ))
        }
        bridge.register(
            class: instant,
            "toEpochMilli",
            prototype: "()J"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Instant.toEpochMilli"),
                  let epoch = object.payload as? EpochMillisecondsBox else {
                throw VMError.verify("Instant.toEpochMilli receiver")
            }
            return .long(epoch.value)
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
            "distinct",
            prototype: "(Ljava/lang/Iterable;)Ljava/util/List;",
            isStatic: true
        ) { _, args in
            let source = try listBox(args, "CollectionsKt.distinct").elements
            try requireCollectionCapacity(source.count, "CollectionsKt.distinct")
            let maximumComparisons = 8_000_000
            var comparisons = 0
            var result: [RVal] = []
            result.reserveCapacity(source.count)
            for value in source {
                var isDuplicate = false
                for existing in result {
                    guard comparisons < maximumComparisons else {
                        throw VMError.verify(
                            "CollectionsKt.distinct exceeds 8000000 equality comparisons"
                        )
                    }
                    comparisons += 1
                    if javaValueEquals(existing, value) {
                        isDuplicate = true
                        break
                    }
                }
                if !isDuplicate { result.append(value) }
            }
            return hostList(result, isMutable: false)
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
            class: "Lkotlin/comparisons/ComparisonsKt;",
            "compareValues",
            prototype: "(Ljava/lang/Comparable;Ljava/lang/Comparable;)I",
            isStatic: true
        ) { _, args in
            let lhs = try argument(args, 0, "ComparisonsKt.compareValues")
            let rhs = try argument(args, 1, "ComparisonsKt.compareValues")
            if lhs.isNull { return .int(rhs.isNull ? 0 : -1) }
            if rhs.isNull { return .int(1) }
            guard case let .obj(lhsObject) = lhs,
                  case let .obj(rhsObject) = rhs,
                  let lhsValue = lhsObject.payload as? Int32,
                  let rhsValue = rhsObject.payload as? Int32 else {
                throw VMError.verify("ComparisonsKt.compareValues supports boxed Int values only")
            }
            return .int(lhsValue == rhsValue ? 0 : (lhsValue < rhsValue ? -1 : 1))
        }
        bridge.register(
            class: collections,
            "sortedWith",
            prototype: "(Ljava/lang/Iterable;Ljava/util/Comparator;)Ljava/util/List;",
            isStatic: true
        ) { vm, args in
            var input = try listBox(args, "CollectionsKt.sortedWith").elements
            guard input.count <= 65_536,
                  case let .obj(comparator) = try argument(
                    args, 1, "CollectionsKt.sortedWith"
                  ) else {
                throw VMError.verify("CollectionsKt.sortedWith arguments or size")
            }
            guard input.count > 1 else { return hostList(input, isMutable: false) }

            var output = input
            var width = 1
            while width < input.count {
                var start = 0
                while start < input.count {
                    let middle = min(start + width, input.count)
                    let end = min(start + width * 2, input.count)
                    var left = start
                    var right = middle
                    var destination = start
                    while left < middle && right < end {
                        let comparison = try vm.call(
                            classDescriptor: comparator.dexType,
                            method: "compare",
                            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)I",
                            args: [.obj(comparator), input[left], input[right]]
                        )
                        guard case let .int(order) = comparison else {
                            throw VMError.verify("Comparator.compare result")
                        }
                        if order <= 0 {
                            output[destination] = input[left]
                            left += 1
                        } else {
                            output[destination] = input[right]
                            right += 1
                        }
                        destination += 1
                    }
                    while left < middle {
                        output[destination] = input[left]
                        left += 1
                        destination += 1
                    }
                    while right < end {
                        output[destination] = input[right]
                        right += 1
                        destination += 1
                    }
                    start = end
                }
                swap(&input, &output)
                width *= 2
            }
            return hostList(input, isMutable: false)
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
        bridge.register(
            class: collections,
            "joinToString$default",
            prototype: "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;",
            isStatic: true
        ) { _, args in
            let values = try listBox(args, "CollectionsKt.joinToString").elements
            guard case let .int(mask) = try argument(args, 7, "CollectionsKt.joinToString mask") else {
                throw VMError.verify("CollectionsKt.joinToString default mask")
            }
            let separator = mask & 0x01 != 0
                ? ", "
                : try requiredString(args, 1, "CollectionsKt.joinToString separator")
            let prefix = mask & 0x02 != 0
                ? ""
                : try requiredString(args, 2, "CollectionsKt.joinToString prefix")
            let postfix = mask & 0x04 != 0
                ? ""
                : try requiredString(args, 3, "CollectionsKt.joinToString postfix")
            let limit: Int
            if mask & 0x08 != 0 {
                limit = -1
            } else {
                guard case let .int(value) = try argument(
                    args, 4, "CollectionsKt.joinToString limit"
                ) else { throw VMError.verify("CollectionsKt.joinToString limit") }
                limit = Int(value)
            }
            let truncated = mask & 0x10 != 0
                ? "..."
                : try requiredString(args, 5, "CollectionsKt.joinToString truncated")
            let transform = mask & 0x20 != 0
                ? RVal.null
                : try argument(args, 6, "CollectionsKt.joinToString transform")
            guard transform.isNull else {
                throw VMError.verify("CollectionsKt.joinToString transform is not implemented")
            }

            let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
            var output = ""
            var outputBytes = 0
            func append(_ value: String) throws {
                let count = value.utf8.count
                let total = outputBytes.addingReportingOverflow(count)
                guard !total.overflow, total.partialValue <= maximumBytes else {
                    throw hostThrowable(
                        "Ljava/lang/IllegalArgumentException;",
                        "joined string is too long"
                    )
                }
                output.append(value)
                outputBytes = total.partialValue
            }

            try append(prefix)
            var count = 0
            for value in values {
                count += 1
                if count > 1 { try append(separator) }
                if limit < 0 || count <= limit {
                    try append(vmStringValue(value))
                } else {
                    break
                }
            }
            if limit >= 0, count > limit { try append(truncated) }
            try append(postfix)
            return string(output)
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
        for descriptor in ["Ljava/util/List;", "Ljava/util/ArrayList;"] {
            bridge.register(class: descriptor, "size", prototype: "()I") { _, args in
                .int(Int32(clamping: try listBox(args, "\(descriptor).size").elements.count))
            }
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
        let select = "Leu/kanade/tachiyomi/source/model/Filter$Select;"
        let separator = "Leu/kanade/tachiyomi/source/model/Filter$Separator;"
        let sort = "Leu/kanade/tachiyomi/source/model/Filter$Sort;"
        let sortSelection = "Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;"
        let textFilter = "Leu/kanade/tachiyomi/source/model/Filter$Text;"
        let triState = "Leu/kanade/tachiyomi/source/model/Filter$TriState;"
        let filterList = "Leu/kanade/tachiyomi/source/model/FilterList;"
        for descriptor in [
            checkBox, group, header, select, separator, sort, sortSelection,
            textFilter, triState, filterList,
        ] {
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
                kind: .checkBox,
                name: vmStringValue(try argument(args, 1, "Filter.CheckBox.<init>")),
                state: boxedBoolean(state)
            )
            return .null
        }
        bridge.register(class: checkBox, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.CheckBox.getState")
        }

        bridge.register(
            class: checkBox,
            "<init>",
            prototype: "(Ljava/lang/String;Z)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.CheckBox.<init>"),
                  case let .int(rawState) = try argument(args, 2, "Filter.CheckBox.<init>") else {
                throw VMError.verify("Filter.CheckBox constructor arguments")
            }
            object.payload = FilterStateBox(
                kind: .checkBox,
                name: vmStringValue(try argument(args, 1, "Filter.CheckBox.<init>")),
                state: boxedBoolean(rawState != 0)
            )
            return .null
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
                kind: .group,
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
                kind: .header,
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
                kind: .separator,
                name: vmStringValue(try argument(args, 1, "Filter.Separator.<init>")),
                state: .null
            )
            return .null
        }

        func registerSelectConstructor(_ prototype: String, hasDefaultMask: Bool) {
            bridge.register(class: select, "<init>", prototype: prototype) { _, args in
                guard case let .obj(object) = try argument(args, 0, "Filter.Select.<init>"),
                      case let .arr(rawValues) = try argument(args, 2, "Filter.Select.<init>"),
                      case let .int(rawState) = try argument(args, 3, "Filter.Select.<init>") else {
                    throw VMError.verify("Filter.Select constructor arguments")
                }
                let state: Int32
                if hasDefaultMask {
                    guard case let .int(mask) = try argument(args, 4, "Filter.Select.<init>") else {
                        throw VMError.verify("Filter.Select default constructor mask")
                    }
                    state = mask & 0x4 == 0 ? rawState : 0
                } else {
                    state = rawState
                }
                guard let values = filterStringValues(rawValues) else {
                    throw VMError.verify("Filter.Select values")
                }
                object.payload = FilterStateBox(
                    kind: .select,
                    name: vmStringValue(try argument(args, 1, "Filter.Select.<init>")),
                    values: values,
                    state: boxedInteger(state)
                )
                return .null
            }
        }
        registerSelectConstructor(
            "(Ljava/lang/String;[Ljava/lang/Object;IILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            hasDefaultMask: true
        )
        registerSelectConstructor(
            "(Ljava/lang/String;[Ljava/lang/Object;I)V",
            hasDefaultMask: false
        )
        bridge.register(class: select, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Select.getState")
        }

        func registerSortConstructor(_ prototype: String, hasDefaultMask: Bool) {
            bridge.register(class: sort, "<init>", prototype: prototype) { _, args in
                guard case let .obj(object) = try argument(args, 0, "Filter.Sort.<init>"),
                      case let .arr(rawValues) = try argument(args, 2, "Filter.Sort.<init>") else {
                    throw VMError.verify("Filter.Sort constructor arguments")
                }
                let state: RVal
                if hasDefaultMask {
                    guard case let .int(mask) = try argument(args, 4, "Filter.Sort.<init>") else {
                        throw VMError.verify("Filter.Sort default constructor mask")
                    }
                    state = mask & 0x4 == 0
                        ? try argument(args, 3, "Filter.Sort.<init>")
                        : .null
                } else {
                    state = try argument(args, 3, "Filter.Sort.<init>")
                }
                guard let values = filterStringValues(rawValues) else {
                    throw VMError.verify("Filter.Sort values")
                }
                object.payload = FilterStateBox(
                    kind: .sort,
                    name: vmStringValue(try argument(args, 1, "Filter.Sort.<init>")),
                    values: values,
                    state: state
                )
                return .null
            }
        }
        registerSortConstructor(
            "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;)V",
            hasDefaultMask: false
        )
        registerSortConstructor(
            "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            hasDefaultMask: true
        )
        bridge.register(class: sort, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Sort.getState")
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
                kind: .text,
                name: vmStringValue(try argument(args, 1, "Filter.Text.<init>")),
                state: state
            )
            return .null
        }
        bridge.register(class: textFilter, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.Text.getState")
        }

        bridge.register(
            class: triState,
            "<init>",
            prototype: "(Ljava/lang/String;IILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "Filter.TriState.<init>"),
                  case let .int(rawState) = try argument(args, 2, "Filter.TriState.<init>"),
                  case let .int(mask) = try argument(args, 3, "Filter.TriState.<init>") else {
                throw VMError.verify("Filter.TriState constructor arguments")
            }
            object.payload = FilterStateBox(
                kind: .triState,
                name: vmStringValue(try argument(args, 1, "Filter.TriState.<init>")),
                state: boxedInteger(mask & 0x2 == 0 ? rawState : 0)
            )
            return .null
        }
        bridge.register(class: triState, "getState", prototype: "()Ljava/lang/Object;") { _, args in
            try filterState(args, "Filter.TriState.getState")
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
            guard source.elements.count <= 512 else {
                throw VMError.verify("FilterList exceeds 512 filters")
            }
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
            guard array.elements.count <= 512 else {
                throw VMError.verify("FilterList exceeds 512 filters")
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

    private static func filterStringValues(_ array: ArrInstance) -> [String]? {
        guard array.elements.count <= 512 else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(array.elements.count)
        var utf8Bytes = 0
        for value in array.elements {
            guard case let .obj(object) = value,
                  let string = object.payload as? String,
                  string.utf8.count <= 4_096 else { return nil }
            utf8Bytes += string.utf8.count
            guard utf8Bytes <= 256 * 1_024 else { return nil }
            strings.append(string)
        }
        return strings
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
        ) { vm, args in
            let receiver = try argument(args, 0, "HttpSource.getHeaders")
            let emptyBuilder = RVal.obj(ObjInstance(
                dexType: "Lokhttp3/Headers$Builder;",
                payload: HeadersBuilderBox(),
                isHost: true
            ))
            let configuredBuilder: RVal
            if case let .obj(source) = receiver {
                do {
                    configuredBuilder = try vm.call(
                        classDescriptor: source.dexType,
                        method: "headersBuilder",
                        prototype: "()Lokhttp3/Headers$Builder;",
                        args: [receiver]
                    )
                } catch let error as VMError {
                    if case .unresolvedMethod = error {
                        configuredBuilder = emptyBuilder
                    } else {
                        throw error
                    }
                }
            } else {
                throw VMError.verify("HttpSource.getHeaders receiver")
            }
            guard case let .obj(builderObject) = configuredBuilder,
                  let builder = builderObject.payload as? HeadersBuilderBox else {
                throw VMError.verify("HttpSource.headersBuilder result")
            }
            return .obj(ObjInstance(
                dexType: "Lokhttp3/Headers;",
                payload: HeadersBox(headers: builder.headers),
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
        let httpUrlBuilder = "Lokhttp3/HttpUrl$Builder;"
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
        bridge.register(
            class: httpUrl,
            "newBuilder",
            prototype: "()Lokhttp3/HttpUrl$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.newBuilder"),
                  let url = object.payload as? HttpUrlBox else {
                throw VMError.verify("HttpUrl.newBuilder receiver")
            }
            return .obj(ObjInstance(
                dexType: httpUrlBuilder,
                payload: HttpUrlBuilderBox(baseURL: url.value),
                isHost: true
            ))
        }
        bridge.register(
            class: httpUrlBuilder,
            "addQueryParameter",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.Builder.addQueryParameter"),
                  let builder = object.payload as? HttpUrlBuilderBox else {
                throw VMError.verify("HttpUrl.Builder.addQueryParameter receiver")
            }
            let name = try requiredString(args, 1, "HttpUrl.Builder.addQueryParameter")
            let value = try optionalString(args, 2, "HttpUrl.Builder.addQueryParameter")
            let maximumURLBytes = 8_192
            guard name.utf8.count <= maximumURLBytes,
                  value?.utf8.count ?? 0 <= maximumURLBytes,
                  let encodedNameBytes = httpQueryComponentEncodedByteCount(
                      name,
                      maximum: maximumURLBytes
                  ) else {
                throw DEXThrowable(string("IllegalArgumentException: query parameter is too large"))
            }
            let encodedValueBytes: Int?
            if let value {
                guard let count = httpQueryComponentEncodedByteCount(
                    value,
                    maximum: maximumURLBytes
                ) else {
                    throw DEXThrowable(string("IllegalArgumentException: query parameter is too large"))
                }
                encodedValueBytes = count
            } else {
                encodedValueBytes = nil
            }
            let parameterBytes = 1 + encodedNameBytes
                + (encodedValueBytes.map { 1 + $0 } ?? 0)
            let addedBytes = builder.addedURLBytes.addingReportingOverflow(parameterBytes)
            guard !addedBytes.overflow,
                  builder.baseURL.utf8.count <= maximumURLBytes,
                  addedBytes.partialValue <= maximumURLBytes - builder.baseURL.utf8.count else {
                throw DEXThrowable(string("IllegalArgumentException: query parameter is too large"))
            }
            builder.addedURLBytes = addedBytes.partialValue
            builder.queryParameters.append((name, value))
            return .obj(object)
        }
        bridge.register(
            class: httpUrlBuilder,
            "build",
            prototype: "()Lokhttp3/HttpUrl;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "HttpUrl.Builder.build"),
                  let builder = object.payload as? HttpUrlBuilderBox,
                  var components = URLComponents(string: builder.baseURL) else {
                throw VMError.verify("HttpUrl.Builder.build receiver")
            }
            var parts: [String] = []
            if let existing = components.percentEncodedQuery, !existing.isEmpty {
                parts.append(existing)
            }
            parts.append(contentsOf: builder.queryParameters.map { parameter in
                let name = httpQueryComponentEncode(parameter.name)
                guard let value = parameter.value else { return name }
                return name + "=" + httpQueryComponentEncode(value)
            })
            components.percentEncodedQuery = parts.isEmpty ? nil : parts.joined(separator: "&")
            guard let value = components.string,
                  let parsed = parsedHTTPURL(value) else {
                throw DEXThrowable(string("IllegalArgumentException: invalid HTTP URL"))
            }
            return .obj(ObjInstance(dexType: httpUrl, payload: parsed, isHost: true))
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
        let schapter = "Leu/kanade/tachiyomi/source/model/SChapter;"
        let chapterCompanion = "Leu/kanade/tachiyomi/source/model/SChapter$Companion;"
        let mangaUpdate = "Leu/kanade/tachiyomi/source/model/SMangaUpdate;"
        let mangasPage = "Leu/kanade/tachiyomi/source/model/MangasPage;"
        let page = "Leu/kanade/tachiyomi/source/model/Page;"

        func mangaBox(_ args: [RVal], _ method: String, index: Int = 0) throws -> SMangaBox {
            guard case let .obj(object) = try argument(args, index, method),
                  let box = object.payload as? SMangaBox else {
                throw VMError.verify("\(method) manga argument")
            }
            return box
        }

        func chapterBox(
            _ args: [RVal],
            _ method: String,
            index: Int = 0
        ) throws -> SChapterBox {
            guard case let .obj(object) = try argument(args, index, method),
                  let box = object.payload as? SChapterBox else {
                throw VMError.verify("\(method) chapter argument")
            }
            return box
        }

        func pageBox(_ args: [RVal], _ method: String, index: Int = 0) throws -> PageBox {
            guard case let .obj(object) = try argument(args, index, method),
                  let box = object.payload as? PageBox else {
                throw VMError.verify("\(method) page argument")
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

        let chapterCompanionValue = RVal.obj(ObjInstance(
            dexType: chapterCompanion,
            isHost: true
        ))
        bridge.staticFields["\(schapter)->Companion"] = chapterCompanionValue
        bridge.register(
            class: chapterCompanion,
            "create",
            prototype: "()Leu/kanade/tachiyomi/source/model/SChapter;"
        ) { _, _ in
            .obj(ObjInstance(
                dexType: schapter,
                payload: SChapterBox(),
                isHost: true
            ))
        }
        for (suffix, keyPath) in [
            ("Url", \SChapterCompat.url),
            ("Name", \SChapterCompat.name),
        ] {
            bridge.register(
                class: schapter,
                "set\(suffix)",
                prototype: "(Ljava/lang/String;)V"
            ) { _, args in
                let box = try chapterBox(args, "SChapter.set\(suffix)")
                box.value[keyPath: keyPath] = try requiredString(
                    args, 1, "SChapter.set\(suffix)"
                )
                return .null
            }
            bridge.register(
                class: schapter,
                "get\(suffix)",
                prototype: "()Ljava/lang/String;"
            ) { _, args in
                string(try chapterBox(args, "SChapter.get\(suffix)").value[
                    keyPath: keyPath
                ])
            }
        }
        bridge.register(
            class: schapter,
            "setChapter_number",
            prototype: "(F)V"
        ) { _, args in
            let box = try chapterBox(args, "SChapter.setChapter_number")
            guard case let .float(value) = try argument(
                args, 1, "SChapter.setChapter_number"
            ) else { throw VMError.verify("SChapter.setChapter_number value") }
            box.value.chapterNumber = value
            return .null
        }
        bridge.register(
            class: schapter,
            "setDate_upload",
            prototype: "(J)V"
        ) { _, args in
            let box = try chapterBox(args, "SChapter.setDate_upload")
            guard case let .long(value) = try argument(
                args, 1, "SChapter.setDate_upload"
            ) else { throw VMError.verify("SChapter.setDate_upload value") }
            box.value.dateUpload = value
            return .null
        }
        bridge.register(
            class: schapter,
            "setMemo",
            prototype: "(Lkotlinx/serialization/json/JsonObject;)V"
        ) { _, args in
            let box = try chapterBox(args, "SChapter.setMemo")
            guard case let .obj(object) = try argument(args, 1, "SChapter.setMemo"),
                  let memo = object.payload as? JSONObjectBox else {
                throw VMError.verify("SChapter.setMemo value")
            }
            box.value.memo = memo.values
            return .null
        }
        bridge.register(
            class: schapter,
            "getMemo",
            prototype: "()Lkotlinx/serialization/json/JsonObject;"
        ) { _, args in
            let memo = try chapterBox(args, "SChapter.getMemo").value.memo
            return .obj(ObjInstance(
                dexType: "Lkotlinx/serialization/json/JsonObject;",
                payload: JSONObjectBox(values: memo),
                isHost: true
            ))
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

        bridge.objectFactories[page] = { _ in
            .obj(ObjInstance(dexType: page, isHost: true))
        }
        func initializePage(_ args: [RVal], defaultMaskIndex: Int?) throws -> RVal {
            let operation = "Page.<init>"
            guard case let .obj(object) = try argument(args, 0, operation),
                  case let .int(index) = try argument(args, 1, operation) else {
                throw VMError.verify("\(operation) arguments")
            }
            let mask: Int32
            if let defaultMaskIndex {
                guard case let .int(value) = try argument(args, defaultMaskIndex, operation) else {
                    throw VMError.verify("\(operation) default mask")
                }
                mask = value
            } else {
                mask = 0
            }
            let url = mask & 0x02 != 0
                ? ""
                : try requiredString(args, 2, operation)
            let imageURL = mask & 0x04 != 0
                ? nil
                : try optionalString(args, 3, operation)
            let uri = mask & 0x08 != 0
                ? RVal.null
                : try argument(args, 4, operation)
            let maximumBytes = bridge.htmlPolicy.maximumExtractedStringBytes
            guard url.utf8.count <= maximumBytes,
                  (imageURL?.utf8.count ?? 0) <= maximumBytes else {
                throw hostThrowable(
                    "Ljava/lang/IllegalArgumentException;",
                    "page URL is too long"
                )
            }
            object.payload = PageBox(
                value: PageCompat(
                    index: Int(index),
                    url: url,
                    imageURL: imageURL
                ),
                uri: uri
            )
            return .null
        }
        bridge.register(
            class: page,
            "<init>",
            prototype: "(ILjava/lang/String;Ljava/lang/String;Landroid/net/Uri;)V"
        ) { _, args in
            try initializePage(args, defaultMaskIndex: nil)
        }
        bridge.register(
            class: page,
            "<init>",
            prototype: "(ILjava/lang/String;Ljava/lang/String;Landroid/net/Uri;ILkotlin/jvm/internal/DefaultConstructorMarker;)V"
        ) { _, args in
            try initializePage(args, defaultMaskIndex: 5)
        }
        for name in ["getIndex", "component1"] {
            bridge.register(class: page, name, prototype: "()I") { _, args in
                .int(Int32(clamping: try pageBox(args, "Page.\(name)").value.index))
            }
        }
        for name in ["getUrl", "component2"] {
            bridge.register(class: page, name, prototype: "()Ljava/lang/String;") { _, args in
                string(try pageBox(args, "Page.\(name)").value.url)
            }
        }
        for name in ["getImageUrl", "component3"] {
            bridge.register(class: page, name, prototype: "()Ljava/lang/String;") { _, args in
                guard let imageURL = try pageBox(args, "Page.\(name)").value.imageURL else {
                    return .null
                }
                return string(imageURL)
            }
        }
        for name in ["getUri", "component4"] {
            bridge.register(class: page, name, prototype: "()Landroid/net/Uri;") { _, args in
                try pageBox(args, "Page.\(name)").uri
            }
        }

        bridge.objectFactories[mangaUpdate] = { _ in
            .obj(ObjInstance(dexType: mangaUpdate, isHost: true))
        }
        bridge.register(
            class: mangaUpdate,
            "<init>",
            prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;)V"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "SMangaUpdate.<init>") else {
                throw VMError.verify("SMangaUpdate constructor receiver")
            }
            let manga = try argument(args, 1, "SMangaUpdate.<init>")
            _ = try mangaBox(args, "SMangaUpdate.<init>", index: 1)
            let chapters = try listBox(args, "SMangaUpdate.<init>", index: 2).elements
            for chapter in chapters {
                _ = try chapterBox([chapter], "SMangaUpdate.<init> chapter")
            }
            object.payload = SMangaUpdateBox(manga: manga, chapters: chapters)
            return .null
        }
        bridge.register(
            class: mangaUpdate,
            "getManga",
            prototype: "()Leu/kanade/tachiyomi/source/model/SManga;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "SMangaUpdate.getManga"),
                  let box = object.payload as? SMangaUpdateBox else {
                throw VMError.verify("SMangaUpdate.getManga receiver")
            }
            return box.manga
        }
        bridge.register(
            class: mangaUpdate,
            "getChapters",
            prototype: "()Ljava/util/List;"
        ) { _, args in
            guard case let .obj(object) = try argument(args, 0, "SMangaUpdate.getChapters"),
                  let box = object.payload as? SMangaUpdateBox else {
                throw VMError.verify("SMangaUpdate.getChapters receiver")
            }
            return hostList(box.chapters, isMutable: false)
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

    /// Creates host-backed tachiyomix inputs for an interpreted source. These
    /// values remain confined to that source's serialized runtime owner.
    static func mangaValue(from value: SMangaCompat) -> RVal {
        .obj(ObjInstance(
            dexType: "Leu/kanade/tachiyomi/source/model/SManga;",
            payload: SMangaBox(value),
            isHost: true
        ))
    }

    static func chapterValue(from value: SChapterCompat) -> RVal {
        .obj(ObjInstance(
            dexType: "Leu/kanade/tachiyomi/source/model/SChapter;",
            payload: SChapterBox(value),
            isHost: true
        ))
    }

    static func emptyListValue() -> RVal {
        hostList([], isMutable: false)
    }

    private struct SourceFilterBudget {
        var filters = 0
        var utf8Bytes = 0
    }

    /// Converts the host-backed Mihon filter graph produced by the exact APK
    /// into immutable app-facing values. Unsupported subclasses or excessive
    /// nesting fail closed instead of being silently omitted.
    static func sourceFilters(from value: RVal) -> [SourceFilter]? {
        guard case let .obj(object) = value,
              let list = object.payload as? HostListBox else { return nil }
        var budget = SourceFilterBudget()
        return sourceFilters(from: list.elements, depth: 0, budget: &budget)
    }

    /// Applies app-edited state to the original DEX filter instances so
    /// extension type checks (for example `firstInstanceOrNull<SortFilter>`) and
    /// subclass getters retain their real runtime identity.
    static func applySourceFilters(_ filters: [SourceFilter], to value: RVal) -> Bool {
        guard case let .obj(object) = value,
              let list = object.payload as? HostListBox,
              sourceFilterStructureMatches(filters, values: list.elements, depth: 0) else {
            return false
        }
        applyValidatedSourceFilters(filters, values: list.elements)
        return true
    }

    private static func sourceFilters(
        from values: [RVal],
        depth: Int,
        budget: inout SourceFilterBudget
    ) -> [SourceFilter]? {
        guard depth <= 16, values.count <= 512 else { return nil }
        var result: [SourceFilter] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard case let .obj(object) = value,
                  let filter = object.payload as? FilterStateBox,
                  filter.name.utf8.count <= 4_096 else { return nil }
            budget.filters += 1
            budget.utf8Bytes += filter.name.utf8.count
            guard budget.filters <= 512, budget.utf8Bytes <= 1_048_576 else { return nil }

            switch filter.kind {
            case .header:
                result.append(.header(filter.name))
            case .separator:
                result.append(.separator(filter.name))
            case .select:
                guard let state = filterInteger(filter.state),
                      state >= 0,
                      Int(state) < filter.values.count,
                      accountFilterValues(filter.values, budget: &budget) else { return nil }
                result.append(.select(
                    name: filter.name,
                    values: filter.values,
                    state: Int(state)
                ))
            case .text:
                guard let state = filterString(filter.state), state.utf8.count <= 4_096 else {
                    return nil
                }
                budget.utf8Bytes += state.utf8.count
                guard budget.utf8Bytes <= 1_048_576 else { return nil }
                result.append(.text(name: filter.name, state: state))
            case .checkBox:
                guard let state = filterBoolean(filter.state) else { return nil }
                result.append(.checkBox(name: filter.name, state: state))
            case .triState:
                guard let rawState = filterInteger(filter.state),
                      let state = SourceFilter.TriState(rawValue: Int(rawState)) else { return nil }
                result.append(.triState(name: filter.name, state: state))
            case .group:
                guard case let .obj(groupObject) = filter.state,
                      let list = groupObject.payload as? HostListBox,
                      let children = sourceFilters(
                          from: list.elements,
                          depth: depth + 1,
                          budget: &budget
                      ) else { return nil }
                result.append(.group(name: filter.name, filters: children))
            case .sort:
                guard accountFilterValues(filter.values, budget: &budget) else { return nil }
                let selection: SourceFilter.SortSelection?
                if filter.state.isNull {
                    selection = nil
                } else {
                    guard case let .obj(selectionObject) = filter.state,
                          let rawSelection = selectionObject.payload as? FilterSortSelectionBox,
                          rawSelection.index >= 0,
                          Int(rawSelection.index) < filter.values.count else { return nil }
                    selection = .init(
                        index: Int(rawSelection.index),
                        ascending: rawSelection.ascending
                    )
                }
                result.append(.sort(
                    name: filter.name,
                    values: filter.values,
                    state: selection
                ))
            }
        }
        return result
    }

    private static func accountFilterValues(
        _ values: [String],
        budget: inout SourceFilterBudget
    ) -> Bool {
        guard values.count <= 512, values.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            return false
        }
        budget.utf8Bytes += values.reduce(0) { $0 + $1.utf8.count }
        return budget.utf8Bytes <= 1_048_576
    }

    private static func sourceFilterStructureMatches(
        _ filters: [SourceFilter],
        values: [RVal],
        depth: Int
    ) -> Bool {
        guard depth <= 16, filters.count == values.count, filters.count <= 512 else {
            return false
        }
        for (source, value) in zip(filters, values) {
            guard case let .obj(object) = value,
                  let target = object.payload as? FilterStateBox else { return false }
            switch (source, target.kind) {
            case let (.header(name), .header), let (.separator(name), .separator):
                guard name == target.name else { return false }
            case let (.select(name, values, state), .select):
                guard name == target.name,
                      values == target.values,
                      state >= 0,
                      state < values.count else { return false }
            case let (.text(name, state), .text):
                guard name == target.name, state.utf8.count <= 4_096 else { return false }
            case let (.checkBox(name, _), .checkBox):
                guard name == target.name else { return false }
            case let (.triState(name, _), .triState):
                guard name == target.name else { return false }
            case let (.group(name, children), .group):
                guard name == target.name,
                      case let .obj(groupObject) = target.state,
                      let list = groupObject.payload as? HostListBox,
                      sourceFilterStructureMatches(
                          children,
                          values: list.elements,
                          depth: depth + 1
                      ) else { return false }
            case let (.sort(name, values, state), .sort):
                guard name == target.name, values == target.values else { return false }
                if let state, (state.index < 0 || state.index >= values.count) { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func applyValidatedSourceFilters(_ filters: [SourceFilter], values: [RVal]) {
        for (source, value) in zip(filters, values) {
            guard case let .obj(object) = value,
                  let target = object.payload as? FilterStateBox else { continue }
            switch source {
            case let .select(_, _, state):
                target.state = boxedInteger(Int32(state))
            case let .text(_, state):
                target.state = string(state)
            case let .checkBox(_, state):
                target.state = boxedBoolean(state)
            case let .triState(_, state):
                target.state = boxedInteger(Int32(state.rawValue))
            case let .group(_, children):
                if case let .obj(groupObject) = target.state,
                   let list = groupObject.payload as? HostListBox {
                    applyValidatedSourceFilters(children, values: list.elements)
                }
            case let .sort(_, _, state):
                if let state {
                    target.state = .obj(ObjInstance(
                        dexType: "Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;",
                        payload: FilterSortSelectionBox(
                            index: Int32(state.index),
                            ascending: state.ascending
                        ),
                        isHost: true
                    ))
                } else {
                    target.state = .null
                }
            case .header, .separator:
                break
            }
        }
    }

    private static func filterInteger(_ value: RVal) -> Int32? {
        guard case let .obj(object) = value else { return nil }
        return object.payload as? Int32
    }

    private static func filterBoolean(_ value: RVal) -> Bool? {
        guard case let .obj(object) = value else { return nil }
        return object.payload as? Bool
    }

    private static func filterString(_ value: RVal) -> String? {
        guard case let .obj(object) = value else { return nil }
        return object.payload as? String
    }

    /// Converts an interpreted tachiyomix `SManga` host value into the public
    /// app-facing compatibility model.
    public static func mangaCompat(from value: RVal) -> SMangaCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? SMangaBox else { return nil }
        return box.value
    }

    public static func chapterCompat(from value: RVal) -> SChapterCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? SChapterBox else { return nil }
        return box.value
    }

    public static func pageCompat(from value: RVal) -> PageCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? PageBox else { return nil }
        return box.value
    }

    public static func pagesCompat(from value: RVal) -> [PageCompat]? {
        guard case let .obj(object) = value,
              let list = object.payload as? HostListBox else { return nil }
        var pages: [PageCompat] = []
        pages.reserveCapacity(list.elements.count)
        for value in list.elements {
            guard let page = pageCompat(from: value) else { return nil }
            pages.append(page)
        }
        return pages
    }

    public static func mangaUpdateCompat(from value: RVal) -> SMangaUpdateCompat? {
        guard case let .obj(object) = value,
              let box = object.payload as? SMangaUpdateBox,
              let manga = mangaCompat(from: box.manga) else { return nil }
        var chapters: [SChapterCompat] = []
        chapters.reserveCapacity(box.chapters.count)
        for chapter in box.chapters {
            guard let converted = chapterCompat(from: chapter) else { return nil }
            chapters.append(converted)
        }
        return SMangaUpdateCompat(manga: manga, chapters: chapters)
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

    /// Conservative RFC 3986 query-component encoding. Encoding every byte
    /// outside the unreserved set preserves OkHttp's decoded parameter
    /// semantics while preventing separators and `+` from changing meaning.
    private static func httpQueryComponentEncodedByteCount(
        _ value: String,
        maximum: Int
    ) -> Int? {
        var count = 0
        for byte in value.utf8 {
            let increment = isHTTPQueryUnreserved(byte) ? 1 : 3
            guard count <= maximum - increment else { return nil }
            count += increment
        }
        return count
    }

    private static func isHTTPQueryUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func httpQueryComponentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            if isHTTPQueryUnreserved(byte) {
                result.append(byte)
            } else {
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
