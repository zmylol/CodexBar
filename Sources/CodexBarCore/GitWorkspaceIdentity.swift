import Foundation

public struct GitWorkspaceIdentity: Equatable, Sendable {
    public let repositoryID: String
    public let workspaceRoot: String
    public let repositoryName: String
    public let branch: String
    public let isLinkedWorktree: Bool
    public let headPath: String
    public let sourceBranch: String?
    public let metadataWatchPaths: [String]

    public init(
        repositoryID: String, workspaceRoot: String, repositoryName: String,
        branch: String, isLinkedWorktree: Bool, headPath: String,
        sourceBranch: String? = nil, metadataWatchPaths: [String] = []
    ) {
        self.repositoryID = repositoryID
        self.workspaceRoot = workspaceRoot
        self.repositoryName = repositoryName
        self.branch = branch
        self.isLinkedWorktree = isLinkedWorktree
        self.headPath = headPath
        self.sourceBranch = sourceBranch
        self.metadataWatchPaths = metadataWatchPaths
    }
}

public struct GitWorkspaceLabel: Equatable, Sendable {
    public let repositoryName: String
    public let branch: String
    public let shortBranch: String
    public let isLinkedWorktree: Bool
    public let workspaceRoot: String
    public let sourceBranch: String?
    public let repositoryID: String

    public init(
        repositoryName: String, branch: String, shortBranch: String,
        isLinkedWorktree: Bool, workspaceRoot: String,
        sourceBranch: String? = nil, repositoryID: String = ""
    ) {
        self.repositoryName = repositoryName
        self.branch = branch
        self.shortBranch = shortBranch
        self.isLinkedWorktree = isLinkedWorktree
        self.workspaceRoot = workspaceRoot
        self.sourceBranch = sourceBranch
        self.repositoryID = repositoryID
    }
}

public enum GitWorkspaceIdentityReader {
    /// Reads only bounded Git metadata. Call from a background queue when projecting UI state.
    public static func read(cwd: String) -> GitWorkspaceIdentity? {
        guard let path = PathNormalizer.normalize(cwd) else { return nil }
        var root = URL(fileURLWithPath: path, isDirectory: true)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        for _ in 0..<128 {
            let marker = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = canonical(marker)
                } else {
                    guard let contents = metadata(marker), contents.hasPrefix("gitdir: "),
                          let target = metadataPath(String(contents.dropFirst(8)), relativeTo: root)
                    else { return nil }
                    gitDirectory = target
                }
                return identity(root: root, gitDirectory: gitDirectory)
            }
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return nil }
            root = parent
        }
        return nil
    }

    /// Keeps Git context for related checkouts and for a linked worktree opened on its own.
    public static func labels(identities: [String: GitWorkspaceIdentity]) -> [String: GitWorkspaceLabel] {
        var result: [String: GitWorkspaceLabel] = [:]
        for group in Dictionary(grouping: identities, by: { $0.value.repositoryID }).values {
            let workspaces = Dictionary(grouping: group, by: { $0.value.workspaceRoot })
            guard workspaces.count > 1 || group.contains(where: { $0.value.isLinkedWorktree }) else { continue }
            let roots = workspaces.keys.sorted()
            let values = roots.compactMap { workspaces[$0]?.sorted { $0.key < $1.key }.first?.value }
            let branches = values.map(\.branch)
            var abbreviations = branches.map { shortBranch($0, peers: branches) }
            let collisions = Dictionary(grouping: abbreviations.indices, by: { abbreviations[$0] })
            var used = Set(collisions.filter { $0.value.count == 1 }.keys)
            for index in abbreviations.indices where (collisions[abbreviations[index]]?.count ?? 0) > 1 {
                var number = index + 1
                var candidate: String
                repeat {
                    let suffix = "·\(number)"
                    candidate = displayPrefix(abbreviations[index], units: 8 - displayWidth(suffix)) + suffix
                    number += 1
                } while used.contains(candidate)
                abbreviations[index] = candidate
                used.insert(candidate)
            }
            for (index, identity) in values.enumerated() {
                let label = GitWorkspaceLabel(
                    repositoryName: identity.repositoryName, branch: identity.branch,
                    shortBranch: abbreviations[index], isLinkedWorktree: identity.isLinkedWorktree,
                    workspaceRoot: identity.workspaceRoot, sourceBranch: identity.sourceBranch,
                    repositoryID: identity.repositoryID
                )
                for entry in workspaces[identity.workspaceRoot] ?? [] { result[entry.key] = label }
            }
        }
        return result
    }

    private static func identity(root: URL, gitDirectory: URL) -> GitWorkspaceIdentity? {
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        let commonDirectory: URL
        if FileManager.default.fileExists(atPath: commonFile.path) {
            guard let contents = metadata(commonFile),
                  let target = metadataPath(contents, relativeTo: gitDirectory)
            else { return nil }
            commonDirectory = target
        } else {
            commonDirectory = gitDirectory
        }
        guard (try? commonDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let head = gitDirectory.appendingPathComponent("HEAD")
        guard GitBranchOriginReader.metadataURL("HEAD", within: gitDirectory) != nil,
              let contents = metadata(head) else { return nil }
        let branch: String
        let sourceBranch: String?
        var watchPaths = [head.path]
        if contents.hasPrefix("ref: refs/heads/") {
            branch = String(contents.dropFirst(16))
            guard GitBranchOriginReader.isLocalBranchName(branch) else { return nil }
            sourceBranch = GitBranchOriginReader.read(branch: branch, commonDirectory: commonDirectory)
            var relativePaths = ["logs/refs/heads/\(branch)", "refs/heads/\(branch)", "packed-refs"]
            if let sourceBranch { relativePaths.append("refs/heads/\(sourceBranch)") }
            watchPaths += relativePaths.compactMap {
                GitBranchOriginReader.metadataURL($0, within: commonDirectory)?.path
            }
        } else {
            guard [40, 64].contains(contents.count), contents.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return nil }
            branch = "HEAD·" + contents.prefix(7)
            sourceBranch = nil
        }
        let name = commonDirectory.lastPathComponent == ".git"
            ? commonDirectory.deletingLastPathComponent().lastPathComponent
            : commonDirectory.deletingPathExtension().lastPathComponent
        return GitWorkspaceIdentity(
            repositoryID: commonDirectory.path, workspaceRoot: root.path, repositoryName: name,
            branch: branch, isLinkedWorktree: commonDirectory != gitDirectory, headPath: head.path,
            sourceBranch: sourceBranch, metadataWatchPaths: watchPaths
        )
    }

    private static func metadata(_ url: URL) -> String? {
        let limit = 8_192
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let contents = String(data: data, encoding: .utf8)
        else { return nil }
        let line = contents.trimmingCharacters(in: .newlines)
        guard !line.isEmpty, !line.contains("\n"), !line.contains("\r"), !line.contains("\0") else { return nil }
        return line
    }

    private static func metadataPath(_ path: String, relativeTo directory: URL) -> URL? {
        guard !path.isEmpty, path.utf8.count <= 4_096 else { return nil }
        return canonical(URL(fileURLWithPath: path, relativeTo: directory))
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func shortBranch(_ branch: String, peers: [String]) -> String {
        guard displayWidth(branch) > 8 else { return branch }
        let leading = displayPrefix(branch, units: 7)
        let similar = peers.filter { $0 != branch && displayPrefix($0, units: 7) == leading }
        guard !similar.isEmpty else { return leading + "…" }
        var prefix = Array(branch)
        for peer in similar { prefix = Array(zip(prefix, peer).prefix { $0 == $1 }.map(\.0)) }
        let cut = prefix.lastIndex(where: { "/-_".contains($0) }).map { $0 + 1 } ?? prefix.count
        let remainder = String(branch.dropFirst(cut))
        guard !remainder.isEmpty else { return leading + "…" }
        return displayWidth(remainder) <= 7 ? "…" + remainder : "…" + displayPrefix(remainder, units: 6) + "…"
    }

    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + displayWidth($1) }
    }

    private static func displayWidth(_ character: Character) -> Int {
        character == "…" || character.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2
    }

    private static func displayPrefix(_ text: String, units: Int) -> String {
        var remaining = units
        return String(text.prefix { character in
            remaining -= displayWidth(character)
            return remaining >= 0
        })
    }
}
