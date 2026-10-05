import XCTest
@testable import KamiCore

final class ReaderImageResidencyTests: XCTestCase {
    func testPressureDropsPagedNeighborsInBothDirections() {
        for mode in [ReaderMode.leftToRight, .rightToLeft] {
            XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 250, mode: mode,
                                                        visiblePages: [0, 499], memoryConstrained: false), [249, 250, 251])
            XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 250, mode: mode,
                                                        visiblePages: [0, 499], memoryConstrained: true), [250])
        }
    }

    func testWebtoonKeepsEveryVisiblePageButReleasesLazyOffscreenPages() {
        XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 249, mode: .webtoon,
                                                    visiblePages: [248, 249, 250], memoryConstrained: false),
                       [247, 248, 249, 250, 251])
        XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 249, mode: .webtoon,
                                                    visiblePages: [248, 249, 250], memoryConstrained: true),
                       [248, 249, 250])
    }

    func testProgrammaticJumpRemainsLoadableBeforeViewportGeometryArrives() {
        XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 499, mode: .webtoon,
                                                    memoryConstrained: true), [499])
        XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 500, currentIndex: 499, mode: .webtoon,
                                                    visiblePages: [0, 1], memoryConstrained: true), [0, 1, 499])
    }

    func testInvalidGeometryAndChapterBoundariesNeverProduceInvalidOrdinals() {
        for pressure in [false, true] {
            XCTAssertEqual(ReaderImageResidency.indexes(pageCount: 1, currentIndex: 0, mode: .webtoon,
                                                        visiblePages: [-1, Int.min, 1, Int.max], memoryConstrained: pressure), [0])
            for (count, current) in [(0, 0), (-1, 0), (3, -1), (3, 3)] {
                XCTAssertTrue(ReaderImageResidency.indexes(pageCount: count, currentIndex: current,
                                                          mode: .webtoon, visiblePages: [0], memoryConstrained: pressure).isEmpty)
            }
        }
        XCTAssertEqual(ReaderImageResidency.indexes(pageCount: Int.max, currentIndex: Int.max - 1,
                                                    mode: .leftToRight, memoryConstrained: false), [Int.max - 2, Int.max - 1])
    }
}
