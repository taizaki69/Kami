import Foundation
import XCTest
@testable import KamiCore

final class ExtensionAPKFileReaderTests: XCTestCase {
    func testBoundedReaderReturnsTheExactBufferAcrossMultipleChunks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = (0..<150_000).map { UInt8($0 % 251) }
        try Data(bytes).write(to: file, options: .atomic)
        XCTAssertEqual(try ExtensionAPKFileReader.read(path: file.path, maximumBytes: bytes.count), bytes)
    }

    func testSparseOversizedAPKIsRejectedWithoutReadingItsContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try ExtensionAPKFileReader.read(path: file.path)) { error in
            guard let readError = error as? ExtensionAPKFileReader.ReadError,
                  case .tooLarge = readError else {
                return XCTFail("expected the byte limit rejection")
            }
        }
    }

    func testDirectoriesMissingPathsAndNonpositiveLimitsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["", directory.path, directory.appendingPathComponent("missing").path] {
            XCTAssertThrowsError(try ExtensionAPKFileReader.read(path: path))
        }
        let file = directory.appendingPathComponent("empty.apk")
        try Data().write(to: file)
        XCTAssertThrowsError(try ExtensionAPKFileReader.read(path: file.path, maximumBytes: 0))
        XCTAssertEqual(try ExtensionAPKFileReader.read(path: file.path), [])
    }
}
