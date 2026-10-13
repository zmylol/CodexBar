import Darwin
import Foundation

/// Runs Git in its own process group so cancellation also stops checkout filters.
public enum GitWorkspaceCommandRunner {
    public static func run(arguments: [String], directory: String) throws -> String {
        try Task.checkCancellation()
        let command = ["/usr/bin/git", "--no-pager", "-C", directory,
                       "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                       "-c", "submodule.recurse=false"] + arguments
        guard command.allSatisfy({ !$0.utf8.contains(0) }) else { throw POSIXError(.EINVAL) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw posixError() }
        defer {
            for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
        }
        for index in descriptors.indices {
            if descriptors[index] <= STDERR_FILENO {
                let duplicated = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
                guard duplicated >= 0 else { throw posixError() }
                Darwin.close(descriptors[index])
                descriptors[index] = duplicated
            }
            guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) == 0 else { throw posixError() }
        }
        let readFD = descriptors[0]
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else { throw posixError() }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[0]))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[1]))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        // A zero group creates a new group whose ID is the spawned Git PID.
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let argv = command.map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var processID: pid_t = 0
        try (argv + [nil]).withUnsafeBufferPointer { argumentsBuffer in
            try (envp + [nil]).withUnsafeBufferPointer { environmentBuffer in
                try check(posix_spawn(
                    &processID, "/usr/bin/git", &actions, &attributes,
                    UnsafeMutablePointer(mutating: argumentsBuffer.baseAddress!),
                    UnsafeMutablePointer(mutating: environmentBuffer.baseAddress!)
                ))
            }
        }
        Darwin.close(descriptors[1])
        descriptors[1] = -1
        // Keep the leader waitable until group cleanup is complete. Reaping it early
        // would allow its PID (and therefore the process group ID) to be reused.
        defer { reap(processID) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        do {
            var exitInformation = siginfo_t()
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw GitWorkspaceServiceError.commandTimedOut }
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= 1_048_576 else { throw GitWorkspaceServiceError.outputLimit }
                    continue
                }
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    throw posixError()
                }
                // Read once more after observing exit: Git may have written its last
                // bytes between our previous nonblocking read and waitid.
                if exitInformation.si_pid == processID { break }
                exitInformation = siginfo_t()
                if waitid(P_PID, id_t(processID), &exitInformation, WEXITED | WNOHANG | WNOWAIT) != 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                if exitInformation.si_pid != processID { usleep(10_000) }
            }
            try Task.checkCancellation()
            guard exitInformation.si_code == CLD_EXITED, exitInformation.si_status == 0 else {
                let message = String(decoding: data.prefix(8_192), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitWorkspaceServiceError.commandFailed(message.isEmpty ? "Git 操作失败。" : message)
            }
            guard let output = String(data: data, encoding: .utf8) else { throw GitWorkspaceServiceError.outputLimit }
            return output
        } catch {
            // Git can exit on TERM while a filter ignores it. Always escalate the
            // original group before reaping Git, even when Git has already exited.
            Darwin.kill(-processID, SIGTERM)
            usleep(250_000)
            Darwin.kill(-processID, SIGKILL)
            throw error
        }
    }

    private static func reap(_ processID: pid_t) {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
