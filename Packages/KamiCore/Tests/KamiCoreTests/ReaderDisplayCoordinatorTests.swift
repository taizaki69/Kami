import Foundation
import XCTest
@testable import KamiCore

@MainActor
private final class ReaderScreenFixture {
    var idle = false
    var brightness = [1: 0.8, 2: 0.7]
    var writes: [(Int, Double)] = []
    var quantize = false
    lazy var coordinator = ReaderDisplayCoordinator<Int>(
        readIdle: { [unowned self] in idle }, writeIdle: { [unowned self] in idle = $0 },
        readBrightness: { [unowned self] in brightness[$0] },
        writeBrightness: { [unowned self] screen, value in
            writes.append((screen, value)); brightness[screen] = quantize ? (value * 10).rounded() / 10 : value
        })
}

final class ReaderDisplayCoordinatorTests: XCTestCase, @unchecked Sendable {
    @MainActor func testClosingOneReaderCannotEnableSleepWhileAnotherNeedsAwake() async {
        for reverse in [false, true] {
            let f = ReaderScreenFixture(), a = UUID(), b = UUID()
            f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: nil)
            f.coordinator.update(id: b, screen: 1, keepAwake: true, brightness: nil)
            f.coordinator.remove(id: reverse ? b : a); XCTAssertTrue(f.idle)
            f.coordinator.remove(id: reverse ? a : b); XCTAssertFalse(f.idle)
            f.coordinator.remove(id: a); XCTAssertFalse(f.idle)
        }
    }

    @MainActor func testKeepAwakePreservesExistingAndExternalOwnership() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.idle = true
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: nil)
        f.coordinator.update(id: b, screen: 1, keepAwake: false, brightness: nil)
        f.coordinator.remove(id: a); XCTAssertTrue(f.idle)
        f.coordinator.remove(id: b); XCTAssertTrue(f.idle)
        f.idle = false
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: nil)
        f.idle = false // an external owner reenabled sleep
        f.coordinator.remove(id: a); XCTAssertFalse(f.idle)
    }

    @MainActor func testNewestBrightnessWinsAndUnrelatedRendersDoNotStealPriority() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.update(id: b, screen: 1, keepAwake: false, brightness: 0.3)
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.5)
        XCTAssertEqual(f.brightness[1], 0.3)
        f.coordinator.remove(id: b); XCTAssertEqual(f.brightness[1], 0.5)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.8)
        XCTAssertEqual(f.writes.map(\.1), [0.5, 0.3, 0.5, 0.8])
    }

    @MainActor func testRemovingInactivePriorityReaderDoesNotChangeWinningBrightness() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.update(id: b, screen: 1, keepAwake: true, brightness: 0.3)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.3)
        f.coordinator.remove(id: b); XCTAssertEqual(f.brightness[1], 0.8)
    }

    @MainActor func testSystemBrightnessChangeIsNotFoughtAndLatestValueIsRestored() async {
        let f = ReaderScreenFixture(), a = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.brightness[1] = 0.6
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.5)
        XCTAssertEqual(f.brightness[1], 0.6)
        XCTAssertEqual(f.writes.count, 1)
        f.brightness[1] = 0.7
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.4)
        XCTAssertEqual(f.brightness[1], 0.4)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.7)
    }

    @MainActor func testSystemChangeImmediatelyBeforeCloseRemainsIntact() async {
        let f = ReaderScreenFixture(), a = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.brightness[1] = 0.9
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.9)
        XCTAssertEqual(f.writes.count, 1)
    }

    @MainActor func testClosingWinnerAfterSystemChangeDoesNotResurrectOlderOverride() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.update(id: b, screen: 1, keepAwake: true, brightness: 0.3)
        f.brightness[1] = 0.9
        f.coordinator.remove(id: b)
        XCTAssertEqual(f.brightness[1], 0.9)
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.5)
        XCTAssertEqual(f.brightness[1], 0.9)
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.6)
        XCTAssertEqual(f.brightness[1], 0.6)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.9)
    }

    @MainActor func testNewReaderCanOverrideSystemChangeWithoutRevivingSupersededReaders() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.brightness[1] = 0.9
        f.coordinator.update(id: b, screen: 1, keepAwake: true, brightness: 0.4)
        XCTAssertEqual(f.brightness[1], 0.4)
        f.coordinator.remove(id: b); XCTAssertEqual(f.brightness[1], 0.9)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.9)
    }

    @MainActor func testScreenMovementAndReactivationRestoreEachScreenIndependently() async {
        let f = ReaderScreenFixture(), a = UUID(), b = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.update(id: b, screen: 2, keepAwake: true, brightness: 0.4)
        f.coordinator.update(id: a, screen: 2, keepAwake: true, brightness: 0.3)
        XCTAssertEqual(f.brightness[1], 0.8); XCTAssertEqual(f.brightness[2], 0.3)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[2], 0.4)
        f.coordinator.remove(id: b); XCTAssertEqual(f.brightness[2], 0.7); XCTAssertFalse(f.idle)
        f.brightness[1] = 0.9
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.9)
    }

    @MainActor func testTurningOverrideOffRestoresOnceAndKeepsOtherEffects() async {
        let f = ReaderScreenFixture(), a = UUID()
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: 0.5)
        f.coordinator.update(id: a, screen: 1, keepAwake: true, brightness: nil)
        XCTAssertEqual(f.brightness[1], 0.8); XCTAssertTrue(f.idle)
        f.coordinator.remove(id: a); f.coordinator.remove(id: a)
        XCTAssertEqual(f.writes.count, 2); XCTAssertFalse(f.idle)
    }

    @MainActor func testQuantizedOutputsAndUnavailableScreensDoNotInventBaselines() async {
        let f = ReaderScreenFixture(), a = UUID()
        f.quantize = true
        f.coordinator.update(id: a, screen: 1, keepAwake: false, brightness: 0.53)
        XCTAssertEqual(f.brightness[1], 0.5)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[1], 0.8)
        f.brightness[2] = .nan
        f.coordinator.update(id: a, screen: 2, keepAwake: false, brightness: 0.5)
        XCTAssertEqual(f.writes.count, 2)
        f.brightness[2] = 0.7
        f.coordinator.update(id: a, screen: 2, keepAwake: false, brightness: 0.5)
        f.coordinator.remove(id: a); XCTAssertEqual(f.brightness[2], 0.7)
    }
}
