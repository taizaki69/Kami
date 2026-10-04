import Foundation
import MihonCompatKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DownloadContentError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentity, invalidManifest, invalidPageOrder, incompleteChapter
    case imageTooLarge, chapterTooLarge, quotaExceeded, storageFull
    case storageUnavailable, unsafeFile, notFound, attemptUnavailable
    case reservationRequired, leaseClosed, pendingDeletion, tooManyReaders

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity, .invalidManifest: return "The saved chapter information is invalid."
        case .invalidPageOrder, .incompleteChapter: return "The downloaded chapter is incomplete."
        case .imageTooLarge: return "A page exceeds the download size limit."
        case .chapterTooLarge: return "This chapter exceeds the download size limit."
        case .quotaExceeded: return "The download storage limit has been reached."
        case .storageFull: return "There is not enough free space for this download."
        case .storageUnavailable, .reservationRequired: return "Download storage is unavailable."
        case .unsafeFile: return "The downloaded files could not be accessed safely."
        case .notFound: return "The downloaded files are missing."
        case .attemptUnavailable: return "This download attempt is no longer active."
        case .leaseClosed: return "This local reading session has closed."
        case .pendingDeletion: return "This chapter is being removed from downloads."
        case .tooManyReaders: return "Close another downloaded chapter before opening this one."
        }
    }
}

public struct DownloadManifestReceipt: Equatable, Sendable {
    public let identity: DownloadContentIdentity
    public let pages: [DownloadPageReceipt]
    public let totalBytes: Int64
    public let manifestSHA256: String

    public init(identity: DownloadContentIdentity, pages: [DownloadPageReceipt],
                totalBytes: Int64, manifestSHA256: String) {
        self.identity = identity
        self.pages = pages
        self.totalBytes = totalBytes
        self.manifestSHA256 = manifestSHA256
    }
}

public enum DownloadRemovalResult: Equatable, Sendable { case removed, waitingForReaders }

public struct DownloadStorageUsage: Equatable, Sendable {
    public let storedBytes: Int64
    public let stagingBytes: Int64
    public let reservedBytes: Int64
    public let quotaBytes: Int64
    public let freeSpaceBytes: Int64?
    public var totalBytes: Int64 { storedBytes + stagingBytes }
}

/// A complete local chapter is independent of extension execution. The owner
/// closes this lease when leaving the reader; deinit provides cleanup only as
/// a fallback. The store checks lease identity on every bounded page read.
public final class OfflineChapterLease: @unchecked Sendable {
    public let id: UUID
    public let identity: DownloadContentIdentity
    public let pages: [DownloadPageReceipt]
    private let store: DownloadContentStore

    fileprivate init(id: UUID, receipt: DownloadManifestReceipt, store: DownloadContentStore) {
        self.id = id
        self.identity = receipt.identity
        self.pages = receipt.pages
        self.store = store
    }

    public func readPage(ordinal: Int) async throws -> Data {
        try await store.readPage(leaseID: id, ordinal: ordinal)
    }

    public func close() async { await store.closeLease(id) }

    deinit {
        let store = store, id = id
        Task { await store.closeLease(id) }
    }
}

private final class DownloadDirectory: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { _ = close(fd) }
}

/// Filesystem half of the download publication protocol. SQLite remains the
/// authority for finished/cancelled state. Only open this store's bundle after
/// a finished DB lookup supplies its exact identity and manifest digest.
///
/// All content access is relative to anchored directory descriptors. Neither
/// a source URL nor a persisted filename is ever passed to the filesystem.
public actor DownloadContentStore {
    private struct Manifest: Codable {
        let version: Int
        let identity: DownloadContentIdentity
        let pages: [DownloadPageReceipt]
        let totalBytes: Int64
    }
    private struct Stage {
        let identity: DownloadContentIdentity
        var pages: [DownloadPageReceipt] = []
        var prepared: DownloadManifestReceipt?
    }
    private struct Inventory {
        var stored: Int64 = 0
        var staging: Int64 = 0
        var files = 0
    }
    private struct FileIdentity: Hashable {
        let device: String
        let inode: UInt64
    }

    public nonisolated let policy: DownloadPolicy
    private let rootPath: String
    private let root: DownloadDirectory
    private let staging: DownloadDirectory
    private let bundles: DownloadDirectory
    private let validator: any DownloadImageValidating
    private var stages: [UUID: Stage] = [:]
    private var reservations: [UUID: Int64] = [:]
    private var leases: [UUID: DownloadManifestReceipt] = [:]
    private var pendingRemoval: [UUID: DownloadContentIdentity] = [:]
    private var inventory: Inventory?
    private static let maximumManagedFiles = 100_000

    public init(root: URL, policy: DownloadPolicy = .init(),
                validator: any DownloadImageValidating = PlatformDownloadImageValidator()) throws {
        guard root.isFileURL, root.path != "/" else { throw DownloadContentError.unsafeFile }
        self.policy = policy
        self.validator = validator
        self.rootPath = root.path
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw DownloadContentError.storageUnavailable }
        #if canImport(Darwin)
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #else
        let rootFD = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #endif
        guard rootFD >= 0 else { throw DownloadContentError.unsafeFile }
        let ownedRoot = DownloadDirectory(rootFD)
        try Self.checkDirectory(rootFD)
        self.root = ownedRoot
        self.staging = try Self.childDirectory(rootFD, name: "staging", create: true)
        self.bundles = try Self.childDirectory(rootFD, name: "bundles", create: true)
        #if canImport(Darwin)
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try excludedRoot.setResourceValues(values) }
        catch { throw DownloadContentError.storageUnavailable }
        #endif
    }

    public func begin(identity: DownloadContentIdentity) throws {
        try Task.checkCancellation()
        try validate(identity)
        guard stages[identity.attemptID] == nil, pendingRemoval[identity.attemptID] == nil,
              try Self.optionalDirectory(staging.fd, name: key(identity)) == nil,
              try Self.optionalDirectory(bundles.fd, name: key(identity)) == nil else {
            throw DownloadContentError.attemptUnavailable
        }
        inventory = nil
        try ensureCapacity(additional: Int64(policy.maximumManifestBytes), additionalFiles: 1)
        _ = try Self.childDirectory(staging.fd, name: key(identity), create: true)
        try Self.flush(staging.fd)
        stages[identity.attemptID] = Stage(identity: identity)
        reservations[identity.attemptID] = Int64(policy.maximumManifestBytes)
    }

    /// Reserve before a network request. A single page's reservation is
    /// replaced by actual bytes only after its durable file write succeeds.
    public func reservePage(identity: DownloadContentIdentity) throws {
        try Task.checkCancellation()
        let stage = try activeStage(identity)
        guard stage.prepared == nil, stage.pages.count < policy.maximumPageCount else {
            throw DownloadContentError.invalidPageOrder
        }
        let desired = Int64(policy.maximumPageBytes) + Int64(policy.maximumManifestBytes)
        let previous = reservations[identity.attemptID] ?? 0
        try ensureCapacity(additional: max(0, desired - previous), additionalFiles: previous < desired ? 1 : 0)
        reservations[identity.attemptID] = desired
    }

    public func writePage(identity: DownloadContentIdentity, ordinal: Int, data: Data) async throws -> DownloadPageReceipt {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= policy.maximumPageBytes else { throw DownloadContentError.imageTooLarge }
        let before = try activeStage(identity)
        try checkPageWrite(before, ordinal: ordinal, bytes: data.count)
        try await validator.validate(data)
        try Task.checkCancellation()
        // ImageIO validation suspends. Cancel/removal or a competing append
        // may have changed the attempt while it was running.
        var stage = try activeStage(identity)
        try checkPageWrite(stage, ordinal: ordinal, bytes: data.count)
        let receipt = DownloadPageReceipt(ordinal: ordinal, byteCount: Int64(data.count), sha256: Self.digest(data))
        let dir = try Self.childDirectory(staging.fd, name: key(identity), create: false)
        do { try Self.writeExclusive(data, directory: dir.fd, name: pageName(ordinal)) }
        catch { inventory = nil; throw error }
        stage.pages.append(receipt)
        stages[identity.attemptID] = stage
        if var value = inventory {
            value.staging = try Self.add(value.staging, Int64(data.count))
            value.files += 1
            inventory = value
        }
        reservations[identity.attemptID] = Int64(policy.maximumManifestBytes)
        return receipt
    }

    public func prepare(identity: DownloadContentIdentity) throws -> DownloadManifestReceipt {
        try Task.checkCancellation()
        var stage = try activeStage(identity)
        if let prepared = stage.prepared { return prepared }
        guard !stage.pages.isEmpty else { throw DownloadContentError.incompleteChapter }
        let dir = try Self.childDirectory(staging.fd, name: key(identity), create: false)
        try checkFiles(dir.fd, pages: stage.pages, manifest: false, verifyHashes: true)
        let total = try stage.pages.reduce(Int64(0)) { try Self.add($0, $1.byteCount) }
        let manifest = Manifest(version: 1, identity: identity, pages: stage.pages, totalBytes: total)
        let data = try Self.encode(manifest)
        guard data.count <= policy.maximumManifestBytes else { throw DownloadContentError.invalidManifest }
        do { try Self.writeExclusive(data, directory: dir.fd, name: "manifest.json") }
        catch { inventory = nil; throw error }
        let receipt = DownloadManifestReceipt(identity: identity, pages: stage.pages,
                                               totalBytes: total, manifestSHA256: Self.digest(data))
        stage.prepared = receipt
        stages[identity.attemptID] = stage
        reservations.removeValue(forKey: identity.attemptID)
        inventory = nil
        return receipt
    }

    /// Rename only after the DB prepare CAS. A later failed DB completion CAS
    /// leaves an invisible bundle which the service removes or recovery cleans.
    public func publish(receipt: DownloadManifestReceipt) throws {
        try Task.checkCancellation()
        try validate(receipt.identity)
        guard pendingRemoval[receipt.identity.attemptID] == nil else { throw DownloadContentError.pendingDeletion }
        if let existing = try Self.optionalDirectory(bundles.fd, name: key(receipt.identity)) {
            guard try readManifest(existing.fd, identity: receipt.identity, digest: receipt.manifestSHA256) == receipt else {
                throw DownloadContentError.invalidManifest
            }
            try checkFiles(existing.fd, pages: receipt.pages, manifest: true, verifyHashes: true)
            return
        }
        let stage = try activeStage(receipt.identity)
        guard stage.prepared == receipt else { throw DownloadContentError.invalidManifest }
        let dir = try Self.childDirectory(staging.fd, name: key(receipt.identity), create: false)
        guard try readManifest(dir.fd, identity: receipt.identity, digest: receipt.manifestSHA256) == receipt else {
            throw DownloadContentError.invalidManifest
        }
        try checkFiles(dir.fd, pages: receipt.pages, manifest: true, verifyHashes: true)
        guard renameat(staging.fd, key(receipt.identity), bundles.fd, key(receipt.identity)) == 0 else {
            throw Self.ioError()
        }
        inventory = nil
        try Self.flush(bundles.fd)
        try Self.flush(staging.fd)
        stages.removeValue(forKey: receipt.identity.attemptID)
        reservations.removeValue(forKey: receipt.identity.attemptID)
    }

    public func open(identity: DownloadContentIdentity, manifestSHA256: String) throws -> OfflineChapterLease {
        try Task.checkCancellation()
        try validate(identity)
        guard pendingRemoval[identity.attemptID] == nil else { throw DownloadContentError.pendingDeletion }
        guard leases.count < 64 else { throw DownloadContentError.tooManyReaders }
        let directory = try Self.childDirectory(bundles.fd, name: key(identity), create: false)
        let receipt = try readManifest(directory.fd, identity: identity, digest: manifestSHA256)
        // Ensure the complete set exists before opening. Each page's bounded
        // read verifies its hash again, so corruption never reaches ImageIO.
        try checkFiles(directory.fd, pages: receipt.pages, manifest: true, verifyHashes: false)
        let id = UUID()
        leases[id] = receipt
        return OfflineChapterLease(id: id, receipt: receipt, store: self)
    }

    public func remove(identity: DownloadContentIdentity) throws -> DownloadRemovalResult {
        try validate(identity)
        pendingRemoval[identity.attemptID] = identity
        stages.removeValue(forKey: identity.attemptID)
        reservations.removeValue(forKey: identity.attemptID)
        guard !leases.values.contains(where: { $0.identity.attemptID == identity.attemptID }) else {
            return .waitingForReaders
        }
        try removeFiles(identity)
        pendingRemoval.removeValue(forKey: identity.attemptID)
        return .removed
    }

    /// Run after DB recovery invalidated partial attempts. Keep only finished
    /// DB bundle IDs and any live leases. Unknown paths are errors, never a
    /// request to recursively delete an arbitrary path.
    public func reconcile(keeping: Set<UUID>) throws {
        guard stages.isEmpty else { throw DownloadContentError.attemptUnavailable }
        let leased = Set(leases.values.map { $0.identity.attemptID })
        for parent in [staging, bundles] {
            let entries = try Self.names(parent.fd, limit: policy.maximumJobs * 3)
            for name in entries {
                guard let id = UUID(uuidString: name), id.uuidString == name else { throw DownloadContentError.unsafeFile }
                if keeping.contains(id) || leased.contains(id) { continue }
                try Self.removeDirectory(parent.fd, name: name, maximumFiles: policy.maximumPageCount + 3)
                pendingRemoval.removeValue(forKey: id)
                reservations.removeValue(forKey: id)
            }
        }
        inventory = nil
        _ = try usage()
    }

    public func usage() throws -> DownloadStorageUsage {
        inventory = nil
        return try currentUsage()
    }

    fileprivate func readPage(leaseID: UUID, ordinal: Int) throws -> Data {
        try Task.checkCancellation()
        guard let receipt = leases[leaseID] else { throw DownloadContentError.leaseClosed }
        guard receipt.pages.indices.contains(ordinal), receipt.pages[ordinal].ordinal == ordinal else {
            throw DownloadContentError.invalidPageOrder
        }
        let directory = try Self.childDirectory(bundles.fd, name: key(receipt.identity), create: false)
        let page = receipt.pages[ordinal]
        let data = try Self.read(directory.fd, name: pageName(ordinal), limit: policy.maximumPageBytes)
        guard Int64(data.count) == page.byteCount, Self.digest(data) == page.sha256 else {
            throw DownloadContentError.invalidManifest
        }
        try Task.checkCancellation()
        return data
    }

    fileprivate func closeLease(_ id: UUID) {
        guard let receipt = leases.removeValue(forKey: id),
              let pending = pendingRemoval[receipt.identity.attemptID],
              !leases.values.contains(where: { $0.identity.attemptID == pending.attemptID }) else { return }
        do {
            try removeFiles(pending)
            pendingRemoval.removeValue(forKey: pending.attemptID)
        } catch {
            // Retain the tombstone. A later explicit cleanup retry reports the
            // finite failure and does not claim that bytes have been freed.
        }
    }

    private func removeFiles(_ identity: DownloadContentIdentity) throws {
        inventory = nil
        try Self.removeDirectory(staging.fd, name: key(identity), maximumFiles: policy.maximumPageCount + 3)
        try Self.removeDirectory(bundles.fd, name: key(identity), maximumFiles: policy.maximumPageCount + 3)
    }

    private func checkPageWrite(_ stage: Stage, ordinal: Int, bytes: Int) throws {
        guard stage.prepared == nil, ordinal == stage.pages.count, ordinal < policy.maximumPageCount else {
            throw DownloadContentError.invalidPageOrder
        }
        guard (reservations[stage.identity.attemptID] ?? 0) >= Int64(policy.maximumPageBytes) + Int64(policy.maximumManifestBytes) else {
            throw DownloadContentError.reservationRequired
        }
        let previous = try stage.pages.reduce(Int64(0)) { try Self.add($0, $1.byteCount) }
        guard try Self.add(previous, Int64(bytes)) <= policy.maximumChapterBytes else {
            throw DownloadContentError.chapterTooLarge
        }
    }

    private func activeStage(_ identity: DownloadContentIdentity) throws -> Stage {
        guard pendingRemoval[identity.attemptID] == nil,
              let stage = stages[identity.attemptID], stage.identity == identity else {
            throw DownloadContentError.attemptUnavailable
        }
        return stage
    }

    private func validate(_ identity: DownloadContentIdentity) throws {
        guard identity.mangaID > 0, identity.chapterID > 0,
              Self.isDigest(identity.mangaURLDigest), Self.isDigest(identity.chapterURLDigest) else {
            throw DownloadContentError.invalidIdentity
        }
    }

    private func readManifest(_ directory: Int32, identity: DownloadContentIdentity, digest: String) throws -> DownloadManifestReceipt {
        guard Self.isDigest(digest) else { throw DownloadContentError.invalidManifest }
        let data = try Self.read(directory, name: "manifest.json", limit: policy.maximumManifestBytes)
        guard Self.digest(data) == digest else { throw DownloadContentError.invalidManifest }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw DownloadContentError.invalidManifest }
        guard manifest.version == 1, manifest.identity == identity,
              !manifest.pages.isEmpty, manifest.pages.count <= policy.maximumPageCount,
              try Self.encode(manifest) == data else { throw DownloadContentError.invalidManifest }
        var total: Int64 = 0
        for (ordinal, page) in manifest.pages.enumerated() {
            guard page.ordinal == ordinal, page.byteCount > 0,
                  page.byteCount <= Int64(policy.maximumPageBytes), Self.isDigest(page.sha256) else {
                throw DownloadContentError.invalidManifest
            }
            total = try Self.add(total, page.byteCount)
        }
        guard total == manifest.totalBytes, total <= policy.maximumChapterBytes else {
            throw DownloadContentError.invalidManifest
        }
        return DownloadManifestReceipt(identity: identity, pages: manifest.pages,
                                       totalBytes: total, manifestSHA256: digest)
    }

    private func checkFiles(_ directory: Int32, pages: [DownloadPageReceipt], manifest: Bool, verifyHashes: Bool) throws {
        var expected = Set(pages.map { pageName($0.ordinal) })
        if manifest { expected.insert("manifest.json") }
        guard Set(try Self.names(directory, limit: policy.maximumPageCount + 3)) == expected else {
            throw DownloadContentError.incompleteChapter
        }
        for page in pages {
            try Task.checkCancellation()
            let file = try Self.regularFile(directory, name: pageName(page.ordinal))
            defer { _ = close(file.fd) }
            guard file.size == page.byteCount else { throw DownloadContentError.invalidManifest }
            if verifyHashes {
                let data = try Self.readFD(file.fd, limit: policy.maximumPageBytes)
                guard Int64(data.count) == page.byteCount, Self.digest(data) == page.sha256 else {
                    throw DownloadContentError.invalidManifest
                }
            }
        }
    }

    private func currentUsage() throws -> DownloadStorageUsage {
        if inventory == nil {
            var measured = Inventory()
            for (parent, isStaging) in [(staging, true), (bundles, false)] {
                for key in try Self.names(parent.fd, limit: policy.maximumJobs * 3) {
                    guard let uuid = UUID(uuidString: key), uuid.uuidString == key else { throw DownloadContentError.unsafeFile }
                    let directory = try Self.childDirectory(parent.fd, name: key, create: false)
                    for name in try Self.names(directory.fd, limit: policy.maximumPageCount + 3) {
                        guard Self.ownedFileName(name) else { throw DownloadContentError.unsafeFile }
                        let file = try Self.regularFile(directory.fd, name: name)
                        _ = close(file.fd)
                        if isStaging { measured.staging = try Self.add(measured.staging, file.size) }
                        else { measured.stored = try Self.add(measured.stored, file.size) }
                        measured.files += 1
                        guard measured.files <= Self.maximumManagedFiles else { throw DownloadContentError.quotaExceeded }
                    }
                }
            }
            inventory = measured
        }
        let measured = inventory!
        let reserved = try reservations.values.reduce(Int64(0)) { try Self.add($0, $1) }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: rootPath)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        return DownloadStorageUsage(storedBytes: measured.stored, stagingBytes: measured.staging,
                                    reservedBytes: reserved, quotaBytes: policy.quotaBytes, freeSpaceBytes: free)
    }

    private func ensureCapacity(additional: Int64, additionalFiles: Int) throws {
        let usage = try currentUsage()
        let required = try Self.add(try Self.add(usage.totalBytes, usage.reservedBytes), additional)
        // Reserve the manifest's file slot as well as its bytes; otherwise a
        // final page at the file-count ceiling could strand a valid chapter.
        let manifests = stages.values.filter { $0.prepared == nil }.count
        let fullPageReservation = Int64(policy.maximumManifestBytes) + Int64(policy.maximumPageBytes)
        let pages = reservations.values.filter { $0 >= fullPageReservation }.count
        let requiredFiles = (inventory?.files ?? 0) + manifests + pages + additionalFiles
        guard required <= policy.quotaBytes, requiredFiles <= Self.maximumManagedFiles else {
            throw DownloadContentError.quotaExceeded
        }
        if policy.freeSpaceFloorBytes > 0 {
            guard let free = usage.freeSpaceBytes else { throw DownloadContentError.storageUnavailable }
            guard free >= (try Self.add(policy.freeSpaceFloorBytes, try Self.add(usage.reservedBytes, additional))) else {
                throw DownloadContentError.storageFull
            }
        }
    }

    private func key(_ identity: DownloadContentIdentity) -> String { identity.attemptID.uuidString }
    private func pageName(_ ordinal: Int) -> String { String(format: "p%06d.bin", ordinal) }
    private static func digest(_ data: Data) -> String { APKSignatureVerifier.apkSHA256(Array(data)) }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func encode(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(manifest) }
        catch { throw DownloadContentError.invalidManifest }
    }
    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue >= 0 else { throw DownloadContentError.quotaExceeded }
        return result.partialValue
    }

    private static func checkDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else { throw DownloadContentError.unsafeFile }
    }
    private static func childDirectory(_ parent: Int32, name: String, create: Bool) throws -> DownloadDirectory {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw DownloadContentError.unsafeFile
        }
        if create, mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw ioError() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ioError() }
        let directory = DownloadDirectory(fd)
        try checkDirectory(fd)
        return directory
    }
    private static func optionalDirectory(_ parent: Int32, name: String) throws -> DownloadDirectory? {
        do { return try childDirectory(parent, name: name, create: false) }
        catch DownloadContentError.notFound { return nil }
    }
    private static func regularFile(
        _ parent: Int32, name: String, allowInternalLinks: Bool = false
    ) throws -> (fd: Int32, size: Int64, identity: FileIdentity, links: UInt64) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ioError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink > 0,
              (allowInternalLinks || info.st_nlink == 1), info.st_size >= 0 else {
            _ = close(fd)
            throw DownloadContentError.unsafeFile
        }
        return (fd, Int64(info.st_size), FileIdentity(device: String(info.st_dev), inode: UInt64(info.st_ino)), UInt64(info.st_nlink))
    }
    private static func names(_ fd: Int32, limit: Int) throws -> [String] {
        // openat(".") creates an independent directory offset. dup alone would
        // share offsets and let an earlier scan make a later inventory empty.
        let copied = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copied >= 0 else { throw ioError() }
        guard let stream = fdopendir(copied) else { _ = close(copied); throw ioError() }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ioError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= limit else { throw DownloadContentError.quotaExceeded }
        }
        return names.sorted()
    }
    private static func read(_ parent: Int32, name: String, limit: Int) throws -> Data {
        let file = try regularFile(parent, name: name)
        defer { _ = close(file.fd) }
        guard file.size <= Int64(limit) else { throw DownloadContentError.imageTooLarge }
        return try readFD(file.fd, limit: limit)
    }
    private static func readFD(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while true {
            try Task.checkCancellation()
            let amount = min(buffer.count, limit - result.count + 1)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, raw.baseAddress, amount)
                #else
                return Glibc.read(fd, raw.baseAddress, amount)
                #endif
            }
            if count < 0 { if errno == EINTR { continue }; throw ioError() }
            if count == 0 { return result }
            guard count <= limit - result.count else { throw DownloadContentError.imageTooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writeExclusive(_ data: Data, directory: Int32, name: String) throws {
        let temporary = ".tmp-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ioError() }
        defer { _ = close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var position = 0
            while position < raw.count {
                try Task.checkCancellation()
                let count = min(65_536, raw.count - position)
                #if canImport(Darwin)
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: position), count)
                #else
                let written = Glibc.write(fd, raw.baseAddress!.advanced(by: position), count)
                #endif
                if written < 0 { if errno == EINTR { continue }; throw ioError() }
                guard written > 0 else { throw DownloadContentError.storageUnavailable }
                position += written
            }
        }
        try flush(fd)
        // linkat publishes without overwriting an existing generated slot.
        guard linkat(directory, temporary, directory, name, 0) == 0 else { throw ioError() }
        guard unlinkat(directory, temporary, 0) == 0 else { throw ioError() }
        try flush(directory)
    }
    private static func ownedFileName(_ name: String) -> Bool {
        if name == "manifest.json" { return true }
        if name.hasPrefix(".tmp-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return name == ".tmp-\(id.uuidString)"
        }
        guard name.utf8.count == 11, name.hasPrefix("p"), name.hasSuffix(".bin") else { return false }
        return name.dropFirst().dropLast(4).utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func removeDirectory(_ parent: Int32, name: String, maximumFiles: Int) throws {
        guard let directory = try optionalDirectory(parent, name: name) else { return }
        let entries = try names(directory.fd, limit: maximumFiles)
        // Validate every entry before removing any; an unexpected sentinel or
        // link must not turn cleanup into recursive deletion outside the root.
        var links: [FileIdentity: [(name: String, count: UInt64)]] = [:]
        for entry in entries {
            guard ownedFileName(entry) else { throw DownloadContentError.unsafeFile }
            let file = try regularFile(directory.fd, name: entry, allowInternalLinks: true)
            _ = close(file.fd)
            links[file.identity, default: []].append((entry, file.links))
        }
        for group in links.values {
            if group.count == 1, group[0].count == 1 { continue }
            // A crash between linkat(temp, final) and unlinkat(temp) leaves
            // exactly two owned names for one inode. Permit only that pair,
            // proving there is no third/external link before deleting either.
            guard group.count == 2, group.allSatisfy({ $0.count == 2 }),
                  group.filter({ $0.name.hasPrefix(".tmp-") }).count == 1 else {
                throw DownloadContentError.unsafeFile
            }
        }
        for entry in entries {
            guard unlinkat(directory.fd, entry, 0) == 0 else { throw ioError() }
        }
        try flush(directory.fd)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ioError() }
        try flush(parent)
    }
    private static func flush(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ioError() }
    }
    private static func ioError() -> DownloadContentError {
        switch errno {
        case ENOENT: return .notFound
        case ENOSPC, EDQUOT: return .storageFull
        case ELOOP, ENOTDIR, EEXIST: return .unsafeFile
        default: return .storageUnavailable
        }
    }
}
