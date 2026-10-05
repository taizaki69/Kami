import Foundation
import XCTest
@testable import KamiCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class LibraryBackupFileReaderTests: XCTestCase {
    func testReadsExactBytesAtLimitAndRejectsExcessBeforeReturningData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-File-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json")
        let data = Data([0, 1, 2, 255])
        try data.write(to: url)
        XCTAssertEqual(try LibraryBackupFileReader.read(url, policy: .init(maximumInputBytes: 4)), data)
        XCTAssertThrowsError(try LibraryBackupFileReader.read(url, policy: .init(maximumInputBytes: 3))) {
            XCTAssertEqual($0 as? LibraryBackupFileError, .tooLarge)
        }
        XCTAssertThrowsError(try LibraryBackupFileReader.read(directory)) {
            XCTAssertEqual($0 as? LibraryBackupFileError, .notRegularFile)
        }
        XCTAssertThrowsError(try LibraryBackupFileReader.read(URL(string: "https://fixture.invalid/backup")!)) {
            XCTAssertEqual($0 as? LibraryBackupFileError, .notRegularFile)
        }
    }

    func testCancellationDoesNotReturnPartialBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-File-\(UUID()).json")
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryBackupFileReader.read(url)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    #if canImport(Darwin) || canImport(Glibc)
    func testLinksAndFIFOsCannotEscapeRegularFileAcquisitionOrBlockWaitingForAWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-File-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        try Data("fixture".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LibraryBackupFileReader.read(link))
        let fifo = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        XCTAssertThrowsError(try LibraryBackupFileReader.read(fifo)) {
            XCTAssertEqual($0 as? LibraryBackupFileError, .notRegularFile)
        }
    }
    #endif
}
