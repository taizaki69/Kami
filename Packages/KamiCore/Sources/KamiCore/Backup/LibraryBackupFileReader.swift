import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LibraryBackupFileError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, notRegularFile, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The backup file could not be read. Choose a downloaded file in Files and try again."
        case .notRegularFile: "Choose a regular Kami backup file. Folders and links cannot be imported."
        case .tooLarge: "The backup file exceeds the import size limit."
        }
    }
}

/// The caller owns any platform security-scoped access. Read once into bounded
/// immutable bytes; preview and review-again must never reopen a provider URL.
public enum LibraryBackupFileReader {
    public static func read(_ url: URL, policy: LibraryBackupPolicy = .default) throws -> Data {
        do {
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.utf8.contains(0) else { throw LibraryBackupFileError.notRegularFile }
            let handle = try openRegularFile(url, maximum: policy.maximumInputBytes)
            defer { try? handle.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let count = min(65_536, policy.maximumInputBytes - data.count + 1)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                guard chunk.count <= policy.maximumInputBytes - data.count else { throw LibraryBackupFileError.tooLarge }
                data.append(chunk)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as LibraryBackupFileError { throw error }
        catch { throw LibraryBackupFileError.unavailable }
    }

    private static func openRegularFile(_ url: URL, maximum: Int) throws -> FileHandle {
        #if canImport(Darwin) || canImport(Glibc)
        // Validate the opened descriptor, not a path that could be replaced
        // between stat and open. Nonblocking open also prevents FIFO hangs.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryBackupFileError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw LibraryBackupFileError.unavailable }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LibraryBackupFileError.notRegularFile }
            guard info.st_size >= 0, info.st_size <= maximum else { throw LibraryBackupFileError.tooLarge }
            return handle
        } catch {
            try? handle.close()
            throw error
        }
        #else
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryBackupFileError.notRegularFile }
        if let size = values.fileSize, size > maximum { throw LibraryBackupFileError.tooLarge }
        return try FileHandle(forReadingFrom: url)
        #endif
    }
}
