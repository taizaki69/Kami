import Foundation
import XCTest
@testable import KamiCore

final class ReaderControlsTests: XCTestCase, @unchecked Sendable {
    func testOldPreferencesKeepDefaultsAndNewFieldsRoundTrip() throws {
        let old = Data(#"{"mode":"rightToLeft","background":"white","keepScreenAwake":false,"prefetchPages":99,"webtoonGap":-4}"#.utf8)
        let settings = try JSONDecoder().decode(ReaderSettings.self, from: old)
        XCTAssertEqual(settings.mode, .rightToLeft)
        XCTAssertEqual(settings.pageFit, .fitPage)
        XCTAssertEqual(settings.taps, .init())
        XCTAssertFalse(settings.trimBorders)
        XCTAssertFalse(settings.overrideBrightness)
        XCTAssertEqual(settings.prefetchPages, 8)
        XCTAssertEqual(settings.webtoonGap, 0)
        let custom = ReaderSettings(pageFit: .fitWidth, trimBorders: true,
                                    taps: .init(left: .nextPage, center: .none, right: .toggleControls),
                                    overrideBrightness: true, brightness: 0.72)
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertThrowsError(try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"pageFit":"guess"}"#.utf8)))
    }

    func testNonfiniteAndOutOfRangePreferencesNormalizeBeforeUIUse() {
        for value in [Double.nan, .infinity, -.infinity] {
            let settings = ReaderSettings(webtoonGap: value, brightness: value)
            XCTAssertEqual(settings.webtoonGap, 0)
            XCTAssertEqual(settings.brightness, 0.5)
        }
        XCTAssertEqual(ReaderSettings(brightness: -2).brightness, 0.05)
        XCTAssertEqual(ReaderSettings(brightness: 4).brightness, 1)
    }

    func testAutomaticTapsRespectDirectionAndExactZoneBoundaries() {
        let taps = ReaderTapConfiguration()
        for mode in [ReaderMode.leftToRight, .rightToLeft] {
            XCTAssertEqual(taps.action(at: 0, mode: mode), mode == .leftToRight ? .previousPage : .nextPage)
            XCTAssertEqual(taps.action(at: 0.249, mode: mode), mode == .leftToRight ? .previousPage : .nextPage)
            XCTAssertEqual(taps.action(at: 1, mode: mode), mode == .leftToRight ? .nextPage : .previousPage)
            for fraction in [0.25, 0.5, 0.75] { XCTAssertEqual(taps.action(at: fraction, mode: mode), .toggleControls) }
        }
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(taps.action(at: fraction, mode: .webtoon), .toggleControls)
        }
        for fraction in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertEqual(taps.action(at: fraction, mode: .leftToRight), .none)
        }
    }

    func testExplicitTapActionsArePhysicalAndApplyToWebtoon() {
        let taps = ReaderTapConfiguration(left: .nextPage, center: .none, right: .previousPage)
        for mode in ReaderMode.allCases {
            XCTAssertEqual(taps.action(at: 0.1, mode: mode), .nextPage)
            XCTAssertEqual(taps.action(at: 0.5, mode: mode), .none)
            XCTAssertEqual(taps.action(at: 0.9, mode: mode), .previousPage)
        }
    }

    func testFitWholePageVersusWidthAndBoundedBasePanning() {
        let whole = ReaderPageLayout(imageWidth: 800, imageHeight: 2400, viewportWidth: 400, viewportHeight: 600, fit: .fitPage)
        XCTAssertEqual(whole.width, 200); XCTAssertEqual(whole.height, 600)
        XCTAssertFalse(whole.canPan(scale: 1))
        let width = ReaderPageLayout(imageWidth: 800, imageHeight: 2400, viewportWidth: 400, viewportHeight: 600, fit: .fitWidth)
        XCTAssertEqual(width.width, 400); XCTAssertEqual(width.height, 1200)
        XCTAssertEqual(width.initialOffset, .init(x: 0, y: 300))
        XCTAssertTrue(width.canPan(scale: 1))
        XCTAssertEqual(width.boundedOffset(.init(x: 20, y: -999), scale: 1), .init(x: 0, y: -300))
    }

    func testFitHeightStartsAtReadingEdgeAndZoomPreservesTheTappedContentPoint() {
        let ltr = ReaderPageLayout(imageWidth: 1800, imageHeight: 600, viewportWidth: 400, viewportHeight: 600, fit: .fitHeight)
        let rtl = ReaderPageLayout(imageWidth: 1800, imageHeight: 600, viewportWidth: 400, viewportHeight: 600, fit: .fitHeight, rightToLeft: true)
        XCTAssertEqual(ltr.initialOffset.x, 700); XCTAssertEqual(rtl.initialOffset.x, -700)
        let zoomed = ltr.zoomedOffset(.init(x: 200, y: 0), from: 1, to: 2.5, anchor: .init(x: 50, y: 30))
        XCTAssertEqual(zoomed.x, 425); XCTAssertEqual(zoomed.y, -45)
        XCTAssertEqual((50 - zoomed.x) / 2.5, 50 - 200)
        XCTAssertEqual(ltr.zoomedOffset(zoomed, from: 2.5, to: 1, anchor: .init(x: 50, y: 30)), .init(x: 200, y: 0))
        XCTAssertEqual(ltr.boundedOffset(.init(x: .nan, y: .infinity), scale: 2), .init())
    }

    func testInvalidGeometryAndScaleNeverProduceUnboundedFrames() {
        for value in [Double.nan, .infinity, 0, -1, Double.leastNonzeroMagnitude] {
            let plan = ReaderPageLayout(imageWidth: value, imageHeight: 10, viewportWidth: 400, viewportHeight: 600, fit: .fitWidth)
            XCTAssertEqual(plan.width, 0); XCTAssertEqual(plan.height, 0)
        }
        XCTAssertEqual(ReaderPageLayout.normalizedScale(.infinity), 1)
        XCTAssertEqual(ReaderPageLayout.normalizedScale(100), 5)
        let huge = ReaderPageLayout(imageWidth: 1, imageHeight: 10, viewportWidth: Double.greatestFiniteMagnitude, viewportHeight: 600, fit: .fitWidth)
        XCTAssertEqual(huge.height, 0)
    }

    func testPrefetchWindowDoesNotOverflowNearIntegerLimit() {
        XCTAssertEqual(ReaderPrefetchPlan.indexes(pageCount: Int.max, currentIndex: Int.max - 2, ahead: 8),
                       [Int.max - 1, Int.max - 3])
    }

    private func raster(background: UInt8, transparent: Bool = false) -> Data {
        var bytes = [UInt8](repeating: background, count: 40 * 32 * 4)
        for y in 0..<32 { for x in 0..<40 {
            let i = (y * 40 + x) * 4
            bytes[i + 3] = transparent ? 0 : 255
            if (8..<30).contains(x), (6..<25).contains(y) {
                bytes[i] = 80; bytes[i + 1] = 100; bytes[i + 2] = 120; bytes[i + 3] = 255
            }
        } }
        return Data(bytes)
    }

    func testUniformWhiteBlackAndTransparentBordersPreservePaddingAndContent() throws {
        for data in [raster(background: 255), raster(background: 0), raster(background: 0, transparent: true)] {
            let crop = try ReaderBorderCrop.detectRGBA(data, width: 40, height: 32)
            XCTAssertEqual(crop, ReaderPixelCrop(x: 6, y: 4, width: 26, height: 23))
            XCTAssertLessThan(crop.x, 8); XCTAssertGreaterThan(crop.x + crop.width, 30)
            XCTAssertLessThan(crop.y, 6); XCTAssertGreaterThan(crop.y + crop.height, 25)
        }
    }

    func testBlankAndMixedCornerPagesRemainWhole() throws {
        let full = ReaderPixelCrop(x: 0, y: 0, width: 40, height: 32)
        XCTAssertEqual(try ReaderBorderCrop.detectRGBA(Data(repeating: 255, count: 40 * 32 * 4), width: 40, height: 32), full)
        var mixed = raster(background: 255); mixed[0] = 0
        XCTAssertEqual(try ReaderBorderCrop.detectRGBA(mixed, width: 40, height: 32), full)
        var edge = raster(background: 255)
        // A real edge mark stops removal on that edge; it isn't a uniform border.
        for x in 0..<12 { edge[(12 * 40 + x) * 4] = 100 }
        XCTAssertEqual(try ReaderBorderCrop.detectRGBA(edge, width: 40, height: 32).x, 0)
    }

    func testCropRasterLimitsAndCancellation() async throws {
        for (w, h, data) in [(0, 1, Data()), (513, 1, Data()), (1, Int.max, Data()), (2, 2, Data([0]))] {
            XCTAssertThrowsError(try ReaderBorderCrop.detectRGBA(data, width: w, height: h)) {
                XCTAssertEqual($0 as? ReaderBorderCropError, .invalidRaster)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReaderBorderCrop.detectRGBA(Data(repeating: 255, count: 512 * 512 * 4), width: 512, height: 512)
        }
        do { _ = try await task.value; XCTFail("Cancelled crop succeeded") } catch is CancellationError { }
    }
}
