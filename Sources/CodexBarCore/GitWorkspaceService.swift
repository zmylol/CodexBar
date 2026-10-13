import Darwin
import Foundation

public struct GitWorkspaceRecord: Codable, Equatable, Sendable, Identifiable {
    public let workspaceRoot: String
    public let repositoryID: String
    public let parentWorkspaceRoot: String?
    public let order: Int
    public let isMainWorkspace: Bool
    public var id: String { workspaceRoot }

    public init(workspaceRoot: String, repositoryID: String, parentWorkspaceRoot: String?, order: Int, isMainWorkspace: Bool) {
        self.workspaceRoot = workspaceRoot
        self.repositoryID = repositoryID
        self.parentWorkspaceRoot = parentWorkspaceRoot
        self.order = order
        self.isMainWorkspace = isMainWorkspace
    }
}

public struct GitWorkspaceSnapshot: Equatable, Sendable {
    public let records: [GitWorkspaceRecord]
    public let identities: [String: GitWorkspaceIdentity]

    public init(records: [GitWorkspaceRecord] = [], identities: [String: GitWorkspaceIdentity] = [:]) {
        self.records = records
        self.identities = identities
    }
}

public enum GitWorkspaceServiceError: Error, LocalizedError {
    case invalidDirectory
    case invalidBranch
    case unavailableWorkspace
    case invalidRegistry
    case registryBusy
    case commandFailed(String)
    case commandTimedOut
    case outputLimit

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "请选择有效且尚未使用的工作目录。"
        case .invalidBranch: "分支名无效、不受支持，或分支已经存在。"
        case .unavailableWorkspace: "工作目录不可用，或已不属于原来的 Git 仓库。"
        case .invalidRegistry: "工作目录记录损坏或不可安全读取，未修改 Git。"
        case .registryBusy: "另一项工作目录操作尚未结束，请稍后重试。"
        case .commandFailed(let message): message
        case .commandTimedOut: "Git 操作超时，请检查目录状态后重试。"
        case .outputLimit: "Git 返回的数据过多，操作已停止。"
        }
    }
}

/// The actor never suspends while holding the registry lock or changing Git. Directory
/// ancestry is written durably before creation, including if the app exits during Git.
public actor GitWorkspaceService {
    private let storageURL: URL
    private struct Registry: Codable {
        var version = 1
        var records: [GitWorkspaceRecord] = []
    }

    public init(storageURL: URL) { self.storageURL = storageURL }

    public func snapshot() async throws -> GitWorkspaceSnapshot {
        try withRegistryLock {
            var registry = try load()
            let previous = registry.records
            var discovered: Set<String> = []
            for record in previous {
                guard !discovered.contains(record.repositoryID),
                      let identity = GitWorkspaceIdentityReader.read(cwd: record.workspaceRoot),
                      identity.workspaceRoot == record.workspaceRoot,
                      identity.repositoryID == record.repositoryID else { continue }
                try discover(identity, into: &registry)
                discovered.insert(record.repositoryID)
            }
            if registry.records != previous { try save(registry) }
            return project(registry.records)
        }
    }

    public func addProject(directory: URL) async throws -> GitWorkspaceSnapshot {
        try withRegistryLock {
            var registry = try load()
            guard directory.isFileURL else { throw GitWorkspaceServiceError.invalidDirectory }
            let identity = try workspace(directory.path)
            try discover(identity, into: &registry)
            try save(registry)
            return project(registry.records)
        }
    }

    public func createWorktree(
        from sourceDirectory: String, at destination: URL, branch: String
    ) async throws -> GitWorkspaceSnapshot {
        try withRegistryLock {
            var registry = try load()
            let source = try registeredWorkspace(sourceDirectory, registry: registry)
            // Freeze the selected source before branch and destination validation.
            let commit = try git(["rev-parse", "--verify", "HEAD^{commit}"], in: source.workspaceRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard [40, 64].contains(commit.count), commit.allSatisfy(\.isHexDigit) else {
                throw GitWorkspaceServiceError.unavailableWorkspace
            }
            try validateBranch(branch, in: source.workspaceRoot)
            guard try !branches(in: source.workspaceRoot).contains(branch) else {
                throw GitWorkspaceServiceError.invalidBranch
            }
            var destinationInfo = stat()
            guard destination.isFileURL, Self.safePath(destination.path),
                  lstat(destination.path, &destinationInfo) != 0, errno == ENOENT,
                  let destinationPath = Self.workspacePath(destination.path),
                  !FileManager.default.fileExists(atPath: destinationPath),
                  !registry.records.contains(where: { $0.workspaceRoot == destinationPath }),
                  (try? URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw GitWorkspaceServiceError.invalidDirectory }
            let previous = registry
            registry.records.append(GitWorkspaceRecord(
                workspaceRoot: destinationPath, repositoryID: source.repositoryID,
                parentWorkspaceRoot: source.workspaceRoot, order: registry.records.count,
                isMainWorkspace: false
            ))
            try save(registry)
            do {
                _ = try git(["worktree", "add", "-b", branch, "--", destinationPath, commit], in: source.workspaceRoot)
            } catch {
                // Keep the durable record when Git may have created metadata before failing.
                // No worktree, branch, or user files are deleted as compensation.
                if case GitWorkspaceServiceError.commandFailed = error,
                   !FileManager.default.fileExists(atPath: destinationPath) {
                    try save(previous)
                }
                throw error
            }
            return project(registry.records)
        }
    }

    public func switchBranch(in directory: String, to branch: String) async throws -> GitWorkspaceSnapshot {
        try withRegistryLock {
            let registry = try load()
            let identity = try registeredWorkspace(directory, registry: registry)
            try validateBranch(branch, in: identity.workspaceRoot)
            guard try branches(in: identity.workspaceRoot).contains(branch) else {
                throw GitWorkspaceServiceError.invalidBranch
            }
            // Git's normal checkout refusal protects local changes and occupied branches.
            _ = try git(["switch", "--no-guess", branch], in: identity.workspaceRoot)
            return project(registry.records)
        }
    }

    public func localBranches(in directory: String) async throws -> [String] {
        try withRegistryLock {
            let identity = try registeredWorkspace(directory, registry: load())
            return try branches(in: identity.workspaceRoot)
        }
    }

    private func branches(in directory: String) throws -> [String] {
        try git(["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"], in: directory)
            .split(separator: "\n").map(String.init).filter(GitBranchOriginReader.isLocalBranchName).sorted()
    }

    private func validateBranch(_ branch: String, in directory: String) throws {
        guard GitBranchOriginReader.isLocalBranchName(branch)
        else { throw GitWorkspaceServiceError.invalidBranch }
        do { _ = try git(["check-ref-format", "--branch", branch], in: directory) }
        catch GitWorkspaceServiceError.commandFailed { throw GitWorkspaceServiceError.invalidBranch }
    }

    private func workspace(_ directory: String) throws -> GitWorkspaceIdentity {
        guard Self.safePath(directory), let identity = GitWorkspaceIdentityReader.read(cwd: directory) else {
            throw GitWorkspaceServiceError.unavailableWorkspace
        }
        let root = try git(["rev-parse", "--show-toplevel"], in: identity.workspaceRoot)
            .trimmingCharacters(in: .newlines)
        guard PathNormalizer.normalize(root) == identity.workspaceRoot else {
            throw GitWorkspaceServiceError.unavailableWorkspace
        }
        return identity
    }

    private func registeredWorkspace(_ directory: String, registry: Registry) throws -> GitWorkspaceIdentity {
        guard Self.safePath(directory), let requestedRoot = PathNormalizer.normalize(directory),
              let record = registry.records.first(where: { $0.workspaceRoot == requestedRoot })
        else { throw GitWorkspaceServiceError.unavailableWorkspace }
        let identity = try workspace(record.workspaceRoot)
        guard identity.workspaceRoot == record.workspaceRoot, identity.repositoryID == record.repositoryID
        else { throw GitWorkspaceServiceError.unavailableWorkspace }
        return identity
    }

    private func discover(_ identity: GitWorkspaceIdentity, into registry: inout Registry) throws {
        let output = try git(["worktree", "list", "--porcelain", "-z"], in: identity.workspaceRoot)
        let entries = output.components(separatedBy: "\0\0").filter { !$0.isEmpty }
        for (index, entry) in entries.enumerated() {
            let fields = entry.split(separator: "\0")
            guard let field = fields.first, field.hasPrefix("worktree ") else {
                throw GitWorkspaceServiceError.unavailableWorkspace
            }
            if fields.contains("bare") { continue }
            let path = String(field.dropFirst(9))
            guard Self.safePath(path), let normalized = Self.workspacePath(path) else {
                throw GitWorkspaceServiceError.invalidDirectory
            }
            if let existing = registry.records.first(where: { $0.workspaceRoot == normalized }) {
                guard existing.repositoryID == identity.repositoryID else {
                    throw GitWorkspaceServiceError.invalidRegistry
                }
                continue
            }
            // Git lists the main checkout first. The list itself establishes repository
            // membership even when an external checkout is currently unavailable.
            registry.records.append(GitWorkspaceRecord(
                workspaceRoot: normalized, repositoryID: identity.repositoryID,
                parentWorkspaceRoot: nil, order: registry.records.count,
                isMainWorkspace: index == 0
            ))
        }
        guard registry.records.contains(where: { $0.workspaceRoot == identity.workspaceRoot }) else {
            throw GitWorkspaceServiceError.unavailableWorkspace
        }
    }

    private func project(_ records: [GitWorkspaceRecord]) -> GitWorkspaceSnapshot {
        var identities: [String: GitWorkspaceIdentity] = [:]
        for record in records {
            if let identity = GitWorkspaceIdentityReader.read(cwd: record.workspaceRoot),
               identity.workspaceRoot == record.workspaceRoot, identity.repositoryID == record.repositoryID {
                identities[record.workspaceRoot] = identity
            }
        }
        return GitWorkspaceSnapshot(records: records.sorted { $0.order < $1.order }, identities: identities)
    }

    private static func safePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4_096
            && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    // Foundation can normalize macOS /var aliases differently when the final path
    // disappears. Resolve the existing ancestor before appending missing components.
    private static func workspacePath(_ path: String) -> String? {
        guard safePath(path) else { return nil }
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor.lastPathComponent)
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            ancestor = parent
        }
        guard let resolved = ancestor.path == "/" ? "/" : PathNormalizer.normalize(ancestor.path) else { return nil }
        return missing.reversed().reduce(URL(fileURLWithPath: resolved)) { $0.appendingPathComponent($1) }.path
    }

    private func validate(_ registry: Registry) throws {
        guard registry.version == 1, registry.records.count <= 1_024 else {
            throw GitWorkspaceServiceError.invalidRegistry
        }
        var byPath: [String: GitWorkspaceRecord] = [:]
        var orders: Set<Int> = []
        var mainRepositories: Set<String> = []
        for record in registry.records {
            guard Self.safePath(record.workspaceRoot), Self.safePath(record.repositoryID),
                  URL(fileURLWithPath: record.workspaceRoot).standardizedFileURL.path == record.workspaceRoot,
                  URL(fileURLWithPath: record.repositoryID).standardizedFileURL.path == record.repositoryID,
                  record.order >= 0, record.order < 1_024, orders.insert(record.order).inserted,
                  byPath.updateValue(record, forKey: record.workspaceRoot) == nil,
                  !record.isMainWorkspace || (record.parentWorkspaceRoot == nil && mainRepositories.insert(record.repositoryID).inserted)
            else { throw GitWorkspaceServiceError.invalidRegistry }
        }
        for record in registry.records {
            var seen: Set<String> = [record.workspaceRoot]
            var parent = record.parentWorkspaceRoot
            while let path = parent {
                guard seen.insert(path).inserted, let ancestor = byPath[path],
                      ancestor.repositoryID == record.repositoryID else {
                    throw GitWorkspaceServiceError.invalidRegistry
                }
                parent = ancestor.parentWorkspaceRoot
            }
        }
    }

    private func load() throws -> Registry {
        let fd = Darwin.open(storageURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return Registry() }
            throw GitWorkspaceServiceError.invalidRegistry
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 1_048_576 else {
            throw GitWorkspaceServiceError.invalidRegistry
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let registry = try? JSONDecoder().decode(Registry.self, from: data) else {
            throw GitWorkspaceServiceError.invalidRegistry
        }
        try validate(registry)
        return registry
    }

    private func save(_ registry: Registry) throws {
        try validate(registry)
        let data = try JSONEncoder().encode(registry)
        guard data.count <= 1_048_576 else { throw GitWorkspaceServiceError.invalidRegistry }
        let temporary = storageURL.deletingLastPathComponent().appendingPathComponent(".workspaces-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, Darwin.rename(temporary.path, storageURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = Darwin.open(storageURL.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func withRegistryLock<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        guard storageURL.isFileURL, Self.safePath(storageURL.path) else {
            throw GitWorkspaceServiceError.invalidRegistry
        }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = Darwin.open(storageURL.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitWorkspaceServiceError.invalidRegistry }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            throw GitWorkspaceServiceError.invalidRegistry
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw GitWorkspaceServiceError.invalidRegistry
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw GitWorkspaceServiceError.registryBusy }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        try GitWorkspaceCommandRunner.run(arguments: arguments, directory: directory)
    }
}
