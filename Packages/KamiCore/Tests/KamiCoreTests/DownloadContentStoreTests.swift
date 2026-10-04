import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DownloadContentStoreTests: XCTestCase {
    /// File safety and publication tests use opaque fixture payloads. Real
    /// image validation is covered separately by ImageIO tests on Apple.
    private struct FixtureValidator: DownloadImageValidating {
        func validate(_ data: Data) async throws {
            guard data.first == 0xAA else { throw DownloadImageValidationError.invalidImage }
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KamiDownloadTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func policy(pageBytes: Int = 64, chapterBytes: Int64 = 1_024,
                        quota: Int64 = 32_768, pages: Int = 8) -> DownloadPolicy {
        .init(maximumPageCount: pages, maximumPageBytes: pageBytes,
              maximumChapterBytes: chapterBytes, quotaBytes: quota,
              freeSpaceFloorBytes: 0, maximumManifestBytes: 4_096, maximumJobs: 16)
    }

    private func identity(attemptID: UUID = UUID(), chapterID: Int64 = 2) -> DownloadContentIdentity {
        .init(jobID: UUID(), attemptID: attemptID, mangaID: 1, chapterID: chapterID,
              sourceID: MangaDexSource().id,
              mangaURLDigest: APKSignatureVerifier.apkSHA256(Array("/manga".utf8)),
              chapterURLDigest: APKSignatureVerifier.apkSHA256(Array("/chapter".utf8)))
    }

    private func publish(_ store: DownloadContentStore, identity: DownloadContentIdentity,
                         pages: [Data] = [Data([0xAA, 1]), Data([0xAA, 2])]) async throws -> DownloadManifestReceipt {
        try await store.begin(identity: identity)
        for (ordinal, data) in pages.enumerated() {
            try await store.reservePage(identity: identity)
            _ = try await store.writePage(identity: identity, ordinal: ordinal, data: data)
        }
        let manifest = try await store.prepare(identity: identity)
        try await store.publish(receipt: manifest)
        return manifest
    }

    func testPublishedChapterReopensWithoutSourceOrNetworkAndRetainsPageOrder() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        let manifest = try await publish(store, identity: id)
        let reopened = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        let lease = try await reopened.open(identity: id, manifestSHA256: manifest.manifestSHA256)
        XCTAssertEqual(lease.pages.map(\.ordinal), [0, 1])
        let first = try await lease.readPage(ordinal: 0)
        let second = try await lease.readPage(ordinal: 1)
        XCTAssertEqual(first, Data([0xAA, 1]))
        XCTAssertEqual(second, Data([0xAA, 2]))
        await lease.close()
        await lease.close()
        do { _ = try await lease.readPage(ordinal: 0); XCTFail("Closed lease must not replay bytes") }
        catch { XCTAssertEqual(error as? DownloadContentError, .leaseClosed) }
        let usage = try await reopened.usage()
        XCTAssertGreaterThan(usage.storedBytes, 4, "Manifest bytes count toward the quota")
        XCTAssertEqual(usage.stagingBytes, 0)
        XCTAssertEqual(usage.reservedBytes, 0)
    }

    func testUnpublishedPagesCannotBeOpenedAndRecoveryDoesNotPromoteRenamedOrphans() async throws {
        let location = try root(), firstID = identity(), otherID = identity(chapterID: 3)
        let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        let completed = try await publish(store, identity: firstID)
        try await store.begin(identity: otherID)
        try await store.reservePage(identity: otherID)
        _ = try await store.writePage(identity: otherID, ordinal: 0, data: Data([0xAA, 3]))
        let prepared = try await store.prepare(identity: otherID)
        do { _ = try await store.open(identity: otherID, manifestSHA256: prepared.manifestSHA256); XCTFail("Staging is not readable") }
        catch { XCTAssertEqual(error as? DownloadContentError, .notFound) }
        try await store.publish(receipt: prepared)
        // Simulate a crash before the final DB completion CAS: only the first
        // identity came from a durable finished lookup.
        let restarted = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        try await restarted.reconcile(keeping: [firstID.attemptID])
        try await restarted.reconcile(keeping: [firstID.attemptID])
        do { _ = try await restarted.open(identity: otherID, manifestSHA256: prepared.manifestSHA256); XCTFail("Orphan must not resurrect") }
        catch { XCTAssertEqual(error as? DownloadContentError, .notFound) }
        let lease = try await restarted.open(identity: firstID, manifestSHA256: completed.manifestSHA256)
        let page = try await lease.readPage(ordinal: 0)
        XCTAssertEqual(page, Data([0xAA, 1]))
        await lease.close()
    }

    func testCancellationDuringValidationCannotWriteLatePage() async throws {
        let entered = expectation(description: "Image validation entered")
        let validator = GatedValidator(entered: entered)
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(), validator: validator)
        try await store.begin(identity: id)
        try await store.reservePage(identity: id)
        let write = Task { try await store.writePage(identity: id, ordinal: 0, data: Data([0xAA])) }
        await fulfillment(of: [entered], timeout: 2)
        let removed = try await store.remove(identity: id)
        XCTAssertEqual(removed, .removed)
        await validator.release()
        do { _ = try await write.value; XCTFail("Removed attempt cannot accept late validation") }
        catch { XCTAssertEqual(error as? DownloadContentError, .attemptUnavailable) }
        let usage = try await store.usage()
        XCTAssertEqual(usage.totalBytes, 0)
        XCTAssertEqual(usage.reservedBytes, 0)
    }

    private actor GatedValidator: DownloadImageValidating {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(entered: XCTestExpectation) { self.entered = entered }
        func validate(_ data: Data) async throws {
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testDeletionWaitsForReadersBlocksNewLeasesAndCleansAfterLastClose() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        let manifest = try await publish(store, identity: id)
        let first = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256)
        let second = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256)
        let waiting = try await store.remove(identity: id)
        XCTAssertEqual(waiting, .waitingForReaders)
        do { _ = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256); XCTFail("Tombstone blocks new readers") }
        catch { XCTAssertEqual(error as? DownloadContentError, .pendingDeletion) }
        await first.close()
        let page = try await second.readPage(ordinal: 1)
        XCTAssertEqual(page, Data([0xAA, 2]))
        let retained = try await store.usage()
        XCTAssertGreaterThan(retained.totalBytes, 0)
        await second.close()
        let cleared = try await store.usage()
        XCTAssertEqual(cleared.totalBytes, 0)
        let again = try await store.remove(identity: id)
        XCTAssertEqual(again, .removed)
    }

    func testIdentityManifestPageHashAndCompleteFileSetAreVerified() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        let manifest = try await publish(store, identity: id)
        let wrong = identity(attemptID: id.attemptID, chapterID: 99)
        do { _ = try await store.open(identity: wrong, manifestSHA256: manifest.manifestSHA256); XCTFail("Identity binding is required") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidManifest) }
        do { _ = try await store.open(identity: id, manifestSHA256: String(repeating: "0", count: 64)); XCTFail("DB digest is required") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidManifest) }
        let bundle = location.appendingPathComponent("bundles/\(id.attemptID.uuidString)")
        let lease = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256)
        try Data([0xAA, 9]).write(to: bundle.appendingPathComponent("p000000.bin"))
        do { _ = try await lease.readPage(ordinal: 0); XCTFail("Same-sized corruption must not be displayed") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidManifest) }
        do { try await store.publish(receipt: manifest); XCTFail("Idempotent publication must recheck stored pages") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidManifest) }
        await lease.close()
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("p000001.bin"))
        do { _ = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256); XCTFail("Missing page must fail before opening") }
        catch { XCTAssertEqual(error as? DownloadContentError, .incompleteChapter) }
    }

    func testRecoveryCleansInternalPublicationLinksLeftByInterruptedRenameProtocol() async throws {
        for parent in ["staging", "bundles"] {
            for name in ["p000000.bin", "manifest.json"] {
                let location = try root(), id = identity()
                let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
                _ = try await publish(store, identity: id)
                let bundle = location.appendingPathComponent("bundles/\(id.attemptID.uuidString)")
                let directory = location.appendingPathComponent("\(parent)/\(id.attemptID.uuidString)")
                if parent == "staging" { try FileManager.default.moveItem(at: bundle, to: directory) }
                let file = directory.appendingPathComponent(name)
                let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
                // This is the on-disk state after linkat succeeds and before
                // unlinkat removes the temporary name. Both links are owned.
                XCTAssertEqual(link(file.path, temporary.path), 0)
                let reopened = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
                try await reopened.reconcile(keeping: [])
                let usage = try await reopened.usage()
                XCTAssertEqual(usage.totalBytes, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
        }
    }

    func testPageOrderValidationAndReservationsDoNotPublishPartialCatalogs() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(pages: 2), validator: FixtureValidator())
        try await store.begin(identity: id)
        do { _ = try await store.prepare(identity: id); XCTFail("No pages is not a chapter") }
        catch { XCTAssertEqual(error as? DownloadContentError, .incompleteChapter) }
        do { _ = try await store.writePage(identity: id, ordinal: 0, data: Data([0xAA])); XCTFail("Reserve before transfer") }
        catch { XCTAssertEqual(error as? DownloadContentError, .reservationRequired) }
        try await store.reservePage(identity: id)
        do { _ = try await store.writePage(identity: id, ordinal: 1, data: Data([0xAA])); XCTFail("Missing ordinal zero") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidPageOrder) }
        do { _ = try await store.writePage(identity: id, ordinal: 0, data: Data("<html>".utf8)); XCTFail("Validator must run before writes") }
        catch { XCTAssertEqual(error as? DownloadImageValidationError, .invalidImage) }
        _ = try await store.writePage(identity: id, ordinal: 0, data: Data([0xAA]))
        try await store.reservePage(identity: id)
        _ = try await store.writePage(identity: id, ordinal: 1, data: Data([0xAA, 1]))
        do { try await store.reservePage(identity: id); XCTFail("Page count is bounded") }
        catch { XCTAssertEqual(error as? DownloadContentError, .invalidPageOrder) }
        let manifest = try await store.prepare(identity: id)
        XCTAssertEqual(manifest.pages.count, 2)
        XCTAssertEqual(manifest.totalBytes, 3)
    }

    func testQuotaIncludesManifestStagingReservationsAndOrphansOnReopen() async throws {
        let location = try root(), id = identity()
        let constrained = policy(pageBytes: 64, quota: 4_160)
        let store = try DownloadContentStore(root: location, policy: constrained, validator: FixtureValidator())
        try await store.begin(identity: id)
        try await store.reservePage(identity: id)
        let reserved = try await store.usage()
        XCTAssertEqual(reserved.reservedBytes, 4_160)
        do { try await store.begin(identity: identity(chapterID: 3)); XCTFail("Concurrent reservations cannot overbook disk") }
        catch { XCTAssertEqual(error as? DownloadContentError, .quotaExceeded) }
        _ = try await store.writePage(identity: id, ordinal: 0, data: Data(repeating: 0xAA, count: 64))
        do { try await store.reservePage(identity: id); XCTFail("Stored bytes and next page both count") }
        catch { XCTAssertEqual(error as? DownloadContentError, .quotaExceeded) }
        let reopened = try DownloadContentStore(root: location, policy: constrained, validator: FixtureValidator())
        let orphaned = try await reopened.usage()
        XCTAssertEqual(orphaned.stagingBytes, 64)
        try await reopened.reconcile(keeping: [])
        let cleaned = try await reopened.usage()
        XCTAssertEqual(cleaned.totalBytes, 0)
    }

    func testOversizedPagesAndChapterLimitDoNotModifyStoredBytes() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(pageBytes: 4, chapterBytes: 5), validator: FixtureValidator())
        try await store.begin(identity: id)
        try await store.reservePage(identity: id)
        do { _ = try await store.writePage(identity: id, ordinal: 0, data: Data(repeating: 0xAA, count: 5)); XCTFail("Per-page bound") }
        catch { XCTAssertEqual(error as? DownloadContentError, .imageTooLarge) }
        _ = try await store.writePage(identity: id, ordinal: 0, data: Data(repeating: 0xAA, count: 4))
        try await store.reservePage(identity: id)
        do { _ = try await store.writePage(identity: id, ordinal: 1, data: Data([0xAA, 1])); XCTFail("Per-chapter bound") }
        catch { XCTAssertEqual(error as? DownloadContentError, .chapterTooLarge) }
        let usage = try await store.usage()
        XCTAssertEqual(usage.stagingBytes, 4)
    }

    func testSymlinksHardlinksAndFIFOsAreRejectedWithoutFollowingOutsideRoot() async throws {
        for kind in ["symlink", "hardlink", "fifo"] {
            let location = try root(), id = identity()
            let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
            let manifest = try await publish(store, identity: id)
            let sentinel = location.appendingPathComponent("outside-sentinel")
            try Data([0xAA, 1]).write(to: sentinel)
            let page = location.appendingPathComponent("bundles/\(id.attemptID.uuidString)/p000000.bin")
            try FileManager.default.removeItem(at: page)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: page, withDestinationURL: sentinel)
            case "hardlink": try FileManager.default.linkItem(at: sentinel, to: page)
            default: XCTAssertEqual(mkfifo(page.path, mode_t(0o600)), 0)
            }
            do { _ = try await store.open(identity: id, manifestSHA256: manifest.manifestSHA256); XCTFail("Unsafe file must not open: \(kind)") }
            catch { XCTAssertEqual(error as? DownloadContentError, .unsafeFile) }
            do { _ = try await store.remove(identity: id); XCTFail("Unsafe cleanup must remain visible") }
            catch { XCTAssertEqual(error as? DownloadContentError, .unsafeFile) }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([0xAA, 1]))
        }
    }

    func testUnknownCleanupEntriesAndDirectoryLinksPreserveSentinels() async throws {
        let location = try root(), id = identity()
        let store = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        _ = try await publish(store, identity: id)
        let bundle = location.appendingPathComponent("bundles/\(id.attemptID.uuidString)")
        let extra = bundle.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: extra)
        do { _ = try await store.remove(identity: id); XCTFail("Do not recursively delete unknown files") }
        catch { XCTAssertEqual(error as? DownloadContentError, .unsafeFile) }
        XCTAssertEqual(try String(contentsOf: extra), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("p000000.bin").path))
        let outside = try root()
        let link = location.appendingPathComponent("staging/\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let restarted = try DownloadContentStore(root: location, policy: policy(), validator: FixtureValidator())
        do { try await restarted.reconcile(keeping: [id.attemptID]); XCTFail("Directory link must not be followed") }
        catch { XCTAssertEqual(error as? DownloadContentError, .unsafeFile) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
