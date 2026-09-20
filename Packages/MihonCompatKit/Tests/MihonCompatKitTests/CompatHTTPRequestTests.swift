import XCTest
@testable import MihonCompatKit

final class CompatHTTPRequestTests: XCTestCase {
    private func makeVM(
        htmlPolicy: CompatHTMLPolicy = .init()
    ) throws -> (DexInterpreter, HostBridge) {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "noop",
            registers: 0,
            ins: 0,
            outs: 0,
            insns: [0x000e],
            isStatic: true
        ))
        let bridge = HostBridge.minimal(htmlPolicy: htmlPolicy)
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(_ bridge: HostBridge, _ vm: DexInterpreter,
                        class descriptor: String, _ name: String,
                        prototype: String, isStatic: Bool = false,
                        args: [RVal]) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(
            class: descriptor,
            name,
            prototype: prototype,
            isStatic: isStatic
        ))
        return try method(vm, args)
    }

    func testKotlinBoxedIntComparisonMatchesNaturalOrder() throws {
        let (vm, bridge) = try makeVM()
        let lower = try invoke(
            bridge, vm,
            class: "Lkotlin/coroutines/jvm/internal/Boxing;", "boxInt",
            prototype: "(I)Ljava/lang/Integer;",
            isStatic: true,
            args: [.int(41)]
        )
        let higher = try invoke(
            bridge, vm,
            class: "Lkotlin/coroutines/jvm/internal/Boxing;", "boxInt",
            prototype: "(I)Ljava/lang/Integer;",
            isStatic: true,
            args: [.int(42)]
        )
        let comparison = try invoke(
            bridge, vm,
            class: "Ljava/lang/Integer;", "compareTo",
            prototype: "(Ljava/lang/Object;)I",
            args: [lower, higher]
        )
        guard case let .int(value) = comparison else {
            return XCTFail("expected Integer.compareTo result")
        }
        XCTAssertEqual(value, -1)
    }

    func testKotlinStringComparisonUsesJavaUTF16Ordering() throws {
        let (vm, bridge) = try makeVM()
        let comparison = try invoke(
            bridge, vm,
            class: "Lkotlin/comparisons/ComparisonsKt;", "compareValues",
            prototype: "(Ljava/lang/Comparable;Ljava/lang/Comparable;)I",
            isStatic: true,
            args: [HostBridge.string("😀"), HostBridge.string("\u{E000}")]
        )
        guard case let .int(value) = comparison else {
            return XCTFail("expected ComparisonsKt.compareValues result")
        }
        XCTAssertLessThan(value, 0)
    }

    func testKotlinTakeAndFilterNotNullPreserveOrderAndRejectNegativeCounts() throws {
        let (vm, bridge) = try makeVM()
        let list = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [.arr(ArrInstance(
                elemDescriptor: "Ljava/lang/Object;",
                elements: [
                    HostBridge.string("one"),
                    .null,
                    HostBridge.string("two"),
                    HostBridge.string("three"),
                ]
            ))]
        )
        let filtered = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "filterNotNull",
            prototype: "(Ljava/lang/Iterable;)Ljava/util/List;",
            isStatic: true,
            args: [list]
        )
        let taken = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "take",
            prototype: "(Ljava/lang/Iterable;I)Ljava/util/List;",
            isStatic: true,
            args: [filtered, .int(2)]
        )
        let size = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "size",
            prototype: "()I",
            args: [taken]
        )
        let first = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [taken, .int(0)]
        )
        let second = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [taken, .int(1)]
        )
        guard case let .int(rawSize) = size,
              case let .obj(firstObject) = first,
              case let .obj(secondObject) = second else {
            return XCTFail("expected bounded list values")
        }
        XCTAssertEqual(rawSize, 2)
        XCTAssertEqual(firstObject.payload as? String, "one")
        XCTAssertEqual(secondObject.payload as? String, "two")

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "take",
            prototype: "(Ljava/lang/Iterable;I)Ljava/util/List;",
            isStatic: true,
            args: [filtered, .int(-1)]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected a DEX IllegalArgumentException")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/IllegalArgumentException;")
        }
    }

    func testKotlinSetHelpersPreserveUniquenessAndMembership() throws {
        let (vm, bridge) = try makeVM()
        let empty = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/SetsKt;", "emptySet",
            prototype: "()Ljava/util/Set;",
            isStatic: true,
            args: []
        )
        let first = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/SetsKt;", "plus",
            prototype: "(Ljava/util/Set;Ljava/lang/Object;)Ljava/util/Set;",
            isStatic: true,
            args: [empty, HostBridge.string("alpha")]
        )
        let duplicate = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/SetsKt;", "plus",
            prototype: "(Ljava/util/Set;Ljava/lang/Object;)Ljava/util/Set;",
            isStatic: true,
            args: [first, HostBridge.string("alpha")]
        )
        let directContains = try invoke(
            bridge, vm,
            class: "Ljava/util/Set;", "contains",
            prototype: "(Ljava/lang/Object;)Z",
            args: [duplicate, HostBridge.string("alpha")]
        )
        let iterableContains = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "contains",
            prototype: "(Ljava/lang/Iterable;Ljava/lang/Object;)Z",
            isStatic: true,
            args: [duplicate, HostBridge.string("missing")]
        )
        let iterator = try invoke(
            bridge, vm,
            class: "Ljava/lang/Iterable;", "iterator",
            prototype: "()Ljava/util/Iterator;",
            args: [duplicate]
        )
        let firstHasNext = try invoke(
            bridge, vm,
            class: "Ljava/util/Iterator;", "hasNext",
            prototype: "()Z",
            args: [iterator]
        )
        _ = try invoke(
            bridge, vm,
            class: "Ljava/util/Iterator;", "next",
            prototype: "()Ljava/lang/Object;",
            args: [iterator]
        )
        let secondHasNext = try invoke(
            bridge, vm,
            class: "Ljava/util/Iterator;", "hasNext",
            prototype: "()Z",
            args: [iterator]
        )

        guard case let .int(rawDirectContains) = directContains,
              case let .int(rawIterableContains) = iterableContains,
              case let .int(rawFirstHasNext) = firstHasNext,
              case let .int(rawSecondHasNext) = secondHasNext else {
            return XCTFail("expected Kotlin boolean results")
        }
        XCTAssertEqual(rawDirectContains, 1)
        XCTAssertEqual(rawIterableContains, 0)
        XCTAssertEqual(rawFirstHasNext, 1)
        XCTAssertEqual(rawSecondHasNext, 0)

        let setOf = try XCTUnwrap(bridge.resolve(
            class: "Lkotlin/collections/SetsKt;", "setOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/Set;",
            isStatic: true
        ))
        let input = ArrInstance(elemDescriptor: "Ljava/lang/Object;", elements: [
            HostBridge.string("beta"), .null, HostBridge.string("alpha"),
            HostBridge.string("beta"), .null,
        ])
        let ordered = try setOf(vm, [.arr(input)])
        input.elements.removeAll()
        let orderedIterator = try invoke(
            bridge, vm, class: "Ljava/lang/Iterable;", "iterator",
            prototype: "()Ljava/util/Iterator;", args: [ordered]
        )
        for expected in ["beta", "null", "alpha"] {
            let value = try invoke(
                bridge, vm, class: "Ljava/util/Iterator;", "next",
                prototype: "()Ljava/lang/Object;", args: [orderedIterator]
            )
            XCTAssertEqual(vmStringValue(value), expected)
        }
        guard case let .int(hasMore) = try invoke(
            bridge, vm, class: "Ljava/util/Iterator;", "hasNext",
            prototype: "()Z", args: [orderedIterator]
        ) else { return XCTFail("expected the set iterator's end state") }
        XCTAssertEqual(hasMore, 0)
        XCTAssertThrowsError(try invoke(
            bridge, vm, class: "Ljava/util/Collection;", "add",
            prototype: "(Ljava/lang/Object;)Z", args: [ordered, HostBridge.string("later")]
        ))
        XCTAssertThrowsError(try setOf(vm, [.arr(ArrInstance(
            elemDescriptor: "I", elements: [.int(1)]
        ))]))
        XCTAssertThrowsError(try setOf(vm, [.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/Object;", elements: Array(repeating: .null, count: 100_001)
        ))]))
    }

    func testKotlinStatusAndChapterNumberHelpersMatchPizzaReader() throws {
        let (vm, bridge) = try makeVM()
        let prefix = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "take",
            prototype: "(Ljava/lang/String;I)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("In corso"), .int(7)]
        )
        let integerText = try invoke(
            bridge, vm,
            class: "Ljava/lang/String;", "valueOf",
            prototype: "(I)Ljava/lang/String;",
            isStatic: true,
            args: [.int(5)]
        )
        let decimal = try invoke(
            bridge, vm,
            class: "Ljava/lang/Float;", "parseFloat",
            prototype: "(Ljava/lang/String;)F",
            isStatic: true,
            args: [HostBridge.string("0.5")]
        )
        guard case let .obj(prefixObject) = prefix,
              case let .obj(integerObject) = integerText,
              case let .float(value) = decimal else {
            return XCTFail("expected PizzaReader helper values")
        }
        XCTAssertEqual(prefixObject.payload as? String, "In cors")
        XCTAssertEqual(integerObject.payload as? String, "5")
        XCTAssertEqual(value, 0.5)
    }

    func testJavaCharacterIsDigitUsesUnicodeDecimalDigitSemantics() throws {
        let (vm, bridge) = try makeVM()
        func isDigit(_ codeUnit: UInt16) throws -> Int32 {
            let result = try invoke(
                bridge, vm,
                class: "Ljava/lang/Character;", "isDigit",
                prototype: "(C)Z",
                isStatic: true,
                args: [.int(Int32(codeUnit))]
            )
            guard case let .int(value) = result else {
                throw VMError.verify("expected Character.isDigit boolean")
            }
            return value
        }

        XCTAssertEqual(try isDigit(0x0037), 1)
        XCTAssertEqual(try isDigit(0x0663), 1)
        XCTAssertEqual(try isDigit(0x0041), 0)
        XCTAssertEqual(try isDigit(0xd800), 0)
    }

    func testLocaleCasingAndCollationPreserveLanguageSpecificBehavior() throws {
        let (vm, bridge) = try makeVM()
        let french = try XCTUnwrap(bridge.staticFields["Ljava/util/Locale;->FRENCH"])
        let result = try invoke(
            bridge, vm,
            class: "Ljava/lang/String;", "toLowerCase",
            prototype: "(Ljava/util/Locale;)Ljava/lang/String;",
            args: [HostBridge.string("ÉCOLE ET SCÉNARIO"), french]
        )
        XCTAssertEqual(vmStringValue(result), "école et scénario")
        func locale(_ tag: String) throws -> RVal {
            try invoke(bridge, vm, class: "Ljava/util/Locale;", "forLanguageTag",
                       prototype: "(Ljava/lang/String;)Ljava/util/Locale;", isStatic: true,
                       args: [HostBridge.string(tag)])
        }
        for tag in ["tr", "TR-latn-tr", "tr-TR-!-ignored"] {
            let turkish = try locale(tag)
            let lower = try invoke(bridge, vm, class: "Ljava/lang/String;", "toLowerCase",
                                   prototype: "(Ljava/util/Locale;)Ljava/lang/String;",
                                   args: [HostBridge.string("Iİ"), turkish])
            let upper = try invoke(bridge, vm, class: "Ljava/lang/String;", "toUpperCase",
                                   prototype: "(Ljava/util/Locale;)Ljava/lang/String;",
                                   args: [HostBridge.string("ıi"), turkish])
            XCTAssertEqual(vmStringValue(lower), "ıi")
            XCTAssertEqual(vmStringValue(upper), "Iİ")
        }
        let spanish = try invoke(bridge, vm, class: "Ljava/text/Collator;", "getInstance",
                                 prototype: "(Ljava/util/Locale;)Ljava/text/Collator;", isStatic: true,
                                 args: [locale("es-ES")])
        let list = try invoke(bridge, vm, class: "Lkotlin/collections/CollectionsKt;", "listOf",
                              prototype: "([Ljava/lang/Object;)Ljava/util/List;", isStatic: true,
                              args: [.arr(ArrInstance(elemDescriptor: "Ljava/lang/Object;", elements:
                                ["zorro", "ñandú", "árbol", "nube"].map(HostBridge.string)))])
        let sorted = try invoke(bridge, vm, class: "Lkotlin/collections/CollectionsKt;", "sortedWith",
                                prototype: "(Ljava/lang/Iterable;Ljava/util/Comparator;)Ljava/util/List;",
                                isStatic: true, args: [list, spanish])
        for (index, expected) in ["árbol", "nube", "ñandú", "zorro"].enumerated() {
            XCTAssertEqual(vmStringValue(try invoke(bridge, vm, class: "Ljava/util/List;", "get",
                                                   prototype: "(I)Ljava/lang/Object;",
                                                   args: [sorted, .int(Int32(index))])), expected)
        }
        let equivalent = try invoke(bridge, vm, class: "Ljava/text/Collator;", "compare",
                                    prototype: "(Ljava/lang/String;Ljava/lang/String;)I",
                                    args: [spanish, HostBridge.string("é"), HostBridge.string("e\u{301}")])
        guard case .int(0) = equivalent else { return XCTFail("canonical equivalents must collate equally") }
        for unsupported in ["es-u-co-trad", "x-private", "i-klingon", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try locale(unsupported))
        }
        XCTAssertThrowsError(try invoke(bridge, vm, class: "Ljava/text/Collator;", "compare",
                                        prototype: "(Ljava/lang/Object;Ljava/lang/Object;)I",
                                        args: [spanish, .null, HostBridge.string("text")]))
    }

    func testKotlinStringBuilderVarargAppendMatchesOriginesDescription() throws {
        let (vm, bridge) = try makeVM()
        let builder = RVal.obj(ObjInstance(
            dexType: "Ljava/lang/StringBuilder;",
            payload: "",
            isHost: true
        ))
        let values = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [
                HostBridge.string("Nom alternatif: "),
                HostBridge.string("Alternative Hero"),
            ]
        ))
        let returned = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "append",
            prototype: "(Ljava/lang/StringBuilder;[Ljava/lang/String;)Ljava/lang/StringBuilder;",
            isStatic: true,
            args: [builder, values]
        )
        XCTAssertEqual(vmStringValue(returned), "Nom alternatif: Alternative Hero")

        let rendered = try invoke(
            bridge, vm,
            class: "Ljava/lang/StringBuilder;", "toString",
            prototype: "()Ljava/lang/String;",
            args: [builder]
        )
        XCTAssertEqual(vmStringValue(rendered), "Nom alternatif: Alternative Hero")
    }

    func testKotlinMapCapacityAndLinkedHashMapLookupStayBounded() throws {
        let (vm, bridge) = try makeVM()
        func mapCapacity(_ size: Int32) throws -> Int32 {
            let result = try invoke(
                bridge, vm,
                class: "Lkotlin/collections/MapsKt;", "mapCapacity",
                prototype: "(I)I",
                isStatic: true,
                args: [.int(size)]
            )
            guard case let .int(value) = result else {
                throw VMError.verify("expected MapsKt.mapCapacity integer")
            }
            return value
        }

        XCTAssertEqual(try mapCapacity(-1), -1)
        XCTAssertEqual(try mapCapacity(0), 1)
        XCTAssertEqual(try mapCapacity(2), 3)
        XCTAssertEqual(try mapCapacity(3), 5)
        XCTAssertEqual(try mapCapacity(12), 17)
        XCTAssertEqual(try mapCapacity(1 << 30), Int32.max)

        let map = RVal.obj(ObjInstance(
            dexType: "Ljava/util/LinkedHashMap;",
            isHost: true
        ))
        _ = try invoke(
            bridge, vm,
            class: "Ljava/util/LinkedHashMap;", "<init>",
            prototype: "(I)V",
            args: [map, .int(4)]
        )
        _ = try invoke(
            bridge, vm,
            class: "Ljava/util/Map;", "put",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            args: [map, HostBridge.string("auteur"), HostBridge.string("Measured Writer")]
        )
        let found = try invoke(
            bridge, vm,
            class: "Ljava/util/LinkedHashMap;", "get",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
            args: [map, HostBridge.string("auteur")]
        )
        let missing = try invoke(
            bridge, vm,
            class: "Ljava/util/LinkedHashMap;", "get",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
            args: [map, HostBridge.string("missing")]
        )
        XCTAssertEqual(vmStringValue(found), "Measured Writer")
        XCTAssertTrue(missing.isNull)

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/util/LinkedHashMap;", "<init>",
            prototype: "(I)V",
            args: [map, .int(1_000_001)]
        ))
    }

    func testKotlinCollectionPlusPreservesOrderAndDuplicates() throws {
        let (vm, bridge) = try makeVM()
        let source = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [.arr(ArrInstance(
                elemDescriptor: "Ljava/lang/Object;",
                elements: [HostBridge.string("Action"), HostBridge.string("Adventure")]
            ))]
        )
        let result = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "plus",
            prototype: "(Ljava/util/Collection;Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [source, HostBridge.string("Action")]
        )
        for (index, expected) in ["Action", "Adventure", "Action"].enumerated() {
            let value = try invoke(
                bridge, vm,
                class: "Ljava/util/List;", "get",
                prototype: "(I)Ljava/lang/Object;",
                args: [result, .int(Int32(index))]
            )
            XCTAssertEqual(vmStringValue(value), expected)
        }
    }

    func testKotlinTakeNormalizesSplitUTF16SurrogatesAtTheVMBoundary() throws {
        let (vm, bridge) = try makeVM()
        let split = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "take",
            prototype: "(Ljava/lang/String;I)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("😀"), .int(1)]
        )
        let whole = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "take",
            prototype: "(Ljava/lang/String;I)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("😀"), .int(2)]
        )
        XCTAssertEqual(vmStringValue(split), "\u{FFFD}")
        XCTAssertEqual(vmStringValue(whole), "😀")
    }

    func testNullableIntSerializerRoundTripsNullAndBoundedIntegers() throws {
        let (vm, bridge) = try makeVM()
        let intSerializer = try XCTUnwrap(
            bridge.staticFields["Lkotlinx/serialization/internal/IntSerializer;->INSTANCE"]
        )
        let nullableSerializer = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/builtins/BuiltinSerializersKt;", "getNullable",
            prototype: "(Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;",
            isStatic: true,
            args: [intSerializer]
        )
        let json = RVal.obj(ObjInstance(
            dexType: "Lkotlinx/serialization/json/Json;",
            isHost: true
        ))

        let encodedNull = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "encodeToString",
            prototype: "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;",
            args: [json, nullableSerializer, .null]
        )
        let encodedMaximum = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "encodeToString",
            prototype: "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;",
            args: [json, nullableSerializer, .int(Int32.max)]
        )
        XCTAssertEqual(vmStringValue(encodedNull), "null")
        XCTAssertEqual(vmStringValue(encodedMaximum), String(Int32.max))

        let decodedNull = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;",
            args: [json, nullableSerializer, HostBridge.string("null")]
        )
        let decodedMinimum = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;",
            args: [json, nullableSerializer, HostBridge.string(String(Int32.min))]
        )
        XCTAssertTrue(decodedNull.isNull)
        guard case let .obj(boxedMinimum) = decodedMinimum else {
            return XCTFail("expected a boxed nullable Int")
        }
        XCTAssertEqual(boxedMinimum.payload as? Int32, Int32.min)

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;",
            args: [json, nullableSerializer, HostBridge.string("2147483648")]
        )) { error in
            XCTAssertTrue(error is DEXThrowable)
        }

        for literal in ["1.0", "1e0", "-1.0"] {
            XCTAssertThrowsError(try invoke(
                bridge, vm,
                class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
                prototype: "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;",
                args: [json, nullableSerializer, HostBridge.string(literal)]
            )) { error in
                XCTAssertTrue(error is DEXThrowable, "expected (literal) to be rejected")
            }
        }
    }

    func testGeneratedSerializerBoundsDescriptorsAndPropagatesJSONModes() throws {
        let generatedSerializer = "LTestGeneratedSerializer;"
        let generatedDescriptor = "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;"
        let serialDescriptor = "Lkotlinx/serialization/descriptors/SerialDescriptor;"
        let serializer = "Lkotlinx/serialization/KSerializer;"
        let decoder = "Lkotlinx/serialization/encoding/Decoder;"
        let compositeDecoder = "Lkotlinx/serialization/encoding/CompositeDecoder;"
        let stringSerializer = "Lkotlinx/serialization/internal/StringSerializer;"
        let intSerializer = "Lkotlinx/serialization/internal/IntSerializer;"

        var builder = DexBuilder()
        let descriptorInit = builder.method(
            classDescriptor: generatedDescriptor,
            name: "<init>",
            shorty: "VLLI",
            ret: "V",
            parameters: [
                "Ljava/lang/String;",
                "Lkotlinx/serialization/internal/GeneratedSerializer;",
                "I",
            ]
        )
        let addElement = builder.method(
            classDescriptor: generatedDescriptor,
            name: "addElement",
            shorty: "VLZ",
            ret: "V",
            parameters: ["Ljava/lang/String;", "Z"]
        )
        let nullableFactory = builder.method(
            classDescriptor: "Lkotlinx/serialization/builtins/BuiltinSerializersKt;",
            name: "getNullable",
            shorty: "LL",
            ret: serializer,
            parameters: [serializer]
        )
        let beginStructure = builder.method(
            classDescriptor: decoder,
            name: "beginStructure",
            shorty: "LL",
            ret: compositeDecoder,
            parameters: [serialDescriptor]
        )
        let decodeElementIndex = builder.method(
            classDescriptor: compositeDecoder,
            name: "decodeElementIndex",
            shorty: "IL",
            ret: "I",
            parameters: [serialDescriptor]
        )
        let decodeStringElement = builder.method(
            classDescriptor: compositeDecoder,
            name: "decodeStringElement",
            shorty: "LLI",
            ret: "Ljava/lang/String;",
            parameters: [serialDescriptor, "I"]
        )
        let decodeNullableElement = builder.method(
            classDescriptor: compositeDecoder,
            name: "decodeNullableSerializableElement",
            shorty: "LLILL",
            ret: "Ljava/lang/Object;",
            parameters: [
                serialDescriptor, "I",
                "Lkotlinx/serialization/DeserializationStrategy;",
                "Ljava/lang/Object;",
            ]
        )
        let endStructure = builder.method(
            classDescriptor: compositeDecoder,
            name: "endStructure",
            shorty: "VL",
            ret: "V",
            parameters: [serialDescriptor]
        )
        let stringField = builder.field(
            classDescriptor: stringSerializer,
            name: "INSTANCE",
            typeDescriptor: serializer
        )
        let intField = builder.field(
            classDescriptor: intSerializer,
            name: "INSTANCE",
            typeDescriptor: serializer
        )
        let nullField = builder.field(
            classDescriptor: "Ljava/lang/Object;",
            name: "NULL",
            typeDescriptor: "Ljava/lang/Object;"
        )
        let generatedDescriptorType = builder.type(generatedDescriptor)
        let serializerArrayType = builder.type("[\(serializer)")
        let modelName = builder.string("Test.Model")
        let titleName = builder.string("title")
        let rankName = builder.string("rank")

        builder.setClass(
            generatedSerializer,
            interfaces: [
                serializer,
                "Lkotlinx/serialization/internal/GeneratedSerializer;",
            ]
        )
        let getDescriptor = builder.addMethod(.init(
            name: "getDescriptor",
            registers: 8,
            ins: 1,
            outs: 4,
            insns: Insn.newInstance(0, generatedDescriptorType)
                + Insn.constString(1, modelName)
                + Insn.const4Units(2, 2)
                + Insn.invokeDirect(descriptorInit, [0, 1, 7, 2])
                + Insn.constString(3, titleName)
                + Insn.const4Units(4, 0)
                + Insn.invokeVirtual(addElement, [0, 3, 4])
                + Insn.constString(5, rankName)
                + Insn.const4Units(6, 1)
                + Insn.invokeVirtual(addElement, [0, 5, 6])
                + Insn.returnObjectReg(0),
            isStatic: false,
            returnType: serialDescriptor
        ))
        let childSerializers = builder.addMethod(.init(
            name: "childSerializers",
            registers: 4,
            ins: 1,
            outs: 1,
            insns: Insn.sget(0, stringField, object: true)
                + Insn.sget(1, intField, object: true)
                + Insn.invokeStatic(nullableFactory, [1])
                + Insn.moveResultObject(1)
                + Insn.const4Units(2, 2)
                + Insn.newArray(3, 2, serializerArrayType)
                + Insn.const4Units(2, 0)
                + Insn.aput(0, 3, 2, object: true)
                + Insn.const4Units(2, 1)
                + Insn.aput(1, 3, 2, object: true)
                + Insn.returnObjectReg(3),
            isStatic: false,
            returnType: "[\(serializer)"
        ))
        builder.addMethod(.init(
            name: "deserialize",
            registers: 10,
            ins: 2,
            outs: 5,
            insns: Insn.invokeVirtual(getDescriptor, [8])
                + Insn.moveResultObject(0)
                + Insn.invokeInterface(beginStructure, [9, 0])
                + Insn.moveResultObject(1)
                + Insn.invokeInterface(decodeElementIndex, [1, 0])
                + Insn.moveResult(2)
                + Insn.invokeInterface(decodeStringElement, [1, 0, 2])
                + Insn.moveResultObject(3)
                + Insn.invokeVirtual(childSerializers, [8])
                + Insn.moveResultObject(4)
                + Insn.const4Units(5, 1)
                + Insn.aget(6, 4, 5, object: true)
                + Insn.const4Units(5, 1)
                + Insn.sget(7, nullField, object: true)
                + Insn.invokeInterface(decodeNullableElement, [1, 0, 5, 6, 7])
                + Insn.moveResultObject(3)
                + Insn.invokeInterface(endStructure, [1, 0])
                + Insn.returnObjectReg(3),
            isStatic: false,
            returnType: "Ljava/lang/Object;",
            parameters: [decoder]
        ))

        let bridge = HostBridge.minimal()
        bridge.staticFields["Ljava/lang/Object;->NULL"] = .null
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let serializerValue = try vm.instantiate(classDescriptor: generatedSerializer)

        func assertDEXFailure(_ body: () throws -> Void) {
            XCTAssertThrowsError(try body()) { error in
                XCTAssertTrue(error is DEXThrowable, "expected DEX throwable, got \(error)")
            }
        }

        let incomplete = RVal.obj(ObjInstance(dexType: generatedDescriptor, isHost: true))
        _ = try invoke(
            bridge, vm,
            class: generatedDescriptor, "<init>",
            prototype: "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;I)V",
            args: [
                incomplete,
                HostBridge.string("Broken.Model"),
                serializerValue,
                .int(2),
            ]
        )
        _ = try invoke(
            bridge, vm,
            class: generatedDescriptor, "addElement",
            prototype: "(Ljava/lang/String;Z)V",
            args: [incomplete, HostBridge.string("title"), .int(0)]
        )
        assertDEXFailure {
            _ = try invoke(
                bridge, vm,
                class: serialDescriptor, "getElementsCount",
                prototype: "()I",
                args: [incomplete]
            )
        }
        assertDEXFailure {
            _ = try invoke(
                bridge, vm,
                class: generatedDescriptor, "addElement",
                prototype: "(Ljava/lang/String;Z)V",
                args: [incomplete, HostBridge.string("title"), .int(1)]
            )
        }

        let descriptor = try vm.call(
            classDescriptor: generatedSerializer,
            method: "getDescriptor",
            prototype: "()\(serialDescriptor)",
            args: [serializerValue]
        )
        let count = try invoke(
            bridge, vm,
            class: serialDescriptor, "getElementsCount",
            prototype: "()I",
            args: [descriptor]
        )
        let firstName = try invoke(
            bridge, vm,
            class: serialDescriptor, "getElementName",
            prototype: "(I)Ljava/lang/String;",
            args: [descriptor, .int(0)]
        )
        let secondName = try invoke(
            bridge, vm,
            class: serialDescriptor, "getElementName",
            prototype: "(I)Ljava/lang/String;",
            args: [descriptor, .int(1)]
        )
        let secondOptional = try invoke(
            bridge, vm,
            class: serialDescriptor, "isElementOptional",
            prototype: "(I)Z",
            args: [descriptor, .int(1)]
        )
        guard case let .int(rawCount) = count,
              case let .int(rawOptional) = secondOptional else {
            return XCTFail("expected generated descriptor metadata")
        }
        XCTAssertEqual(rawCount, 2)
        XCTAssertEqual(vmStringValue(firstName), "title")
        XCTAssertEqual(vmStringValue(secondName), "rank")
        XCTAssertEqual(rawOptional, 1)

        let rankDescriptor = try invoke(
            bridge, vm,
            class: serialDescriptor, "getElementDescriptor",
            prototype: "(I)Lkotlinx/serialization/descriptors/SerialDescriptor;",
            args: [descriptor, .int(1)]
        )
        let rankNullable = try invoke(
            bridge, vm,
            class: serialDescriptor, "isNullable",
            prototype: "()Z",
            args: [rankDescriptor]
        )
        guard case let .int(rawRankNullable) = rankNullable else {
            return XCTFail("expected nullable child descriptor")
        }
        XCTAssertEqual(rawRankNullable, 1)

        let json = RVal.obj(ObjInstance(
            dexType: "Lkotlinx/serialization/json/Json;",
            isHost: true
        ))
        let decodePrototype = "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;"
        let strictInput = HostBridge.string(#"{"title":"Hero","rank":null,"ignored":true}"#)
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: decodePrototype,
            args: [json, serializerValue, strictInput]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected strict unknown-key serialization failure, got \(error)")
            }
            XCTAssertEqual(object.dexType, "Lkotlinx/serialization/SerializationException;")
        }

        let factory = RVal.obj(ObjInstance(
            dexType: "Luy/kohesive/injekt/api/InjektFactory;",
            isHost: true
        ))
        let type = RVal.obj(ObjInstance(dexType: "Ljava/lang/reflect/Type;", isHost: true))
        let lenientJSON = try invoke(
            bridge, vm,
            class: "Luy/kohesive/injekt/api/InjektFactory;", "getInstance",
            prototype: "(Ljava/lang/reflect/Type;)Ljava/lang/Object;",
            args: [factory, type]
        )
        let decodedNull = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: decodePrototype,
            args: [lenientJSON, serializerValue, strictInput]
        )
        XCTAssertTrue(decodedNull.isNull)

        let decodedRank = try invoke(
            bridge, vm,
            class: "Lkotlinx/serialization/json/Json;", "decodeFromString",
            prototype: decodePrototype,
            args: [
                lenientJSON,
                serializerValue,
                HostBridge.string(#"{"title":"Hero","rank":7,"ignored":true}"#),
            ]
        )
        guard case let .obj(boxedRank) = decodedRank else {
            return XCTFail("expected boxed nullable rank")
        }
        XCTAssertEqual(boxedRank.payload as? Int32, 7)
    }

    func testJsonElementsKeepConcreteTypesAcrossArrayAndObjectViews() throws {
        let (vm, bridge) = try makeVM()
        let json = RVal.obj(ObjInstance(
            dexType: "Lkotlinx/serialization/json/Json;",
            isHost: true
        ))
        let jsonObject = "Lkotlinx/serialization/json/JsonObject;"
        let jsonArray = "Lkotlinx/serialization/json/JsonArray;"
        let jsonElement = "Lkotlinx/serialization/json/JsonElement;"
        let jsonPrimitive = "Lkotlinx/serialization/json/JsonPrimitive;"
        let elementKt = "Lkotlinx/serialization/json/JsonElementKt;"
        let arrayGet = "(I)\(jsonElement)"
        let primitiveCast = "(Lkotlinx/serialization/json/JsonElement;)\(jsonPrimitive)"

        func call(
            _ descriptor: String,
            _ name: String,
            prototype: String,
            args: [RVal],
            isStatic: Bool = false
        ) throws -> RVal {
            try invoke(
                bridge, vm,
                class: descriptor,
                name,
                prototype: prototype,
                isStatic: isStatic,
                args: args
            )
        }
        func intValue(_ value: RVal, _ message: String = "expected host integer") throws -> Int32 {
            guard case let .int(result) = value else {
                throw VMError.verify(message)
            }
            return result
        }
        func next(_ iterator: RVal) throws -> RVal {
            try call(
                "Ljava/util/Iterator;", "next",
                prototype: "()Ljava/lang/Object;",
                args: [iterator]
            )
        }
        func primitive(_ element: RVal) throws -> RVal {
            try call(
                elementKt, "getJsonPrimitive",
                prototype: primitiveCast,
                args: [element],
                isStatic: true
            )
        }

        let parsed = try call(
            "Lkotlinx/serialization/json/Json;", "parseToJsonElement",
            prototype: "(Ljava/lang/String;)\(jsonElement)",
            args: [json, HostBridge.string(#"{"title":"Hero","chapters":["1",null,2]}"#)]
        )
        let object = try call(
            elementKt, "getJsonObject",
            prototype: "(Lkotlinx/serialization/json/JsonElement;)\(jsonObject)",
            args: [parsed],
            isStatic: true
        )
        XCTAssertTrue(object === parsed)
        XCTAssertEqual(try intValue(try call(
            jsonObject, "containsKey",
            prototype: "(Ljava/lang/Object;)Z",
            args: [object, HostBridge.string("title")]
        )), 1)
        XCTAssertEqual(try intValue(try call(
            jsonObject, "containsKey",
            prototype: "(Ljava/lang/Object;)Z",
            args: [object, HostBridge.string("missing")]
        )), 0)

        let chapterElement = try call(
            jsonObject, "get",
            prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
            args: [object, HostBridge.string("chapters")]
        )
        let array = try call(
            elementKt, "getJsonArray",
            prototype: "(Lkotlinx/serialization/json/JsonElement;)\(jsonArray)",
            args: [chapterElement],
            isStatic: true
        )
        XCTAssertTrue(array === chapterElement)
        XCTAssertEqual(try intValue(try call(
            jsonArray, "size",
            prototype: "()I",
            args: [array]
        )), 3)
        XCTAssertEqual(try intValue(try call(
            "Ljava/util/List;", "size",
            prototype: "()I",
            args: [array]
        )), 3)

        let first = try call(jsonArray, "get", prototype: arrayGet, args: [array, .int(0)])
        let firstViaList = try call(
            "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [array, .int(0)]
        )
        XCTAssertEqual(vmStringValue(try call(
            jsonPrimitive, "getContent",
            prototype: "()Ljava/lang/String;",
            args: [try primitive(first)]
        )), "1")
        XCTAssertEqual(vmStringValue(try call(
            jsonPrimitive, "getContent",
            prototype: "()Ljava/lang/String;",
            args: [try primitive(firstViaList)]
        )), "1")

        let nullElement = try call(jsonArray, "get", prototype: arrayGet, args: [array, .int(1)])
        XCTAssertTrue(try call(
            elementKt, "getContentOrNull",
            prototype: "(Lkotlinx/serialization/json/JsonPrimitive;)Ljava/lang/String;",
            args: [try primitive(nullElement)],
            isStatic: true
        ).isNull)
        let numberElement = try call(jsonArray, "get", prototype: arrayGet, args: [array, .int(2)])
        XCTAssertEqual(vmStringValue(try call(
            jsonPrimitive, "getContent",
            prototype: "()Ljava/lang/String;",
            args: [try primitive(numberElement)]
        )), "2")

        // Rendering must preserve JSON member order and scalar types instead
        // of falling back to a host object's diagnostic description.
        for (descriptor, value, expected) in [
            (jsonObject, object, #"{"title":"Hero","chapters":["1",null,2]}"#),
            (jsonArray, array, #"["1",null,2]"#),
            (jsonPrimitive, first, #""1""#),
            (jsonPrimitive, numberElement, "2"),
            ("Lkotlinx/serialization/json/JsonNull;", nullElement, "null"),
        ] {
            XCTAssertEqual(vmStringValue(try call(
                descriptor, "toString",
                prototype: "()Ljava/lang/String;",
                args: [value]
            )), expected)
        }

        let entries = try call(
            "Ljava/util/Map;", "entrySet",
            prototype: "()Ljava/util/Set;",
            args: [object]
        )
        let entryIterator = try call(
            "Ljava/lang/Iterable;", "iterator",
            prototype: "()Ljava/util/Iterator;",
            args: [entries]
        )
        for expected in ["title", "chapters"] {
            let entry = try next(entryIterator)
            XCTAssertEqual(vmStringValue(try call(
                "Ljava/util/Map$Entry;", "getKey",
                prototype: "()Ljava/lang/Object;",
                args: [entry]
            )), expected)
        }

        let values = try call(
            jsonObject, "values",
            prototype: "()Ljava/util/Collection;",
            args: [object]
        )
        let valueIterator = try call(
            "Ljava/lang/Iterable;", "iterator",
            prototype: "()Ljava/util/Iterator;",
            args: [values]
        )
        let firstValue = try next(valueIterator)
        let secondValue = try next(valueIterator)
        guard case let .obj(firstValueObject) = firstValue,
              case let .obj(secondValueObject) = secondValue else {
            return XCTFail("expected concrete JSON object values")
        }
        XCTAssertEqual(firstValueObject.dexType, jsonPrimitive)
        XCTAssertEqual(secondValueObject.dexType, jsonArray)

        let constructorList = try call(
            "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            args: [.arr(ArrInstance(
                elemDescriptor: jsonElement,
                elements: [first, nullElement]
            ))],
            isStatic: true
        )
        let arrayCopy = RVal.obj(ObjInstance(dexType: jsonArray, isHost: true))
        _ = try call(
            jsonArray, "<init>",
            prototype: "(Ljava/util/List;)V",
            args: [arrayCopy, constructorList]
        )
        XCTAssertEqual(try intValue(try call(
            jsonArray, "size",
            prototype: "()I",
            args: [arrayCopy]
        )), 2)

        let rawMap = RVal.obj(ObjInstance(
            dexType: "Ljava/util/LinkedHashMap;",
            isHost: true
        ))
        _ = try call(
            "Ljava/util/LinkedHashMap;", "<init>",
            prototype: "()V",
            args: [rawMap]
        )
        _ = try call(
            "Ljava/util/Map;", "put",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            args: [rawMap, HostBridge.string("title"), first]
        )
        _ = try call(
            "Ljava/util/Map;", "put",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            args: [rawMap, HostBridge.string("chapters"), array]
        )
        let objectCopy = RVal.obj(ObjInstance(dexType: jsonObject, isHost: true))
        _ = try call(
            jsonObject, "<init>",
            prototype: "(Ljava/util/Map;)V",
            args: [objectCopy, rawMap]
        )
        XCTAssertEqual(try intValue(try call(
            "Ljava/util/Map;", "size",
            prototype: "()I",
            args: [objectCopy]
        )), 2)
        let copiedArray = try call(
            elementKt, "getJsonArray",
            prototype: "(Lkotlinx/serialization/json/JsonElement;)\(jsonArray)",
            args: [try call(
                jsonObject, "get",
                prototype: "(Ljava/lang/Object;)Ljava/lang/Object;",
                args: [objectCopy, HostBridge.string("chapters")]
            )],
            isStatic: true
        )
        XCTAssertEqual(try intValue(try call(
            jsonArray, "size",
            prototype: "()I",
            args: [copiedArray]
        )), 3)

        XCTAssertThrowsError(try call(
            jsonArray, "get",
            prototype: arrayGet,
            args: [array, .int(3)]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected JsonArray bounds failure, got \(error)")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/IndexOutOfBoundsException;")
        }

        // The ordered scanner must retain the response parser's resource
        // limits, including repeated keys that collapse to one map entry.
        let rejectedInputs: [(String, CompatHTMLPolicy)] = [
            (#"{"x":[1,]}"#, .init()),
            (#"{"x":"\u12"}"#, .init()),
            ("[1,[2]]", .init(maximumDepth: 2)),
            ("[0,1]", .init(maximumNodes: 2)),
            (#"{"x":0,"x":1}"#, .init(maximumAttributes: 1)),
        ]
        for (text, policy) in rejectedInputs {
            let (limitedVM, limitedBridge) = try makeVM(htmlPolicy: policy)
            XCTAssertThrowsError(try invoke(
                limitedBridge, limitedVM,
                class: "Lkotlinx/serialization/json/Json;", "parseToJsonElement",
                prototype: "(Ljava/lang/String;)\(jsonElement)",
                args: [json, HostBridge.string(text)]
            )) { error in
                guard let throwable = error as? DEXThrowable,
                      case let .obj(object) = throwable.value else {
                    return XCTFail("expected bounded JSON failure, got \(error)")
                }
                XCTAssertEqual(object.dexType, "Lkotlinx/serialization/SerializationException;")
            }
        }
    }

    func testChapterScanlatorBridgePreservesTheCombinedPizzaReaderCredit() throws {
        let (vm, bridge) = try makeVM()
        let chapter = HostBridge.chapterValue(from: SChapterCompat(
            url: "/chapter/7",
            name: "Chapter Seven"
        ))
        _ = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/model/SChapter;", "setScanlator",
            prototype: "(Ljava/lang/String;)V",
            args: [chapter, HostBridge.string("Team A & Team B")]
        )
        let scanlator = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/model/SChapter;", "getScanlator",
            prototype: "()Ljava/lang/String;",
            args: [chapter]
        )
        XCTAssertEqual(vmStringValue(scanlator), "Team A & Team B")
        XCTAssertEqual(
            HostBridge.chapterCompat(from: chapter)?.scanlators,
            ["Team A & Team B"]
        )
    }

    func testHostBridgeBuildsTransportNeutralBoundedRequest() throws {
        let (vm, bridge) = try makeVM()
        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))

        let urlCompanion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let url = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [urlCompanion, HostBridge.string("https://example.test/manga?page=1")]
        )

        let headerBuilder = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "headersBuilder",
            prototype: "()Lokhttp3/Headers$Builder;",
            args: [source]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "set",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;",
            args: [headerBuilder, HostBridge.string("Accept"), HostBridge.string("text/html")]
        )
        let headers = try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "build",
            prototype: "()Lokhttp3/Headers;",
            args: [headerBuilder]
        )

        let formBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/FormBody$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "<init>",
            prototype: "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            args: [formBuilder, .null, .int(1), .null]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "add",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            args: [formBuilder, HostBridge.string("page"), HostBridge.string("1")]
        )
        let body = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "build",
            prototype: "()Lokhttp3/FormBody;",
            args: [formBuilder]
        )

        let secondsUnit = try XCTUnwrap(bridge.staticFields["Lkotlin/time/DurationUnit;->SECONDS"])
        let duration = try invoke(
            bridge, vm,
            class: "Lkotlin/time/DurationKt;", "toDuration",
            prototype: "(ILkotlin/time/DurationUnit;)J",
            isStatic: true,
            args: [.int(30), secondsUnit]
        )
        let cacheBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/CacheControl$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "<init>",
            prototype: "()V",
            args: [cacheBuilder]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "maxAge-LRDsOJo",
            prototype: "(J)Lokhttp3/CacheControl$Builder;",
            args: [cacheBuilder, duration]
        )
        let cache = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "build",
            prototype: "()Lokhttp3/CacheControl;",
            args: [cacheBuilder]
        )

        let requestBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/Request$Builder;", "<init>",
            prototype: "()V",
            args: [requestBuilder]
        )
        for (name, prototype, argument) in [
            ("url", "(Lokhttp3/HttpUrl;)Lokhttp3/Request$Builder;", url),
            ("headers", "(Lokhttp3/Headers;)Lokhttp3/Request$Builder;", headers),
            ("cacheControl", "(Lokhttp3/CacheControl;)Lokhttp3/Request$Builder;", cache),
            ("post", "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;", body),
        ] {
            _ = try invoke(
                bridge, vm,
                class: "Lokhttp3/Request$Builder;", name,
                prototype: prototype,
                args: [requestBuilder, argument]
            )
        }
        let request = try invoke(
            bridge, vm,
            class: "Lokhttp3/Request$Builder;", "build",
            prototype: "()Lokhttp3/Request;",
            args: [requestBuilder]
        )

        let helper = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "getNetwork",
            prototype: "()Leu/kanade/tachiyomi/network/NetworkHelper;",
            args: [source]
        )
        let client = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/network/NetworkHelper;", "getClient",
            prototype: "()Lokhttp3/OkHttpClient;",
            args: [helper]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/OkHttpClient;", "newCall",
            prototype: "(Lokhttp3/Request;)Lokhttp3/Call;",
            args: [client, request]
        )

        XCTAssertEqual(bridge.lastPreparedRequest, CompatHTTPRequest(
            url: "https://example.test/manga?page=1",
            method: "POST",
            headers: [CompatHTTPHeader(name: "Accept", value: "text/html")],
            body: .form(fields: [CompatHTTPFormField(name: "page", value: "1")]),
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 30)
        ))
    }

    func testHttpUrlBuilderPreservesOrderAndEncodesQueryComponents() throws {
        let (vm, bridge) = try makeVM()
        let companion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let url = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [companion, HostBridge.string("https://example.test/api?existing=1")]
        )
        let builder = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl;", "newBuilder",
            prototype: "()Lokhttp3/HttpUrl$Builder;",
            args: [url]
        )
        for (name, value) in [("action", "search"), ("q", "hero & +/?")] {
            _ = try invoke(
                bridge, vm,
                class: "Lokhttp3/HttpUrl$Builder;", "addQueryParameter",
                prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;",
                args: [builder, HostBridge.string(name), HostBridge.string(value)]
            )
        }
        let built = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Builder;", "build",
            prototype: "()Lokhttp3/HttpUrl;",
            args: [builder]
        )
        let rendered = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl;", "toString",
            prototype: "()Ljava/lang/String;",
            args: [built]
        )

        XCTAssertEqual(
            vmStringValue(rendered),
            "https://example.test/api?existing=1&action=search&q=hero%20%26%20%2B%2F%3F"
        )
    }

    func testHttpUrlBuilderRejectsOversizedPercentEncodedQuery() throws {
        let (vm, bridge) = try makeVM()
        let companion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let url = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [companion, HostBridge.string("https://example.test/api")]
        )
        let builder = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl;", "newBuilder",
            prototype: "()Lokhttp3/HttpUrl$Builder;",
            args: [url]
        )

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Builder;", "addQueryParameter",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;",
            args: [
                builder,
                HostBridge.string("q"),
                HostBridge.string(String(repeating: " ", count: 3_000)),
            ]
        ))
    }

    func testKotlinInstantParseOrNullReturnsEpochMilliseconds() throws {
        let (vm, bridge) = try makeVM()
        let companion = try XCTUnwrap(
            bridge.staticFields["Lkotlin/time/Instant;->Companion"]
        )
        let parsed = try invoke(
            bridge, vm,
            class: "Lkotlin/time/Instant$Companion;", "parseOrNull",
            prototype: "(Ljava/lang/CharSequence;)Lkotlin/time/Instant;",
            args: [companion, HostBridge.string("1970-01-01T00:00:01.234Z")]
        )
        let milliseconds = try invoke(
            bridge, vm,
            class: "Lkotlin/time/Instant;", "toEpochMilliseconds",
            prototype: "()J",
            args: [parsed]
        )
        guard case let .long(value) = milliseconds else {
            return XCTFail("expected epoch milliseconds")
        }
        XCTAssertEqual(value, 1_234)

        let invalid = try invoke(
            bridge, vm,
            class: "Lkotlin/time/Instant$Companion;", "parseOrNull",
            prototype: "(Ljava/lang/CharSequence;)Lkotlin/time/Instant;",
            args: [companion, HostBridge.string("not-an-instant")]
        )
        XCTAssertTrue(invalid.isNull)
    }

    func testJavaZoneIDOfAcceptsIANAIdentifierAndRejectsInvalidInput() throws {
        let (vm, bridge) = try makeVM()
        let zone = try invoke(
            bridge, vm,
            class: "Ljava/time/ZoneId;", "of",
            prototype: "(Ljava/lang/String;)Ljava/time/ZoneId;",
            isStatic: true,
            args: [HostBridge.string("Europe/Paris")]
        )
        guard case let .obj(object) = zone else {
            return XCTFail("expected ZoneId host object")
        }
        XCTAssertEqual(object.dexType, "Ljava/time/ZoneId;")

        for invalid in ["", "Not/A_Time_Zone", String(repeating: "A", count: 257)] {
            XCTAssertThrowsError(try invoke(
                bridge, vm,
                class: "Ljava/time/ZoneId;", "of",
                prototype: "(Ljava/lang/String;)Ljava/time/ZoneId;",
                isStatic: true,
                args: [HostBridge.string(invalid)]
            )) { error in
                guard let throwable = error as? DEXThrowable,
                      case let .obj(throwableObject) = throwable.value else {
                    return XCTFail("expected DateTimeException for \(invalid)")
                }
                XCTAssertEqual(throwableObject.dexType, "Ljava/time/DateTimeException;")
            }
        }
    }

    func testJavaLocalDateOfValidatesCalendarDateAndUsesParisStartOfDay() throws {
        let (vm, bridge) = try makeVM()
        let date = try invoke(
            bridge, vm,
            class: "Ljava/time/LocalDate;", "of",
            prototype: "(III)Ljava/time/LocalDate;",
            isStatic: true,
            args: [.int(2026), .int(8), .int(8)]
        )
        let zone = try invoke(
            bridge, vm,
            class: "Ljava/time/ZoneId;", "of",
            prototype: "(Ljava/lang/String;)Ljava/time/ZoneId;",
            isStatic: true,
            args: [HostBridge.string("Europe/Paris")]
        )
        let zoned = try invoke(
            bridge, vm,
            class: "Ljava/time/LocalDate;", "atStartOfDay",
            prototype: "(Ljava/time/ZoneId;)Ljava/time/ZonedDateTime;",
            args: [date, zone]
        )
        let instant = try invoke(
            bridge, vm,
            class: "Ljava/time/chrono/ChronoZonedDateTime;", "toInstant",
            prototype: "()Ljava/time/Instant;",
            args: [zoned]
        )
        let epoch = try invoke(
            bridge, vm,
            class: "Ljava/time/Instant;", "toEpochMilli",
            prototype: "()J",
            args: [instant]
        )
        guard case let .long(milliseconds) = epoch else {
            return XCTFail("expected epoch milliseconds")
        }
        XCTAssertEqual(milliseconds, 1_786_140_000_000)

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/time/LocalDate;", "of",
            prototype: "(III)Ljava/time/LocalDate;",
            isStatic: true,
            args: [.int(2025), .int(2), .int(29)]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected DateTimeException")
            }
            XCTAssertEqual(object.dexType, "Ljava/time/DateTimeException;")
        }
    }

    func testJsoupParseBodyFragmentPreservesBoundedBaseURLResolution() throws {
        let (vm, bridge) = try makeVM()
        let document = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/Jsoup;", "parseBodyFragment",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            isStatic: true,
            args: [
                HostBridge.string(#"<a class="entry" href="/oeuvre/hero/">Hero</a>"#),
                HostBridge.string("https://mangas-origines.fr/catalogue/"),
            ]
        )
        let anchor = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Document;", "selectFirst",
            prototype: "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
            args: [document, HostBridge.string("a.entry")]
        )
        let absoluteURL = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Element;", "absUrl",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;",
            args: [anchor, HostBridge.string("href")]
        )
        XCTAssertEqual(
            vmStringValue(absoluteURL),
            "https://mangas-origines.fr/oeuvre/hero/"
        )

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lorg/jsoup/Jsoup;", "parseBodyFragment",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            isStatic: true,
            args: [HostBridge.string("<p>unsafe</p>"), HostBridge.string("file:///private/")]
        ))
    }

    func testJsoupElementSiblingAttributeAndEachTextMatchOriginesDetailsAndPages() throws {
        let (vm, bridge) = try makeVM()
        let document = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/Jsoup;", "parseBodyFragment",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            isStatic: true,
            args: [
                HostBridge.string(#"""
                <div class="infos"><dt>Auteur</dt><dd>Measured Writer</dd></div>
                <div class="genres"><a data-src="/a">Action</a><a>Adventure</a></div>
                """#),
                HostBridge.string("https://mangas-origines.fr/oeuvre/hero/"),
            ]
        )
        let terms = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Document;", "select",
            prototype: "(Ljava/lang/String;)Lorg/jsoup/select/Elements;",
            args: [document, HostBridge.string("div.infos dt")]
        )
        let term = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/select/Elements;", "first",
            prototype: "()Lorg/jsoup/nodes/Element;",
            args: [terms]
        )
        let sibling = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Element;", "nextElementSibling",
            prototype: "()Lorg/jsoup/nodes/Element;",
            args: [term]
        )
        let siblingText = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Element;", "text",
            prototype: "()Ljava/lang/String;",
            args: [sibling]
        )
        XCTAssertEqual(vmStringValue(siblingText), "Measured Writer")

        let genres = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Document;", "select",
            prototype: "(Ljava/lang/String;)Lorg/jsoup/select/Elements;",
            args: [document, HostBridge.string("div.genres a")]
        )
        let texts = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/select/Elements;", "eachText",
            prototype: "()Ljava/util/List;",
            args: [genres]
        )
        for (index, expected) in ["Action", "Adventure"].enumerated() {
            let text = try invoke(
                bridge, vm,
                class: "Ljava/util/List;", "get",
                prototype: "(I)Ljava/lang/Object;",
                args: [texts, .int(Int32(index))]
            )
            XCTAssertEqual(vmStringValue(text), expected)
        }
        let firstGenre = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/select/Elements;", "first",
            prototype: "()Lorg/jsoup/nodes/Element;",
            args: [genres]
        )
        let hasDataSource = try invoke(
            bridge, vm,
            class: "Lorg/jsoup/nodes/Element;", "hasAttr",
            prototype: "(Ljava/lang/String;)Z",
            args: [firstGenre, HostBridge.string("data-src")]
        )
        guard case let .int(rawHasDataSource) = hasDataSource else {
            return XCTFail("expected Element.hasAttr boolean")
        }
        XCTAssertEqual(rawHasDataSource, 1)
    }

    func testHostBridgeRejectsMalformedRequestInputs() throws {
        let (vm, bridge) = try makeVM()
        let urlCompanion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [urlCompanion, HostBridge.string("file:///private/secret")]
        ))
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [urlCompanion, HostBridge.string("https://name:value@example.test/path")]
        ))

        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))
        let headerBuilder = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "headersBuilder",
            prototype: "()Lokhttp3/Headers$Builder;",
            args: [source]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "set",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;",
            args: [headerBuilder, HostBridge.string("X-Test"), HostBridge.string("ok\r\nInjected: yes")]
        ))

        let formBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/FormBody$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "<init>",
            prototype: "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            args: [formBuilder, .null, .int(1), .null]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "add",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            args: [formBuilder, HostBridge.string("payload"), HostBridge.string(String(repeating: "x", count: 1_048_577))]
        ))
        XCTAssertNil(bridge.lastPreparedRequest)
    }

    func testSourceModelBridgeBoundsPageFieldsAndResultCounts() throws {
        let (vm, bridge) = try makeVM()
        let pageDescriptor = "Leu/kanade/tachiyomi/source/model/Page;"
        let oversizedPage = RVal.obj(ObjInstance(dexType: pageDescriptor, isHost: true))
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: pageDescriptor, "<init>",
            prototype: "(ILjava/lang/String;Ljava/lang/String;Landroid/net/Uri;)V",
            args: [
                oversizedPage,
                .int(0),
                HostBridge.string(""),
                HostBridge.string("https://example.test/" + String(repeating: "x", count: 8_193)),
                .null,
            ]
        ))

        let pageValues = (0...2_048).map {
            HostBridge.pageValue(from: PageCompat(
                index: $0,
                imageURL: "https://example.test/page-\($0).jpg"
            ))
        }
        let pageList = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [.arr(ArrInstance(elemDescriptor: "Ljava/lang/Object;", elements: pageValues))]
        )
        XCTAssertNil(HostBridge.pagesCompat(from: pageList))

        let mangaValues = (0...2_048).map {
            HostBridge.mangaValue(from: SMangaCompat(url: "/manga/\($0)", title: "Manga \($0)"))
        }
        let mangaList = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [.arr(ArrInstance(elemDescriptor: "Ljava/lang/Object;", elements: mangaValues))]
        )
        let mangasPageDescriptor = "Leu/kanade/tachiyomi/source/model/MangasPage;"
        let mangasPage = RVal.obj(ObjInstance(dexType: mangasPageDescriptor, isHost: true))
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: mangasPageDescriptor, "<init>",
            prototype: "(Ljava/util/List;Z)V",
            args: [mangasPage, mangaList, .int(0)]
        ))
    }

    func testURLFormEncoderMatchesJavaUTF8SemanticsAndIsBounded() throws {
        let (vm, bridge) = try makeVM()
        let encoded = try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("A b+c/é~*"), HostBridge.string("UTF-8")]
        )
        XCTAssertEqual(vmStringValue(encoded), "A+b%2Bc%2F%C3%A9%7E*")

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("value"), HostBridge.string("UTF-16")]
        ))
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string(String(repeating: "x", count: 8_193)), HostBridge.string("UTF-8")]
        ))
    }

    func testKotlinJoinToStringDefaultsAndExplicitLimit() throws {
        let (vm, bridge) = try makeVM()
        let values = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/Object;",
            elements: [
                HostBridge.string("Action"),
                HostBridge.string("Adventure"),
                HostBridge.string("Comic"),
            ]
        ))
        let list = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [values]
        )
        let prototype = "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;"

        let defaults = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "joinToString$default",
            prototype: prototype,
            isStatic: true,
            args: [list, .null, .null, .null, .int(0), .null, .null, .int(0x3F), .null]
        )
        XCTAssertEqual(vmStringValue(defaults), "Action, Adventure, Comic")

        let limited = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "joinToString$default",
            prototype: prototype,
            isStatic: true,
            args: [
                list,
                HostBridge.string("|"),
                HostBridge.string("["),
                HostBridge.string("]"),
                .int(2),
                HostBridge.string("more"),
                .null,
                .int(0),
                .null,
            ]
        )
        XCTAssertEqual(vmStringValue(limited), "[Action|Adventure|more]")
    }

    func testKotlinJoinToStringEnforcesOutputLimit() throws {
        let (vm, bridge) = try makeVM(
            htmlPolicy: .init(maximumExtractedStringBytes: 4)
        )
        let values = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/Object;",
            elements: [HostBridge.string("12345")]
        ))
        let list = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [values]
        )

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "joinToString$default",
            prototype: "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;",
            isStatic: true,
            args: [list, .null, .null, .null, .int(0), .null, .null, .int(0x3F), .null]
        ))
    }

    func testKotlinDistinctPreservesFirstOccurrenceOrder() throws {
        let (vm, bridge) = try makeVM()
        let values = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/Object;",
            elements: [
                HostBridge.string("Manga"),
                HostBridge.string("Action"),
                HostBridge.string("Manga"),
                HostBridge.string("Drama"),
                HostBridge.string("Action"),
            ]
        ))
        let list = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [values]
        )
        let distinct = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "distinct",
            prototype: "(Ljava/lang/Iterable;)Ljava/util/List;",
            isStatic: true,
            args: [list]
        )

        for (index, expected) in ["Manga", "Action", "Drama"].enumerated() {
            let value = try invoke(
                bridge, vm,
                class: "Ljava/util/List;", "get",
                prototype: "(I)Ljava/lang/Object;",
                args: [distinct, .int(Int32(index))]
            )
            XCTAssertEqual(vmStringValue(value), expected)
        }
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [distinct, .int(3)]
        ))
    }

    func testKotlinDistinctRejectsExcessiveQuadraticWork() throws {
        let (vm, bridge) = try makeVM()
        let values = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/Object;",
            elements: (0...4_000).map { HostBridge.string("value-\($0)") }
        ))
        let list = try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "listOf",
            prototype: "([Ljava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [values]
        )

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lkotlin/collections/CollectionsKt;", "distinct",
            prototype: "(Ljava/lang/Iterable;)Ljava/util/List;",
            isStatic: true,
            args: [list]
        ))
    }

    func testKotlinSubstringDefaultHelpersMatchDelimiterSemantics() throws {
        let (vm, bridge) = try makeVM()
        let prototype = "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;"
        let script = "prefix window.__DATA__ = {\"id\":42}; suffix;"

        let after = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "substringAfter$default",
            prototype: prototype,
            isStatic: true,
            args: [
                HostBridge.string(script),
                HostBridge.string("window.__DATA__ = "),
                .null,
                .int(0x02),
                .null,
            ]
        )
        XCTAssertEqual(vmStringValue(after), "{\"id\":42}; suffix;")

        let before = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "substringBeforeLast$default",
            prototype: prototype,
            isStatic: true,
            args: [after, HostBridge.string(";"), .null, .int(0x02), .null]
        )
        XCTAssertEqual(vmStringValue(before), "{\"id\":42}; suffix")

        let charPrototype = "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;"
        let chapterPath = HostBridge.string("hero/7#chapter-7")
        let afterLast = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "substringAfterLast$default",
            prototype: charPrototype,
            isStatic: true,
            args: [chapterPath, .int(35), .null, .int(0x02), .null]
        )
        let beforeLast = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "substringBeforeLast$default",
            prototype: charPrototype,
            isStatic: true,
            args: [chapterPath, .int(35), .null, .int(0x02), .null]
        )
        XCTAssertEqual(vmStringValue(afterLast), "chapter-7")
        XCTAssertEqual(vmStringValue(beforeLast), "hero/7")

        let missing = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "substringAfter$default",
            prototype: prototype,
            isStatic: true,
            args: [
                HostBridge.string("unchanged"),
                HostBridge.string("missing"),
                .null,
                .int(0x02),
                .null,
            ]
        )
        XCTAssertEqual(vmStringValue(missing), "unchanged")
    }

    func testKotlinNullableStringEqualsHonorsIgnoreCase() throws {
        let (vm, bridge) = try makeVM()
        let prototype = "(Ljava/lang/String;Ljava/lang/String;Z)Z"

        func equals(_ left: RVal, _ right: RVal, ignoreCase: Bool) throws -> Int32 {
            let value = try invoke(
                bridge, vm,
                class: "Lkotlin/text/StringsKt;", "equals",
                prototype: prototype,
                isStatic: true,
                args: [left, right, .int(ignoreCase ? 1 : 0)]
            )
            guard case let .int(result) = value else {
                throw VMError.verify("expected Kotlin boolean result")
            }
            return result
        }

        XCTAssertEqual(try equals(.null, .null, ignoreCase: true), 1)
        XCTAssertEqual(try equals(.null, HostBridge.string("manga"), ignoreCase: true), 0)
        XCTAssertEqual(try equals(
            HostBridge.string("MANGA"),
            HostBridge.string("manga"),
            ignoreCase: false
        ), 0)
        XCTAssertEqual(try equals(
            HostBridge.string("MANGA"),
            HostBridge.string("manga"),
            ignoreCase: true
        ), 1)
    }

    func testKotlinSplitRegexAndAffixHelpersMatchPagePathSemantics() throws {
        let (vm, bridge) = try makeVM()
        let splitPrototype = "(Ljava/lang/CharSequence;[Ljava/lang/String;ZIILjava/lang/Object;)Ljava/util/List;"
        let slash = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [HostBridge.string("/")]
        ))
        let parts = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "split$default",
            prototype: splitPrototype,
            isStatic: true,
            args: [
                HostBridge.string("42/7?token=test"),
                slash,
                .int(0),
                .int(2),
                .int(0),
                .null,
            ]
        )
        let first = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [parts, .int(0)]
        )
        let second = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [parts, .int(1)]
        )
        XCTAssertEqual(vmStringValue(first), "42")
        XCTAssertEqual(vmStringValue(second), "7?token=test")
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [parts, .int(2)]
        ))

        let characterParts = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "split$default",
            prototype: "(Ljava/lang/CharSequence;[CZIILjava/lang/Object;)Ljava/util/List;",
            isStatic: true,
            args: [
                HostBridge.string("oeuvre/hero/chapter-7"),
                .arr(ArrInstance(elemDescriptor: "C", elements: [.int(47)])),
                .int(0),
                .int(2),
                .int(0),
                .null,
            ]
        )
        let characterTail = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [characterParts, .int(1)]
        )
        XCTAssertEqual(vmStringValue(characterTail), "hero/chapter-7")

        let emptyDelimiter = RVal.arr(ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [HostBridge.string("")]
        ))
        let characters = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "split$default",
            prototype: splitPrototype,
            isStatic: true,
            args: [
                HostBridge.string("ab"),
                emptyDelimiter,
                .int(0),
                .int(0),
                .int(0x04),
                .null,
            ]
        )
        for (index, expected) in ["", "a", "b", ""].enumerated() {
            let value = try invoke(
                bridge, vm,
                class: "Ljava/util/List;", "get",
                prototype: "(I)Ljava/lang/Object;",
                args: [characters, .int(Int32(index))]
            )
            XCTAssertEqual(vmStringValue(value), expected)
        }

        let affixPrototype = "(Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Z"
        let defaultCaseSensitive = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "startsWith$default",
            prototype: affixPrototype,
            isStatic: true,
            args: [
                HostBridge.string("HTTPS://cdn/PAGE.JPG"),
                HostBridge.string("http"),
                .int(1),
                .int(0x02),
                .null,
            ]
        )
        let explicitIgnoreCase = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "startsWith$default",
            prototype: affixPrototype,
            isStatic: true,
            args: [
                HostBridge.string("HTTPS://cdn/PAGE.JPG"),
                HostBridge.string("http"),
                .int(1),
                .int(0),
                .null,
            ]
        )
        let suffix = try invoke(
            bridge, vm,
            class: "Lkotlin/text/StringsKt;", "endsWith$default",
            prototype: affixPrototype,
            isStatic: true,
            args: [
                HostBridge.string("HTTPS://cdn/PAGE.JPG"),
                HostBridge.string(".jpg"),
                .int(1),
                .int(0),
                .null,
            ]
        )
        guard case let .int(defaultResult) = defaultCaseSensitive,
              case let .int(ignoreCaseResult) = explicitIgnoreCase,
              case let .int(suffixResult) = suffix else {
            return XCTFail("expected Kotlin boolean results")
        }
        XCTAssertEqual(defaultResult, 0)
        XCTAssertEqual(ignoreCaseResult, 1)
        XCTAssertEqual(suffixResult, 1)

        let regexDescriptor = "Lkotlin/text/Regex;"
        let regex = RVal.obj(ObjInstance(dexType: regexDescriptor, isHost: true))
        _ = try invoke(
            bridge, vm,
            class: regexDescriptor, "<init>",
            prototype: "(Ljava/lang/String;)V",
            args: [regex, HostBridge.string(#"^\d+"#)]
        )
        let findPrototype = "(Lkotlin/text/Regex;Ljava/lang/CharSequence;IILjava/lang/Object;)Lkotlin/text/MatchResult;"
        let match = try invoke(
            bridge, vm,
            class: regexDescriptor, "find$default",
            prototype: findPrototype,
            isStatic: true,
            args: [regex, HostBridge.string("7?token=test"), .int(99), .int(0x02), .null]
        )
        let matchValue = try invoke(
            bridge, vm,
            class: "Lkotlin/text/MatchResult;", "getValue",
            prototype: "()Ljava/lang/String;",
            args: [match]
        )
        XCTAssertEqual(vmStringValue(matchValue), "7")

        let noMatch = try invoke(
            bridge, vm,
            class: regexDescriptor, "find$default",
            prototype: findPrototype,
            isStatic: true,
            args: [regex, HostBridge.string("chapter-7"), .int(0), .int(0), .null]
        )
        XCTAssertTrue(noMatch.isNull)

        let containsMatch = try invoke(
            bridge, vm,
            class: regexDescriptor, "containsMatchIn",
            prototype: "(Ljava/lang/CharSequence;)Z",
            args: [regex, HostBridge.string("7-chapter")]
        )
        let doesNotContainMatch = try invoke(
            bridge, vm,
            class: regexDescriptor, "containsMatchIn",
            prototype: "(Ljava/lang/CharSequence;)Z",
            args: [regex, HostBridge.string("chapter-seven")]
        )
        guard case let .int(containsMatchValue) = containsMatch,
              case let .int(doesNotContainMatchValue) = doesNotContainMatch else {
            return XCTFail("expected Regex.containsMatchIn boolean results")
        }
        XCTAssertEqual(containsMatchValue, 1)
        XCTAssertEqual(doesNotContainMatchValue, 0)

        let ignoreCase = try XCTUnwrap(
            bridge.staticFields["Lkotlin/text/RegexOption;->IGNORE_CASE"]
        )
        let caseInsensitiveRegex = RVal.obj(ObjInstance(dexType: regexDescriptor, isHost: true))
        _ = try invoke(
            bridge, vm,
            class: regexDescriptor, "<init>",
            prototype: "(Ljava/lang/String;Lkotlin/text/RegexOption;)V",
            args: [
                caseInsensitiveRegex,
                HostBridge.string(#"/(\d+)\.(jpg|png)$"#),
                ignoreCase,
            ]
        )
        let uppercaseExtension = try invoke(
            bridge, vm,
            class: regexDescriptor, "containsMatchIn",
            prototype: "(Ljava/lang/CharSequence;)Z",
            args: [caseInsensitiveRegex, HostBridge.string("/42.JPG")]
        )
        guard case let .int(uppercaseExtensionValue) = uppercaseExtension else {
            return XCTFail("expected RegexOption.IGNORE_CASE boolean result")
        }
        XCTAssertEqual(uppercaseExtensionValue, 1)

        let uppercaseMatch = try invoke(
            bridge, vm,
            class: regexDescriptor, "find$default",
            prototype: findPrototype,
            isStatic: true,
            args: [
                caseInsensitiveRegex,
                HostBridge.string("/42.JPG"),
                .int(0),
                .int(0),
                .null,
            ]
        )
        let uppercaseGroups = try invoke(
            bridge, vm,
            class: "Lkotlin/text/MatchResult;", "getGroupValues",
            prototype: "()Ljava/util/List;",
            args: [uppercaseMatch]
        )
        let numericGroup = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [uppercaseGroups, .int(1)]
        )
        let extensionGroup = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [uppercaseGroups, .int(2)]
        )
        XCTAssertEqual(vmStringValue(numericGroup), "42")
        XCTAssertEqual(vmStringValue(extensionGroup), "JPG")

        let destructured = try invoke(
            bridge, vm,
            class: "Lkotlin/text/MatchResult;", "getDestructured",
            prototype: "()Lkotlin/text/MatchResult$Destructured;",
            args: [uppercaseMatch]
        )
        let destructuredMatch = try invoke(
            bridge, vm,
            class: "Lkotlin/text/MatchResult$Destructured;", "getMatch",
            prototype: "()Lkotlin/text/MatchResult;",
            args: [destructured]
        )
        let destructuredGroups = try invoke(
            bridge, vm,
            class: "Lkotlin/text/MatchResult;", "getGroupValues",
            prototype: "()Ljava/util/List;",
            args: [destructuredMatch]
        )
        let destructuredExtension = try invoke(
            bridge, vm,
            class: "Ljava/util/List;", "get",
            prototype: "(I)Ljava/lang/Object;",
            args: [destructuredGroups, .int(2)]
        )
        XCTAssertEqual(vmStringValue(destructuredExtension), "JPG")

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: regexDescriptor, "find$default",
            prototype: findPrototype,
            isStatic: true,
            args: [regex, HostBridge.string("7"), .int(2), .int(0), .null]
        ))
    }
}
