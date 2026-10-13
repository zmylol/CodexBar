import Darwin
import Foundation

/// Metadata used only to prompt discovery of a newly created VS Code session.
public struct CodexSessionCandidate: Hashable, Sendable {
    public let sessionID: String
    public let cwd: String

    public init(sessionID: String, cwd: String) {
        self.sessionID = sessionID
        self.cwd = cwd
    }
}

package enum CodexSessionCandidateReadResult: Equatable, Sendable {
    case pending
    case ignored
    case candidate(CodexSessionCandidate)
}

/// Synchronous filesystem access; callers run this reader off the main actor.
package struct CodexSessionCandidateReader: Sendable {
    package init() {}

    package func read(at url: URL) -> CodexSessionCandidateReadResult {
        guard url.isFileURL, !url.path.utf8.contains(0) else { return .ignored }
        let descriptor = openWithoutSymlinks(url)
        guard descriptor >= 0 else { return errno == ENOENT ? .pending : .ignored }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else { return .ignored }

        var line = Data()
        // Read one byte at a time so no read crosses into the conversation body.
        for _ in 0..<(64 * 1_024) {
            var byte: UInt8 = 0
            var count: Int
            repeat { count = Darwin.read(descriptor, &byte, 1) } while count < 0 && errno == EINTR
            if count == 0 { return .pending }
            guard count == 1 else { return .ignored }
            if byte == 10 { return candidate(from: line) }
            line.append(byte)
        }
        return .ignored
    }

    private func candidate(from line: Data) -> CodexSessionCandidateReadResult {
        guard let metadata = try? JSONDecoder().decode(SessionMetadata.self, from: line),
              metadata.type == "session_meta", metadata.payload.source == "vscode",
              !metadata.payload.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.payload.id.utf8.count <= 512,
              metadata.payload.cwd.utf8.count <= 4_096,
              !metadata.payload.cwd.utf8.contains(0),
              let cwd = PathNormalizer.normalize(metadata.payload.cwd)
        else { return .ignored }
        return .candidate(CodexSessionCandidate(sessionID: metadata.payload.id, cwd: cwd))
    }

    private func openWithoutSymlinks(_ url: URL) -> Int32 {
        let components = url.path.split(separator: "/")
        guard let filename = components.last,
              !components.contains("..") else { errno = EINVAL; return -1 }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return -1 }
        for component in components.dropLast() {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(directory)
            guard next >= 0 else { errno = failure; return -1 }
            directory = next
        }
        // O_NONBLOCK also prevents a substituted FIFO from blocking before fstat.
        let descriptor = openat(directory, String(filename), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        let failure = errno
        close(directory)
        errno = failure
        return descriptor
    }
}

private struct SessionMetadata: Decodable {
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let id: String
        let cwd: String
        let source: String
    }
}
