import XCTest
@testable import MihonCompatKit

final class HostReferenceHierarchyTests: XCTestCase {
    private func runtime() throws -> (DexInterpreter, HostBridge) {
        var builder = DexBuilder()
        builder.setClass("LHostReferenceTest;")
        for (name, target) in [
            ("asNode", "Lorg/jsoup/nodes/Node;"),
            ("asElement", "Lorg/jsoup/nodes/Element;"),
            ("asField", "Ljava/time/temporal/TemporalField;"),
            ("asEnum", "Ljava/lang/Enum;"),
        ] {
            let index = UInt16(builder.type(target))
            builder.addMethod(.init(
                name: name, registers: 1, ins: 1, outs: 0,
                insns: [0x001f, index, 0x0011], // check-cast v0; return-object v0
                isStatic: true, returnType: target, parameters: ["Ljava/lang/Object;"]
            ))
        }
        let leafIndex = UInt16(builder.type("Lorg/jsoup/nodes/LeafNode;"))
        builder.addMethod(.init(
            name: "isLeaf", registers: 2, ins: 1, outs: 0,
            insns: [0x1020, leafIndex, 0x000f], // instance-of v0,v1; return v0
            isStatic: true, returnType: "I", parameters: ["Ljava/lang/Object;"]
        ))
        let bridge = HostBridge.minimal()
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(
        _ bridge: HostBridge, _ vm: DexInterpreter, owner: String,
        name: String, prototype: String, isStatic: Bool = false, args: [RVal]
    ) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(
            class: owner, name, prototype: prototype, isStatic: isStatic
        ))
        return try method(vm, args)
    }

    private func call(_ vm: DexInterpreter, _ name: String, _ value: RVal) throws -> RVal {
        try vm.call(classDescriptor: "LHostReferenceTest;", method: name, args: [value])
    }

    private func assertSameObject(_ actual: RVal, _ expected: RVal,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case let .obj(actualObject) = actual, case let .obj(expectedObject) = expected else {
            return XCTFail("expected object identity", file: file, line: line)
        }
        XCTAssertTrue(actualObject === expectedObject, file: file, line: line)
    }

    private func assertClassCast(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let thrown = error as? DEXThrowable, case let .obj(object) = thrown.value else {
            return XCTFail("expected typed class-cast failure", file: file, line: line)
        }
        XCTAssertEqual(object.dexType, "Ljava/lang/ClassCastException;", file: file, line: line)
    }

    func testRealHostDOMValuesSurviveDEXNodeCastsAndRejectSiblingCategoryCast() throws {
        let (vm, bridge) = try runtime()
        let document = try invoke(bridge, vm, owner: "Lorg/jsoup/Jsoup;", name: "parseBodyFragment",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
            isStatic: true, args: [HostBridge.string("<p><b>Author</b> Writer</p>"),
                                  HostBridge.string("https://fixtures.example")])
        let element = try invoke(bridge, vm, owner: "Lorg/jsoup/nodes/Document;", name: "selectFirst",
            prototype: "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
            args: [document, HostBridge.string("b")])
        let text = try invoke(bridge, vm, owner: "Lorg/jsoup/nodes/Element;", name: "nextSibling",
            prototype: "()Lorg/jsoup/nodes/Node;", args: [element])
        for value in [document, element, text] {
            assertSameObject(try call(vm, "asNode", value), value)
        }
        guard case .int(1) = try call(vm, "isLeaf", text),
              case .int(0) = try call(vm, "isLeaf", element) else {
            return XCTFail("DEX must distinguish text leaves from elements")
        }
        XCTAssertThrowsError(try call(vm, "asElement", text)) { assertClassCast($0) }
        XCTAssertThrowsError(try call(vm, "asNode", HostBridge.string("unrelated"))) { assertClassCast($0) }
    }

    func testRealChronoFieldCrossesDEXTemporalInterfaceCastWithoutAcceptingUnrelatedObjects() throws {
        let (vm, bridge) = try runtime()
        let year = try XCTUnwrap(bridge.staticFields["Ljava/time/temporal/ChronoField;->YEAR"])
        assertSameObject(try call(vm, "asField", year), year)
        assertSameObject(try call(vm, "asEnum", year), year)
        XCTAssertThrowsError(try call(vm, "asField", HostBridge.string("YEAR"))) { assertClassCast($0) }
    }
}
