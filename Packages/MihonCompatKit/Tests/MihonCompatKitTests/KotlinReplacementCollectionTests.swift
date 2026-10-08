import Foundation
import XCTest
@testable import MihonCompatKit

final class KotlinReplacementCollectionTests: XCTestCase {
    private func replace(_ pattern: String, _ input: String, _ replacement: String,
                         limit: Int = 1024, matches: Int = 10_000) throws -> String {
        try KotlinRegexReplacement.replace(expression: NSRegularExpression(pattern: pattern),
            input: input, replacement: replacement, maximumBytes: limit, maximumMatches: matches,
            cancelled: { false })
    }

    func testReplacementReferencesEscapesAndUnmatchedGroups() throws {
        XCTAssertEqual(try replace(#"\s+"#, "Chapter\t  2\nTitle", " "), "Chapter 2 Title")
        XCTAssertEqual(try replace("(a)(b)?", "a ab", "$0:$2:$12:$01"), "a::a2:a ab:b:a2:a")
        XCTAssertEqual(try replace("(a)", "a", #"\$1 \\ \q $1"#), #"$1 \ q a"#)
        XCTAssertEqual(try replace("(?<word>a)(?<optional>b)?", "a ab", "${optional}-${word}"), "-a b-a")
        XCTAssertEqual(try replace("(😀)", "x😀y", "$1$1"), "x😀😀y")
        XCTAssertEqual(try replace("a", "a\u{301}", "o"), "o\u{301}")
        XCTAssertEqual(try replace("(?=.)|$", "ab", "-"), "-a-b-")
        XCTAssertEqual(try replace("a", "xyz", "$"), "xyz", "JVM validates a template on the first match")
    }

    func testNamedGroupValidationSkipsQuotedClassesCommentsAndScopedFlags() throws {
        XCTAssertEqual(try replace(#"\Q(?<fake>x)\E(?<real>a)?"#, "(?<fake>x)", "${real}"), "")
        XCTAssertThrowsError(try replace(#"\Q(?<fake>x)\E"#, "(?<fake>x)", "${fake}"))
        XCTAssertThrowsError(try replace("[(?<fake>)]", "<", "${fake}"))
        XCTAssertThrowsError(try replace("(?x)# (?<fake>x)\n(?<real>a)", "a", "${fake}"))
        XCTAssertEqual(try replace("(?x:(?<first>a) # comment\n)(?<last>b)", "ab", "${last}${first}"), "ba")
        XCTAssertEqual(try replace("(?x:(?-x:#))(?<real>a)", "#a", "${real}"), "a")
        for template in ["$", "\\", "$x", "${}", "${1x}", "${absent}", "${word", "${wo_rd}"] {
            XCTAssertThrowsError(try replace("(?<word>a)", "a", template), template)
        }
        XCTAssertThrowsError(try replace("(a)", "a", "$2")) {
            guard case KotlinRegexReplacement.Failure.missingGroup = $0 else { return XCTFail("\($0)") }
        }
    }

    func testReplacementBoundsAndCancellationNeverReturnPartialOutput() throws {
        XCTAssertThrowsError(try replace("a", "aaaa", "1234", limit: 8))
        XCTAssertThrowsError(try replace("a", "aaa", "", matches: 2))
        XCTAssertThrowsError(try replace("a", "long input", "", limit: 4))
        XCTAssertThrowsError(try replace("a", "a", "long replacement", limit: 4))
        XCTAssertThrowsError(try replace(String(repeating: "()", count: 128), "", ""))
        var checks = 0
        XCTAssertThrowsError(try KotlinRegexReplacement.replace(expression: NSRegularExpression(pattern: "."),
            input: "abcdefghij", replacement: "x", maximumBytes: 32, cancelled: {
                checks += 1
                return checks >= 3
            })) { guard case VMError.cancelled = $0 else { return XCTFail("\($0)") } }
        XCTAssertGreaterThanOrEqual(checks, 3)
    }

    func testReversedListIsReadOnlyAndObservesOriginalMutationsAndRepeatedReversals() throws {
        var builder = DexBuilder()
        builder.setClass("LReversedTest;")
        builder.addMethod(.init(name: "noop", registers: 0, ins: 0, outs: 0, insns: [0x000e], isStatic: true))
        let bridge = HostBridge.minimal()
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        func call(_ type: String, _ name: String, _ proto: String, _ args: [RVal], _ statik: Bool = false) throws -> RVal {
            try XCTUnwrap(bridge.resolve(class: type, name, prototype: proto, isStatic: statik))(vm, args)
        }
        let list = try XCTUnwrap(bridge.objectFactories["Ljava/util/ArrayList;"])(vm)
        func add(_ target: RVal, _ text: String) throws {
            _ = try call("Ljava/util/List;", "add", "(Ljava/lang/Object;)Z", [target, HostBridge.string(text)])
        }
        func reverse(_ target: RVal) throws -> RVal {
            try call("Lkotlin/collections/CollectionsKt;", "asReversed", "(Ljava/util/List;)Ljava/util/List;", [target], true)
        }
        func values(_ target: RVal) throws -> [String] {
            guard case let .int(count) = try call("Ljava/util/List;", "size", "()I", [target]) else { throw VMError.verify("size") }
            return try (0..<count).map { vmStringValue(try call("Ljava/util/List;", "get", "(I)Ljava/lang/Object;", [target, .int($0)])) }
        }
        let view = try reverse(list)
        XCTAssertEqual(try values(view), [])
        try add(list, "one"); try add(list, "two")
        XCTAssertEqual(try values(view), ["two", "one"])
        XCTAssertThrowsError(try add(view, "forbidden"))
        let twice = try reverse(view)
        XCTAssertEqual(try values(twice), ["one", "two"])
        XCTAssertThrowsError(try add(twice, "still read-only"))
        _ = try call("Ljava/util/List;", "remove", "(Ljava/lang/Object;)Z", [list, HostBridge.string("one")])
        XCTAssertEqual(try values(view), ["two"])
        try add(list, "three")
        XCTAssertEqual(try values(twice), ["two", "three"])
        var many = view
        for _ in 0..<2_000 { many = try reverse(many) }
        XCTAssertEqual(try values(many), ["three", "two"])
        let copy = try call("Lkotlin/collections/CollectionsKt;", "toMutableList", "(Ljava/util/Collection;)Ljava/util/List;", [view], true)
        try add(copy, "copy")
        XCTAssertEqual(try values(list), ["two", "three"])

        let regex = try XCTUnwrap(bridge.objectFactories["Lkotlin/text/Regex;"])(vm)
        _ = try call("Lkotlin/text/Regex;", "<init>", "(Ljava/lang/String;)V", [regex, HostBridge.string("(a)")])
        XCTAssertEqual(vmStringValue(try call("Lkotlin/text/Regex;", "replace", "(Ljava/lang/CharSequence;Ljava/lang/String;)Ljava/lang/String;", [regex, HostBridge.string("a"), HostBridge.string("$1$1")])), "aa")
        XCTAssertThrowsError(try call("Lkotlin/text/Regex;", "replace", "(Ljava/lang/CharSequence;Ljava/lang/String;)Ljava/lang/String;", [regex, HostBridge.string("a"), HostBridge.string("$2")])) {
            guard let thrown = $0 as? DEXThrowable, case let .obj(object) = thrown.value else { return XCTFail("\($0)") }
            XCTAssertEqual(object.dexType, "Ljava/lang/IndexOutOfBoundsException;")
        }
    }

    func testSubstringDirectionUsesLiteralUTF16AndDefaultMissingValue() throws {
        var builder = DexBuilder()
        builder.setClass("LSubstringTest;")
        builder.addMethod(.init(name: "noop", registers: 0, ins: 0, outs: 0, insns: [0x000e], isStatic: true))
        let bridge = HostBridge.minimal()
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        func substring(_ name: String, _ input: String, _ delimiter: String, missing: RVal = .null, mask: Int32 = 2) throws -> String {
            vmStringValue(try XCTUnwrap(bridge.resolve(class: "Lkotlin/text/StringsKt;", name + "$default",
                prototype: "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;", isStatic: true))(
                    vm, [HostBridge.string(input), HostBridge.string(delimiter), missing, .int(mask), .null]))
        }
        XCTAssertEqual(try substring("substringAfter", "/genre/action", "/"), "genre/action")
        XCTAssertEqual(try substring("substringAfterLast", "/genre/action", "/"), "action")
        XCTAssertEqual(try substring("substringBeforeLast", "/genre/action", "/"), "/genre")
        XCTAssertEqual(try substring("substringAfterLast", "a", ""), "")
        XCTAssertEqual(try substring("substringBeforeLast", "a", ""), "a")
        XCTAssertEqual(try substring("substringAfter", "a", ""), "a")
        XCTAssertEqual(try substring("substringAfterLast", "é", "e\u{301}"), "é")
        XCTAssertEqual(try substring("substringAfterLast", "a\u{301}b", "a"), "\u{301}b")
        XCTAssertEqual(try substring("substringAfterLast", "😀/x", "😀"), "/x")
        XCTAssertEqual(try substring("substringAfterLast", "x", "/", missing: HostBridge.string("missing"), mask: 0), "missing")
    }
}
