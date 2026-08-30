import XCTest
@testable import MihonCompatKit

final class ArrayListToArrayTests: XCTestCase {
    private func makeVM() throws -> (DexInterpreter, HostBridge) {
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
        let bridge = HostBridge.minimal()
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(
        _ bridge: HostBridge,
        _ vm: DexInterpreter,
        class descriptor: String,
        _ name: String,
        prototype: String,
        args: [RVal]
    ) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(
            class: descriptor,
            name,
            prototype: prototype,
            isStatic: false
        ))
        return try method(vm, args)
    }

    private func makeArrayList(_ bridge: HostBridge, vm: DexInterpreter) throws -> RVal {
        let factory = try XCTUnwrap(bridge.objectFactories["Ljava/util/ArrayList;"])
        return try factory(vm)
    }

    private func add(_ value: RVal, to list: RVal, bridge: HostBridge, vm: DexInterpreter) throws {
        _ = try invoke(
            bridge,
            vm,
            class: "Ljava/util/ArrayList;",
            "add",
            prototype: "(Ljava/lang/Object;)Z",
            args: [list, value]
        )
    }

    private func toArray(
        _ destination: ArrInstance,
        list: RVal,
        bridge: HostBridge,
        vm: DexInterpreter
    ) throws -> RVal {
        try invoke(
            bridge,
            vm,
            class: "Ljava/util/ArrayList;",
            "toArray",
            prototype: "([Ljava/lang/Object;)[Ljava/lang/Object;",
            args: [list, .arr(destination)]
        )
    }

    private func stringValue(_ value: RVal) -> String? {
        guard case let .obj(object) = value,
              object.dexType == "Ljava/lang/String;" else { return nil }
        return object.payload as? String
    }

    func testToArrayThrowsArrayStoreExceptionBeforeMutatingDestination() throws {
        let (vm, bridge) = try makeVM()
        let list = try makeArrayList(bridge, vm: vm)
        try add(HostBridge.string("compatible"), to: list, bridge: bridge, vm: vm)
        try add(
            .obj(ObjInstance(
                dexType: "Ljava/lang/Integer;",
                payload: Int32(7),
                isHost: true
            )),
            to: list,
            bridge: bridge,
            vm: vm
        )

        let destination = ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [
                HostBridge.string("before-0"),
                HostBridge.string("before-1"),
                HostBridge.string("before-2"),
            ]
        )
        XCTAssertThrowsError(try toArray(destination, list: list, bridge: bridge, vm: vm)) { error in
            guard let thrown = error as? DEXThrowable,
                  case let .obj(object) = thrown.value else {
                return XCTFail("expected DEX ArrayStoreException, got \(error)")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/ArrayStoreException;")
        }
        XCTAssertEqual(destination.elements.compactMap(stringValue), ["before-0", "before-1", "before-2"])
    }

    func testToArrayRejectsUnknownReferenceBeforeMutatingDestination() throws {
        let (vm, bridge) = try makeVM()
        let list = try makeArrayList(bridge, vm: vm)
        try add(
            .obj(ObjInstance(dexType: "Lexternal/UnknownValue;", isHost: true)),
            to: list,
            bridge: bridge,
            vm: vm
        )
        let destination = ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [HostBridge.string("before")]
        )

        XCTAssertThrowsError(try toArray(destination, list: list, bridge: bridge, vm: vm)) { error in
            guard let thrown = error as? DEXThrowable,
                  case let .obj(object) = thrown.value else {
                return XCTFail("expected DEX ArrayStoreException, got \(error)")
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/ArrayStoreException;")
        }
        XCTAssertEqual(stringValue(destination.elements[0]), "before")
    }

    func testToArrayStoresCompatibleReferencesAndNullAndClearsOnlySentinel() throws {
        let (vm, bridge) = try makeVM()
        let list = try makeArrayList(bridge, vm: vm)
        try add(HostBridge.string("value"), to: list, bridge: bridge, vm: vm)
        try add(.null, to: list, bridge: bridge, vm: vm)

        let destination = ArrInstance(
            elemDescriptor: "Ljava/lang/String;",
            elements: [
                HostBridge.string("before-0"),
                HostBridge.string("before-1"),
                HostBridge.string("sentinel"),
                HostBridge.string("untouched"),
            ]
        )
        guard case let .arr(result) = try toArray(destination, list: list, bridge: bridge, vm: vm) else {
            return XCTFail("expected typed array result")
        }
        XCTAssertTrue(result === destination)
        XCTAssertEqual(stringValue(result.elements[0]), "value")
        XCTAssertTrue(result.elements[1].isNull)
        XCTAssertTrue(result.elements[2].isNull)
        XCTAssertEqual(stringValue(result.elements[3]), "untouched")
    }

    func testToArrayRejectsPrimitiveArrayDestinations() throws {
        let primitiveCases: [(String, RVal)] = [
            ("I", .int(7)),
            ("J", .long(8)),
            ("F", .float(9)),
            ("D", .double(10)),
        ]

        for (componentDescriptor, value) in primitiveCases {
            let (vm, bridge) = try makeVM()
            let list = try makeArrayList(bridge, vm: vm)
            try add(value, to: list, bridge: bridge, vm: vm)
            let destination = ArrInstance(
                elemDescriptor: componentDescriptor,
                elements: []
            )

            XCTAssertThrowsError(try toArray(
                destination, list: list, bridge: bridge, vm: vm
            )) { error in
                guard let thrown = error as? DEXThrowable,
                      case let .obj(object) = thrown.value else {
                    return XCTFail("expected DEX ArrayStoreException, got \(error)")
                }
                XCTAssertEqual(object.dexType, "Ljava/lang/ArrayStoreException;")
            }
            XCTAssertTrue(destination.elements.isEmpty)
        }
    }
}
