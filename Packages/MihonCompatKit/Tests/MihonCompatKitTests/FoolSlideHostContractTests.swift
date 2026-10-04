import XCTest
@testable import MihonCompatKit

final class FoolSlideHostContractTests: XCTestCase {
    private func makeVM() throws -> (DexInterpreter, HostBridge) {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "noop", registers: 0, ins: 0, outs: 0,
            insns: [0x000e], isStatic: true
        ))
        let bridge = HostBridge.minimal()
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(
        _ bridge: HostBridge, _ vm: DexInterpreter,
        _ descriptor: String, _ name: String, _ prototype: String,
        _ args: [RVal], isStatic: Bool = false
    ) throws -> RVal {
        try XCTUnwrap(bridge.resolve(
            class: descriptor, name, prototype: prototype, isStatic: isStatic
        ))(vm, args)
    }

    private func string(_ value: RVal) throws -> String {
        guard case let .obj(object) = value else { throw VMError.verify("test expected string") }
        return try XCTUnwrap(object.payload as? String)
    }

    private func sameObject(_ lhs: RVal, _ rhs: RVal, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .obj(left) = lhs, case let .obj(right) = rhs else {
            return XCTFail("expected object identity", file: file, line: line)
        }
        XCTAssertTrue(left === right, file: file, line: line)
    }

    private func dateYear(_ bridge: HostBridge, _ vm: DexInterpreter, _ input: String, _ formatter: RVal) throws -> Int32 {
        let date = try invoke(
            bridge, vm, "Ljava/time/LocalDate;", "parse",
            "(Ljava/lang/CharSequence;Ljava/time/format/DateTimeFormatter;)Ljava/time/LocalDate;",
            [HostBridge.string(input), formatter], isStatic: true
        )
        let value = try invoke(bridge, vm, "Ljava/time/LocalDate;", "getYear", "()I", [date])
        guard case let .int(year) = value else { throw VMError.verify("test expected date year") }
        return year
    }

    func testFormatterBuilderMutatesIdentityUsesFirstYearDefaultAndSnapshotsFormatters() throws {
        let (vm, bridge) = try makeVM()
        let descriptor = "Ljava/time/format/DateTimeFormatterBuilder;"
        let builder = RVal.obj(ObjInstance(dexType: descriptor, isHost: true))
        _ = try invoke(bridge, vm, descriptor, "<init>", "()V", [builder])
        for part in ["dd'rd' ", "MMMM"] {
            let appended = try invoke(
                bridge, vm, descriptor, "appendPattern",
                "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
                [builder, HostBridge.string(part)]
            )
            sameObject(appended, builder)
        }
        let locale = try XCTUnwrap(bridge.staticFields["Ljava/util/Locale;->ENGLISH"])
        let beforeDefault = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        let field = try XCTUnwrap(bridge.staticFields["Ljava/time/temporal/ChronoField;->YEAR"])
        for year: Int64 in [2024, 2025] {
            let defaulted = try invoke(
                bridge, vm, descriptor, "parseDefaulting",
                "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;",
                [builder, field, .long(year)]
            )
            sameObject(defaulted, builder)
        }
        let first = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        XCTAssertEqual(try dateYear(bridge, vm, "23rd August", first), 2024)
        XCTAssertThrowsError(try dateYear(bridge, vm, "23rd August", beforeDefault))
        let explicitBuilder = RVal.obj(ObjInstance(dexType: descriptor, isHost: true))
        _ = try invoke(bridge, vm, descriptor, "<init>", "()V", [explicitBuilder])
        _ = try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [explicitBuilder, HostBridge.string("dd'rd' MMMM, yyyy")]
        )
        _ = try invoke(
            bridge, vm, descriptor, "parseDefaulting",
            "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;",
            [explicitBuilder, field, .long(2024)]
        )
        let second = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [explicitBuilder, locale]
        )
        XCTAssertEqual(try dateYear(bridge, vm, "23rd August, 2026", second), 2026)
        XCTAssertEqual(try dateYear(bridge, vm, "23rd August", first), 2024)
    }

    func testUnmeasuredDefaultBeforePatternAndAppendAfterDefaultSequencesFailClosed() throws {
        let (vm, bridge) = try makeVM()
        let descriptor = "Ljava/time/format/DateTimeFormatterBuilder;"
        let builder = RVal.obj(ObjInstance(dexType: descriptor, isHost: true))
        _ = try invoke(bridge, vm, descriptor, "<init>", "()V", [builder])
        let field = try XCTUnwrap(bridge.staticFields["Ljava/time/temporal/ChronoField;->YEAR"])
        XCTAssertThrowsError(try invoke(
            bridge, vm, descriptor, "parseDefaulting",
            "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, field, .long(2024)]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected unsupported date sequence")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/UnsupportedOperationException;")
        }
        _ = try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, HostBridge.string("dd'rd' MMMM")]
        )
        _ = try invoke(
            bridge, vm, descriptor, "parseDefaulting",
            "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, field, .long(2024)]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, HostBridge.string(", yyyy")]
        )) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected unsupported date sequence")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/UnsupportedOperationException;")
        }
        let locale = try XCTUnwrap(bridge.staticFields["Ljava/util/Locale;->ENGLISH"])
        let formatter = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        XCTAssertEqual(try dateYear(bridge, vm, "23rd August", formatter), 2024)
    }

    func testFormatterBuilderBoundsEveryAppendAndDoesNotMutateOnRejection() throws {
        let (vm, bridge) = try makeVM()
        let descriptor = "Ljava/time/format/DateTimeFormatterBuilder;"
        let builder = RVal.obj(ObjInstance(dexType: descriptor, isHost: true))
        _ = try invoke(bridge, vm, descriptor, "<init>", "()V", [builder])
        _ = try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, HostBridge.string("yyyy.")]
        )
        for badPattern in [String(repeating: "M", count: 252), "'unterminated"] {
            XCTAssertThrowsError(try invoke(
                bridge, vm, descriptor, "appendPattern",
                "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
                [builder, HostBridge.string(badPattern)]
            )) { error in
                guard let throwable = error as? DEXThrowable,
                      case let .obj(object) = throwable.value else {
                    return XCTFail("expected bounded IllegalArgumentException")
                }
                XCTAssertEqual(object.dexType, "Ljava/lang/IllegalArgumentException;")
            }
        }
        _ = try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, HostBridge.string("MM.dd")]
        )
        let locale = try XCTUnwrap(bridge.staticFields["Ljava/util/Locale;->ENGLISH"])
        let formatter = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        XCTAssertEqual(try dateYear(bridge, vm, "2026.08.23", formatter), 2026)
    }

    func testDateWithoutYearRequiresDefaultAndRejectsInvalidDefaultAtParse() throws {
        let (vm, bridge) = try makeVM()
        let descriptor = "Ljava/time/format/DateTimeFormatterBuilder;"
        let builder = RVal.obj(ObjInstance(dexType: descriptor, isHost: true))
        _ = try invoke(bridge, vm, descriptor, "<init>", "()V", [builder])
        _ = try invoke(
            bridge, vm, descriptor, "appendPattern",
            "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, HostBridge.string("dd'rd' MMMM")]
        )
        let locale = try XCTUnwrap(bridge.staticFields["Ljava/util/Locale;->ENGLISH"])
        let formatter = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        let field = try XCTUnwrap(bridge.staticFields["Ljava/time/temporal/ChronoField;->YEAR"])
        _ = try invoke(
            bridge, vm, descriptor, "parseDefaulting",
            "(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;",
            [builder, field, .long(Int64.max)]
        )
        let invalidDefault = try invoke(
            bridge, vm, descriptor, "toFormatter",
            "(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;", [builder, locale]
        )
        for value in [formatter, invalidDefault] {
            XCTAssertThrowsError(try dateYear(bridge, vm, "23rd August", value)) { error in
                guard let throwable = error as? DEXThrowable,
                      case let .obj(object) = throwable.value else {
                    return XCTFail("expected DateTimeParseException")
                }
                XCTAssertEqual(object.dexType, "Ljava/time/format/DateTimeParseException;")
            }
        }
    }

    func testSiblingPreservesTextNodeOrElementPayloadAndNullAtEnd() throws {
        let (vm, bridge) = try makeVM()
        let document = try invoke(
            bridge, vm, "Lorg/jsoup/Jsoup;", "parseBodyFragment",
            "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            [HostBridge.string("<p><b>Author</b>: Test Author<span>value</span><i id='last'>last</i></p>"), HostBridge.string("https://foolslide.test/")],
            isStatic: true
        )
        func select(_ selector: String) throws -> RVal {
            try invoke(
                bridge, vm, "Lorg/jsoup/nodes/Document;", "selectFirst",
                "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [document, HostBridge.string(selector)]
            )
        }
        let text = try invoke(
            bridge, vm, "Lorg/jsoup/nodes/Element;", "nextSibling",
            "()Lorg/jsoup/nodes/Node;", [select("b")]
        )
        XCTAssertEqual(try string(invoke(
            bridge, vm, "Lorg/jsoup/nodes/TextNode;", "text", "()Ljava/lang/String;", [text]
        )), ": Test Author")
        let element = try invoke(
            bridge, vm, "Lorg/jsoup/nodes/Element;", "nextSibling",
            "()Lorg/jsoup/nodes/Node;", [select("span")]
        )
        XCTAssertEqual(try string(invoke(
            bridge, vm, "Lorg/jsoup/nodes/Element;", "attr",
            "(Ljava/lang/String;)Ljava/lang/String;", [element, HostBridge.string("id")]
        )), "last")
        let absent = try invoke(
            bridge, vm, "Lorg/jsoup/nodes/Element;", "nextSibling",
            "()Lorg/jsoup/nodes/Node;", [element]
        )
        XCTAssertTrue(absent.isNull)
    }

    func testCreatedDetachedAnchorResolvesBaseURLAndReplacesAttributeCaseInsensitively() throws {
        let (vm, bridge) = try makeVM()
        let document = try invoke(
            bridge, vm, "Lorg/jsoup/Jsoup;", "parseBodyFragment",
            "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            [HostBridge.string("<p>existing</p>"), HostBridge.string("https://foolslide.test/read/alpha/")],
            isStatic: true
        )
        let anchor = try invoke(
            bridge, vm, "Lorg/jsoup/nodes/Document;", "createElement",
            "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;", [document, HostBridge.string("a")]
        )
        for (key, value) in [("href", "old.jpg"), ("HREF", "/images/001.jpg")] {
            let returned = try invoke(
                bridge, vm, "Lorg/jsoup/nodes/Element;", "attr",
                "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
                [anchor, HostBridge.string(key), HostBridge.string(value)]
            )
            sameObject(returned, anchor)
        }
        XCTAssertEqual(try string(invoke(
            bridge, vm, "Lorg/jsoup/nodes/Element;", "absUrl",
            "(Ljava/lang/String;)Ljava/lang/String;", [anchor, HostBridge.string("href")]
        )), "https://foolslide.test/images/001.jpg")
        let markup = try string(invoke(
            bridge, vm, "Lorg/jsoup/nodes/Document;", "toString", "()Ljava/lang/String;", [document]
        ))
        XCTAssertTrue(markup.contains("<p>existing</p>"))
        XCTAssertFalse(markup.contains("001.jpg"))
    }

    func testLastOrNullSelectsFinalListValueAndHandlesEmptyList() throws {
        let (vm, bridge) = try makeVM()
        let list = try invoke(
            bridge, vm, "Lkotlin/collections/CollectionsKt;", "listOf",
            "([Ljava/lang/Object;)Ljava/util/List;", [.arr(ArrInstance(
                elemDescriptor: "Ljava/lang/Object;",
                elements: [HostBridge.string("first"), .null, HostBridge.string("last")]
            ))], isStatic: true
        )
        XCTAssertEqual(try string(invoke(
            bridge, vm, "Lkotlin/collections/CollectionsKt;", "lastOrNull",
            "(Ljava/util/List;)Ljava/lang/Object;", [list], isStatic: true
        )), "last")
        let empty = try invoke(
            bridge, vm, "Lkotlin/collections/CollectionsKt;", "lastOrNull",
            "(Ljava/util/List;)Ljava/lang/Object;", [HostBridge.emptyListValue()], isStatic: true
        )
        XCTAssertTrue(empty.isNull)
    }

    func testRequestRewritePreservesCacheTagsAndUnrelatedHeaders() throws {
        let (vm, bridge) = try makeVM()
        let url = "https://foolslide.test/read/alpha/en/0/1/"
        let original = RVal.obj(ObjInstance(
            dexType: "Lokhttp3/Request;",
            fields: ["test-tag": HostBridge.string("retained")],
            payload: CompatHTTPRequest(
                url: url,
                headers: [
                    CompatHTTPHeader(name: "Adult", value: "true"),
                    CompatHTTPHeader(name: "adult", value: "false"),
                    CompatHTTPHeader(name: "Origin", value: "https://foolslide.test"),
                ],
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ), isHost: true
        ))
        let builder = try invoke(
            bridge, vm, "Lokhttp3/Request;", "newBuilder", "()Lokhttp3/Request$Builder;", [original]
        )
        sameObject(try invoke(
            bridge, vm, "Lokhttp3/Request$Builder;", "removeHeader",
            "(Ljava/lang/String;)Lokhttp3/Request$Builder;", [builder, HostBridge.string("ADULT")]
        ), builder)
        let form = CompatHTTPRequestBody.form(fields: [CompatHTTPFormField(name: "adult", value: "true")])
        let body = RVal.obj(ObjInstance(dexType: "Lokhttp3/FormBody;", payload: form, isHost: true))
        sameObject(try invoke(
            bridge, vm, "Lokhttp3/Request$Builder;", "method",
            "(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;",
            [builder, HostBridge.string("POST"), body]
        ), builder)
        let built = try invoke(
            bridge, vm, "Lokhttp3/Request$Builder;", "build", "()Lokhttp3/Request;", [builder]
        )
        guard case let .obj(object) = built else { return XCTFail("expected request") }
        XCTAssertEqual(object.payload as? CompatHTTPRequest, CompatHTTPRequest(
            url: url, method: "POST",
            headers: [CompatHTTPHeader(name: "Origin", value: "https://foolslide.test")],
            body: form, cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        ))
        XCTAssertEqual(try string(try XCTUnwrap(object.fields["test-tag"])), "retained")
        _ = try invoke(
            bridge, vm, "Lokhttp3/Request$Builder;", "method",
            "(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;",
            [builder, HostBridge.string("GET"), .null]
        )
        let reset = try invoke(
            bridge, vm, "Lokhttp3/Request$Builder;", "build", "()Lokhttp3/Request;", [builder]
        )
        guard case let .obj(resetObject) = reset else { return XCTFail("expected request") }
        XCTAssertEqual((resetObject.payload as? CompatHTTPRequest)?.method, "GET")
        XCTAssertNil((resetObject.payload as? CompatHTTPRequest)?.body)
    }
}
