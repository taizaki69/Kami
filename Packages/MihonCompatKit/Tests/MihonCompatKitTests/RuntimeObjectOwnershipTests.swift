import XCTest
@testable import MihonCompatKit

final class RuntimeObjectOwnershipTests: XCTestCase {
    func testRetirementCollectsCyclesButDoesNotMutateValuesCreatedOutsideSession() throws {
        let outside = ObjInstance(dexType: "LOutside;", payload: "retained")
        outside.fields["self"] = .obj(outside)
        defer { outside.fields.removeAll() }
        let owner = RuntimeObjectOwnership()
        weak var weakObject: ObjInstance?
        weak var weakArray: ArrInstance?
        try owner.perform {
            let object = ObjInstance(dexType: "LOwned;", payload: outside)
            let array = ArrInstance(elemDescriptor: "Ljava/lang/Object;", elements: [.obj(object)])
            object.fields["array"] = .arr(array)
            weakObject = object; weakArray = array
        }
        XCTAssertNotNil(weakObject); XCTAssertNotNil(weakArray)
        owner.retire()
        XCTAssertNil(weakObject); XCTAssertNil(weakArray)
        XCTAssertEqual(outside.payload as? String, "retained")
        XCTAssertTrue(outside.fields["self"]! === .obj(outside))
        XCTAssertThrowsError(try owner.perform { 1 })
        owner.retire() // Retirement is idempotent.
    }

    func testOwnershipIsWeakForAcyclicValuesAndRetiresLongChainsWithoutRecursion() throws {
        let owner = RuntimeObjectOwnership()
        weak var simple: ObjInstance?
        try owner.perform {
            let value = ObjInstance(dexType: "LSimple;")
            simple = value
            XCTAssertNotNil(simple)
        }
        XCTAssertNil(simple)
        weak var root: ObjInstance?
        try owner.perform {
            var head = ObjInstance(dexType: "LNode;")
            let tail = head
            for _ in 0..<10_000 { head = ObjInstance(dexType: "LNode;", fields: ["next": .obj(head)]) }
            tail.fields["cycle"] = .obj(head)
            root = head
        }
        XCTAssertNotNil(root)
        owner.retire()
        XCTAssertNil(root)
    }

    func testBridgeRetirementBreaksRegistrationCycles() throws {
        let owner = RuntimeObjectOwnership()
        weak var weakBridge: HostBridge?
        var bridge: HostBridge? = try owner.perform { HostBridge.minimal() }
        weakBridge = bridge
        owner.retire()
        bridge?.retire()
        bridge = nil
        XCTAssertNil(weakBridge)
    }

    func testObjectGuardStopsActualDEXCycleAllocation() throws {
        var builder = DexBuilder()
        let type = builder.type("LNode;")
        let field = builder.field(classDescriptor: "LNode;", name: "next", typeDescriptor: "LNode;")
        let objectInit = builder.method(classDescriptor: "Ljava/lang/Object;", name: "<init>")
        builder.setClass("LNode;", superclass: "Ljava/lang/Object;", fields: [("next", "LNode;")])
        let nodeInit = builder.addMethod(.init(name: "<init>", registers: 1, ins: 1, outs: 1,
            insns: [0x1070, UInt16(objectInit), 0x0000, 0x000e], isStatic: false))
        builder.addMethod(.init(name: "run", registers: 1, ins: 0, outs: 1,
            insns: [0x0022, UInt16(type), 0x1070, UInt16(nodeInit), 0x0000,
                    0x005b, UInt16(field), 0xf928], isStatic: true))
        let bridge = HostBridge.minimal()
        defer { bridge.retire() }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge, maxInstructions: 1_000)
        let owner = RuntimeObjectOwnership(maximumObjects: 8)
        defer { owner.retire() }
        XCTAssertThrowsError(try owner.perform {
            try vm.call(classDescriptor: "LNode;", method: "run", args: [])
        }) {
            guard case VMError.verify("retired or oversized source object session") = $0 else { return XCTFail("\($0)") }
        }
    }

    func testIndependentOwnershipContextsSurviveAsyncSuspension() async throws {
        let first = RuntimeObjectOwnership(), second = RuntimeObjectOwnership()
        let a = Task {
            try await first.perform {
                let object = ObjInstance(dexType: "LA;")
                await Task.yield()
                XCTAssertTrue(RuntimeObjectOwnership.current === first)
                object.fields["self"] = .obj(object)
                return object
            }
        }
        let b = Task {
            try await second.perform {
                let object = ObjInstance(dexType: "LB;")
                await Task.yield()
                XCTAssertTrue(RuntimeObjectOwnership.current === second)
                object.fields["self"] = .obj(object)
                return object
            }
        }
        let firstValue = try await a.value, secondValue = try await b.value
        first.retire()
        XCTAssertTrue(firstValue.fields.isEmpty)
        XCTAssertFalse(secondValue.fields.isEmpty)
        second.retire()
        XCTAssertTrue(secondValue.fields.isEmpty)
        XCTAssertNil(RuntimeObjectOwnership.current)
    }
}
