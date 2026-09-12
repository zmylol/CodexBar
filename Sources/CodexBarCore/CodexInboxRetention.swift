import Darwin
import Foundation

public struct CodexInboxHealth: Equatable, Sendable {
    /// Unacknowledged reliable Inbox entries in the latest reader snapshot.
    public let pendingCount: Int
    /// Cumulative events selected for discard; an interrupted cleanup may overcount.
    public let discardedCount: Int

    public init(pendingCount: Int, discardedCount: Int) {
        self.pendingCount = pendingCount
        self.discardedCount = discardedCount
    }
}

package struct CodexInboxRetentionPolicy: Sendable {
    package static let standard = Self(
        maximumFileCount: 2_048,
        maximumBytes: 32 * 1_024 * 1_024,
        maximumAge: 7 * 24 * 60 * 60
    )
    package let maximumFileCount: Int
    package let maximumBytes: Int
    package let maximumAge: TimeInterval

    package init(maximumFileCount: Int, maximumBytes: Int, maximumAge: TimeInterval) {
        self.maximumFileCount = maximumFileCount
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
    }
}

struct CodexInboxRetention {
    let paths: CodexBarPaths
    let fileManager: FileManager
    let policy: CodexInboxRetentionPolicy

    private var counterURL: URL { paths.rootDirectory.appendingPathComponent("inbox-discarded-count") }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let url = paths.rootDirectory.appendingPathComponent(".inbox.lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw POSIXError(.EACCES) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw POSIXError(.EACCES) }
            guard ContinuousClock.now < deadline else { throw CodexInboxRetentionError.lockBusy }
            usleep(1_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Called under the shared writer/consumer lock. File names order event replay;
    /// modification dates measure arrival age independently of payload timestamps.
    func retain(_ sortedURLs: [URL], now: Date = Date()) throws -> [URL] {
        var retained: [(url: URL, size: Int)] = []
        var discarded: [URL] = []
        let expiredBefore = now.addingTimeInterval(-policy.maximumAge)
        for url in sortedURLs {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
            ]) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                // Invalid queue entries still pass through the existing quarantine path.
                retained.append((url, 0))
                continue
            }
            if let modified = values.contentModificationDate, modified < expiredBefore {
                discarded.append(url)
            } else {
                retained.append((url, values.fileSize ?? 0))
            }
        }
        var bytes = retained.reduce(0) { $0 + $1.size }
        var oldest = 0
        while retained.count - oldest > policy.maximumFileCount || bytes > policy.maximumBytes {
            let file = retained[oldest]
            discarded.append(file.url)
            bytes -= file.size
            oldest += 1
        }
        if !discarded.isEmpty {
            let count = try discardedCount()
            // Record potential loss before deleting anything. A failed counter write
            // leaves all events intact; interruption can produce a conservative warning.
            try saveDiscardedCount(count > Int.max - discarded.count ? Int.max : count + discarded.count)
            for url in discarded {
                do { try fileManager.removeItem(at: url) }
                catch where Self.isMissingFile(error) { continue }
            }
        }
        return retained.dropFirst(oldest).map(\.url)
    }

    func discardedCount() throws -> Int {
        var status = stat()
        guard lstat(counterURL.path, &status) == 0 else {
            if errno == ENOENT { return 0 }
            throw POSIXError(.EACCES)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(),
              status.st_nlink == 1, status.st_size <= 32,
              let count = Int(try String(contentsOf: counterURL, encoding: .utf8)), count >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return count
    }

    private func saveDiscardedCount(_ count: Int) throws {
        let temporary = paths.rootDirectory.appendingPathComponent(".inbox-count-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path, contents: Data(String(count).utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, counterURL.path) == 0 else { throw POSIXError(.EIO) }
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
    }
}

enum CodexInboxRetentionError: Error {
    case lockBusy
}
