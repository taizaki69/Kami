import Foundation
import XCTest
@testable import KamiCore

final class ReaderImageRenderingTests: XCTestCase {
    func testLongPageRetainsReadingWidthInsteadOfA4096PixelHeightCap() throws {
        let plan = try XCTUnwrap(ReaderImageDecodePlan(width: 1_000, height: 16_000,
                                                      ordinaryMaximumDimension: 4_096, memoryConstrained: false))
        XCTAssertTrue(plan.isLongPage)
        XCTAssertEqual(plan.maximumPixelDimension, 16_000)
        XCTAssertEqual(plan.maximumDecodedPixels, 16_777_216)
        let pressure = try XCTUnwrap(ReaderImageDecodePlan(width: 1_000, height: 16_000,
                                                          ordinaryMaximumDimension: 4_096, memoryConstrained: true))
        XCTAssertGreaterThan(pressure.maximumPixelDimension, 8_000)
        XCTAssertLessThan(pressure.maximumPixelDimension, 8_200)
        XCTAssertEqual(pressure.maximumDecodedPixels, 4_194_304)
    }

    func testOrdinaryPagesRetainExistingResolutionAndPressureLimits() throws {
        for (constrained, expected) in [(false, 6_144), (true, 2_048)] {
            let plan = try XCTUnwrap(ReaderImageDecodePlan(width: 8_000, height: 8_000,
                                                          ordinaryMaximumDimension: 6_144, memoryConstrained: constrained))
            XCTAssertFalse(plan.isLongPage)
            XCTAssertEqual(plan.maximumPixelDimension, expected)
        }
        let tiny = try XCTUnwrap(ReaderImageDecodePlan(width: 32, height: 16, ordinaryMaximumDimension: 4_096,
                                                      memoryConstrained: false))
        XCTAssertEqual(tiny.maximumPixelDimension, 32)
    }

    func testLongPageBudgetIncludesDecoderRoundingAndBothOrientations() throws {
        for (width, height) in [(1, 100_000), (313, 99_999), (1_001, 30_007), (2_499, 100_000), (512, 2_048)] {
            for constrained in [false, true] {
                let plan = try XCTUnwrap(ReaderImageDecodePlan(width: width, height: height,
                                                              ordinaryMaximumDimension: 4_096, memoryConstrained: constrained))
                let rotated = try XCTUnwrap(ReaderImageDecodePlan(width: height, height: width,
                                                                 ordinaryMaximumDimension: 4_096, memoryConstrained: constrained))
                XCTAssertEqual(plan, rotated)
                let shorter = Int(ceil(Double(width) * Double(plan.maximumPixelDimension) / Double(height)))
                XCTAssertLessThanOrEqual(shorter * plan.maximumPixelDimension, plan.maximumDecodedPixels)
                XCTAssertLessThanOrEqual(plan.maximumPixelDimension, 65_536)
            }
        }
    }

    func testInvalidSourceDimensionsFailBeforeAnyDecode() {
        for (width, height) in [(0, 1), (-1, 50), (1, Int.max), (100_001, 1), (20_000, 20_000)] {
            XCTAssertNil(ReaderImageDecodePlan(width: width, height: height,
                                              ordinaryMaximumDimension: Int.max, memoryConstrained: false))
        }
    }

    func testTileMapsTheVisibleRegionWithInterpolationOverlap() throws {
        let plan = try XCTUnwrap(ReaderImageTilePlan(imageWidth: 1_000, imageHeight: 16_000,
                                                    surface: CGSize(width: 500, height: 8_000),
                                                    clip: CGRect(x: 0, y: 4_000, width: 500, height: 256)))
        XCTAssertEqual(plan.source, CGRect(x: 0, y: 7_999, width: 1_000, height: 514))
        XCTAssertEqual(plan.destination, CGRect(x: 0, y: 3_999.5, width: 500, height: 257))
        XCTAssertEqual(plan.clip, CGRect(x: 0, y: 4_000, width: 500, height: 256))
        XCTAssertLessThan(plan.source.height, 1_024)
    }

    func testTileClipsPartialEdgesAndAdjacentTilesKeepIdenticalMapping() throws {
        let surface = CGSize(width: 333, height: 5_328)
        let top = try XCTUnwrap(ReaderImageTilePlan(imageWidth: 1_000, imageHeight: 16_000, surface: surface,
                                                   clip: CGRect(x: -10, y: -10, width: 510, height: 266)))
        XCTAssertEqual(top.clip, CGRect(x: 0, y: 0, width: 333, height: 256))
        let next = try XCTUnwrap(ReaderImageTilePlan(imageWidth: 1_000, imageHeight: 16_000, surface: surface,
                                                    clip: CGRect(x: 0, y: 256, width: 333, height: 256)))
        XCTAssertGreaterThan(top.source.maxY, next.source.minY)
        XCTAssertEqual(top.destination.height / top.source.height, next.destination.height / next.source.height,
                       accuracy: 0.000_001)
        let bottom = try XCTUnwrap(ReaderImageTilePlan(imageWidth: 1_000, imageHeight: 16_000, surface: surface,
                                                      clip: CGRect(x: 0, y: 5_120, width: 512, height: 256)))
        XCTAssertEqual(bottom.source.maxY, 16_000)
        XCTAssertEqual(bottom.clip.maxY, 5_328)
    }

    func testEmptyOffscreenOrNonFiniteTileCannotReachCoreGraphics() {
        for clip in [CGRect.zero, CGRect(x: 0, y: 300, width: 100, height: 100),
                     CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)] {
            XCTAssertNil(ReaderImageTilePlan(imageWidth: 100, imageHeight: 200,
                                            surface: CGSize(width: 100, height: 200), clip: clip))
        }
        XCTAssertNil(ReaderImageTilePlan(imageWidth: 100, imageHeight: 200,
                                        surface: CGSize(width: CGFloat.nan, height: 200), clip: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
}
