import CryptoKit
import Darwin
import Foundation

public struct KnowledgeFolderSection: Identifiable, Equatable, Sendable {
    public let relativePath: String
    public let name: String
    public let noteCount: Int
    public var id: String { relativePath }

    public init(relativePath: String, name: String, noteCount: Int) {
        self.relativePath = relativePath
        self.name = name
        self.noteCount = noteCount
    }
}

public struct KnowledgeFolderSnapshot: Equatable, Sendable {
    public let changes: [CodexRecordedFileChange]
    public let noteCount: Int
    public let warnings: [String]
    public let sections: [KnowledgeFolderSection]
    public let articles: [KnowledgeArticle]
}

/// Keeps an in-memory baseline for one explicitly selected vault. Capture is never run on the UI actor.
public actor KnowledgeFolderTracker {
    public static let maximumNotes = 10_000
    public static let maximumNoteBytes = 256 * 1_024
    public static let maximumContentBytes = 32 * 1_024 * 1_024
    public static let maximumDiffBytes = 32 * 1_024
    private static let maximumEntries = 50_000

    private let vault: ObsidianVault
    private let trackerID = UUID().uuidString
    private var files: [String: Note] = [:]
    private var articleIndex: [String: ArticleEntry] = [:]
    private var sections: [KnowledgeFolderSection] = []
    private var rootIdentity: Identity?
    private var hasBaseline = false
    private var revision = 0

    private struct Identity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int
    }

    private struct Metadata: Equatable, Sendable {
        let identity: Identity
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            identity = Identity(device: value.st_dev, inode: value.st_ino,
                                createdSeconds: value.st_birthtimespec.tv_sec,
                                createdNanoseconds: value.st_birthtimespec.tv_nsec)
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private struct Note: Sendable {
        let metadata: Metadata
        let content: String
        var byteCount: Int { content.utf8.count }
    }

    private struct ArticleEntry: Sendable {
        let metadata: Metadata
        let article: KnowledgeArticle?
    }

    private struct Inventory {
        var notes: [String: Metadata] = [:]
        var topLevelDirectories: Set<String> = []
        var visitedEntries = 0
        var complete = true
        var warnings: Set<String> = []
    }

    public init(vault: ObsidianVault) {
        self.vault = vault
    }

    /// The first successful capture establishes a baseline. Later captures return new versions only.
    /// A failed scan leaves the baseline intact; bounded partial scans never infer deletions.
    public func capture() throws -> KnowledgeFolderSnapshot {
        guard (vault.rootPath as NSString).isAbsolutePath, vault.rootPath != "/" else {
            throw folderError("请选择有效的知识库文件夹。")
        }
        let root = open(vault.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw folderError("无法读取知识库文件夹，请检查位置和访问权限。") }
        defer { close(root) }
        var rootStatus = stat()
        guard fstat(root, &rootStatus) == 0 else { throw scanError() }
        var inventory = Inventory()
        try enumerate(directory: root, path: "", depth: 0, inventory: &inventory)

        let capturedRootIdentity = Metadata(rootStatus).identity
        let replacedRoot = hasBaseline && rootIdentity != capturedRootIdentity
        if replacedRoot { inventory.warnings.insert("知识库文件夹已替换，已重新建立基线。") }
        var next = replacedRoot ? [:] : files
        var nextArticleIndex = replacedRoot ? [:] : articleIndex
        if inventory.complete {
            next = next.filter { inventory.notes[$0.key] != nil }
            nextArticleIndex = nextArticleIndex.filter { inventory.notes[$0.key] != nil }
        }
        var retainedBytes = next.values.reduce(0) { $0 + $1.byteCount }
        for path in inventory.notes.keys.sorted() {
            guard let metadata = inventory.notes[path] else { continue }
            guard metadata.size >= 0, metadata.size <= Self.maximumNoteBytes else {
                inventory.warnings.insert("部分笔记超过 256 KiB，暂未读取其正文。")
                continue
            }
            let previousBytes = next[path]?.byteCount ?? 0
            let canCacheBody = retainedBytes - previousBytes + Int(metadata.size) <= Self.maximumContentBytes
                && (next[path] != nil || next.count < Self.maximumNotes)
            let canIndexArticle = nextArticleIndex[path] != nil || nextArticleIndex.count < Self.maximumNotes
            if !canCacheBody {
                inventory.warnings.insert("知识库超过读取预算，部分笔记暂未纳入变更预览。")
            }
            if !canIndexArticle { inventory.warnings.insert("文章索引达到上限，部分文章暂未纳入列表。") }
            // Uncached bodies must not block article discovery. Retain metadata for nonarticles too,
            // so unchanged files outside the body budget do not need to be read on every capture.
            guard canCacheBody && next[path]?.metadata != metadata
                || canIndexArticle && nextArticleIndex[path]?.metadata != metadata else { continue }
            guard let content = try readNote(path, root: root, expected: metadata) else {
                inventory.warnings.insert("部分笔记不是 UTF-8 文本，暂未读取其正文。")
                continue
            }
            if canIndexArticle {
                nextArticleIndex[path] = ArticleEntry(metadata: metadata, article: KnowledgeArticle(path: path, content: content))
            }
            if canCacheBody {
                let note = Note(metadata: metadata, content: content)
                next[path] = note
                retainedBytes += note.byteCount - previousBytes
            }
        }
        // A moved/replaced root must not publish edits under its old location.
        var currentRoot = stat()
        guard lstat(vault.rootPath, &currentRoot) == 0, currentRoot.st_mode & S_IFMT == S_IFDIR,
              Metadata(currentRoot).identity == capturedRootIdentity else { throw scanError() }

        revision += 1
        let changes = hasBaseline && !replacedRoot ? changes(from: files, to: next) : []
        files = next
        articleIndex = nextArticleIndex
        sections = folderSections(inventory, preserving: replacedRoot ? [] : sections)
        rootIdentity = capturedRootIdentity
        hasBaseline = true
        let articles = nextArticleIndex.values.compactMap(\.article).sorted {
            $0.collectedAt == $1.collectedAt ? $0.path < $1.path : $0.collectedAt > $1.collectedAt
        }
        return KnowledgeFolderSnapshot(changes: changes, noteCount: inventory.notes.count,
                                       warnings: inventory.warnings.sorted(), sections: sections, articles: articles)
    }

    private func folderSections(_ inventory: Inventory, preserving previousSections: [KnowledgeFolderSection]) -> [KnowledgeFolderSection] {
        var counts: [String: Int] = [:]
        for path in inventory.notes.keys {
            let section = path.firstIndex(of: "/").map { String(path[..<$0]) } ?? ""
            counts[section, default: 0] += 1
        }
        var current = Dictionary(uniqueKeysWithValues: inventory.topLevelDirectories.map { path in
            (path, KnowledgeFolderSection(relativePath: path, name: path, noteCount: counts[path, default: 0]))
        })
        // A capped traversal cannot establish that an old category or its notes disappeared.
        if !inventory.complete {
            for previous in previousSections { current[previous.relativePath] = previous }
        }
        return current.values.sorted { $0.relativePath < $1.relativePath }
    }

    private func enumerate(directory: Int32, path: String, depth: Int, inventory: inout Inventory) throws {
        guard depth <= 128 else {
            inventory.complete = false
            inventory.warnings.insert("部分目录层级过深，暂未纳入变更预览。")
            return
        }
        // Every descent is relative to an already validated directory descriptor.
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw scanError() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw scanError() }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw scanError() }
                return
            }
            inventory.visitedEntries += 1
            guard inventory.visitedEntries <= Self.maximumEntries else {
                inventory.complete = false
                inventory.warnings.insert("目录扫描达到上限，部分笔记暂未纳入变更预览。")
                return
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, !name.hasPrefix(".") else { continue }
            let relative = path.isEmpty ? name : path + "/" + name
            guard relative.utf8.count <= 4_096 else {
                inventory.complete = false
                inventory.warnings.insert("部分笔记路径过长，暂未纳入变更预览。")
                continue
            }
            var status = stat()
            guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw scanError() }
            if status.st_mode & S_IFMT == S_IFDIR {
                if path.isEmpty { inventory.topLevelDirectories.insert(name) }
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw scanError() }
                do { try enumerate(directory: child, path: relative, depth: depth + 1, inventory: &inventory) }
                catch { close(child); throw error }
                close(child)
                if !inventory.complete, inventory.visitedEntries > Self.maximumEntries
                    || inventory.notes.count >= Self.maximumNotes { return }
            } else if !path.isEmpty, status.st_mode & S_IFMT == S_IFREG,
                      (name as NSString).pathExtension.lowercased() == "md" {
                guard inventory.notes.count < Self.maximumNotes else {
                    inventory.complete = false
                    inventory.warnings.insert("目录扫描达到上限，部分笔记暂未纳入变更预览。")
                    return
                }
                inventory.notes[relative] = Metadata(status)
            }
        }
    }

    private func readNote(_ path: String, root: Int32, expected: Metadata) throws -> String? {
        let components = path.split(separator: "/").map(String.init)
        var parent = dup(root)
        guard parent >= 0 else { throw scanError() }
        defer { close(parent) }
        for name in components.dropLast() {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw scanError() }
            close(parent)
            parent = child
        }
        guard let name = components.last else { throw scanError() }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw scanError() }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              Metadata(before) == expected else { throw scanError() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= Self.maximumNoteBytes {
            let count = read(descriptor, &buffer, min(buffer.count, Self.maximumNoteBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw scanError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count <= Self.maximumNoteBytes, fstat(descriptor, &after) == 0,
              Metadata(after) == expected, data.count == Int(expected.size) else { throw scanError() }
        return String(data: data, encoding: .utf8)
    }

    private func changes(from old: [String: Note], to new: [String: Note]) -> [CodexRecordedFileChange] {
        let removed = Set(old.keys).subtracting(new.keys)
        let added = Set(new.keys).subtracting(old.keys)
        let oldIdentities = Dictionary(grouping: old.keys) { old[$0]!.metadata.identity }
        let newIdentities = Dictionary(grouping: new.keys) { new[$0]!.metadata.identity }
        var movedDestinations: Set<String> = []
        var result: [CodexRecordedFileChange] = []
        for path in removed.sorted() {
            guard let previous = old[path] else { continue }
            let identity = previous.metadata.identity
            if oldIdentities[identity]?.count == 1, newIdentities[identity]?.count == 1,
               let destination = newIdentities[identity]?.first, added.contains(destination), let note = new[destination] {
                movedDestinations.insert(destination)
                result.append(change(path: path, movePath: destination, kind: "update", before: previous.content, after: note.content))
            } else {
                result.append(change(path: path, kind: "delete", before: previous.content, after: ""))
            }
        }
        for path in new.keys.sorted() where !movedDestinations.contains(path) {
            guard let note = new[path] else { continue }
            if let previous = old[path] {
                if previous.content != note.content {
                    result.append(change(path: path, kind: "update", before: previous.content, after: note.content))
                }
            } else {
                result.append(change(path: path, kind: "add", before: "", after: note.content))
            }
        }
        return result.sorted { ($0.movePath ?? $0.path) < ($1.movePath ?? $1.path) }
    }

    private func change(path: String, movePath: String? = nil, kind: String, before: String, after: String) -> CodexRecordedFileChange {
        let version = SHA256.hash(data: Data(after.utf8)).map { String(format: "%02x", $0) }.joined()
        let turnID = "folder-\(trackerID)-\(revision)"
        return CodexRecordedFileChange(id: "\(turnID):\(path)", turnID: turnID, itemID: path, path: path,
            kind: kind, movePath: movePath, diff: boundedDiff(before: before, after: after, path: path, movePath: movePath),
            status: "completed", diffFingerprint: version)
    }

    /// Common prefix/suffix trimming is linear, including for thousands of repeated lines.
    /// Each changed side gets its own budget so a large deletion cannot hide the added text.
    private func boundedDiff(before: String, after: String, path: String, movePath: String?) -> String {
        var output = "--- \(path)\n+++ \(movePath ?? path)\n"
        if before == after { return output + "内容未改变。\n" }
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        output += "@@ -\(start + 1),\(oldEnd - start) +\(start + 1),\(newEnd - start) @@\n"
        let sideBudget = max(0, (Self.maximumDiffBytes - output.utf8.count - 256) / 2)
        for (prefix, lines) in [("-", old[start..<oldEnd]), ("+", new[start..<newEnd])] {
            var used = 0
            var count = 0
            for line in lines {
                let text = prefix + line + "\n"
                guard count < 160, used + text.utf8.count <= sideBudget else {
                    output += "… 差异过长，剩余内容未展示。\n"
                    break
                }
                output += text
                used += text.utf8.count
                count += 1
            }
        }
        return output
    }

    private func scanError() -> NSError {
        folderError("知识库正在变化或部分文件暂时无法读取，已保留上次结果，请刷新重试。")
    }

    private func folderError(_ message: String) -> NSError {
        NSError(domain: "CodexBar.KnowledgeFolder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message, NSFilePathErrorKey: vault.rootPath])
    }
}
