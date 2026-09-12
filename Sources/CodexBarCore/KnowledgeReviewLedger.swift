import CryptoKit
import Foundation

public struct KnowledgeNoteChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let previousPath: String?
    public let kind: String
    public let diff: String?
    public let isReviewed: Bool
    public let version: String

    public init(id: String, path: String, previousPath: String?, kind: String, diff: String?, isReviewed: Bool, version: String = "") {
        self.id = id
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.diff = diff
        self.isReviewed = isReviewed
        self.version = version
    }
}

public struct KnowledgeVaultReview: Equatable, Sendable {
    public let vault: ObsidianVault
    public let notes: [KnowledgeNoteChange]
    public let isLoading: Bool
    public let message: String?
    public var pendingCount: Int { notes.lazy.filter { !$0.isReviewed }.count }

    public init(vault: ObsidianVault, notes: [KnowledgeNoteChange], isLoading: Bool, message: String?) {
        self.vault = vault
        self.notes = notes
        self.isLoading = isLoading
        self.message = message
    }
}

/// Review state independent of the task's runtime/unread status.
/// Diffs stay in memory; only version fingerprints are suitable for persistence.
public struct KnowledgeReviewLedger: Sendable {
    public static let maximumRecords = 512
    public static let maximumBytes = 4 * 1_024 * 1_024
    public let vault: ObsidianVault
    public private(set) var notes: [KnowledgeNoteChange] = []
    public private(set) var reviewedVersions: Set<String>
    public private(set) var isTruncated = false
    public var pendingCount: Int { notes.lazy.filter { !$0.isReviewed }.count }

    /// Current note versions ordered by their most recent recorded change.
    public var recentNotes: [KnowledgeNoteChange] {
        var remaining = Dictionary(uniqueKeysWithValues: notes.map { ($0.path, $0) })
        return records.reversed().compactMap { remaining.removeValue(forKey: $0.path) }
    }

    private let scopeID: String
    private var records: [Record] = []
    private var noteVersions: [String: String] = [:]

    private struct Record: Equatable, Sendable {
        let id: String
        let path: String
        let previousPath: String?
        let kind: String
        let diff: String?
        let version: String
        var byteCount: Int { id.utf8.count + path.utf8.count + (previousPath?.utf8.count ?? 0) + (diff?.utf8.count ?? 0) + 256 }
    }

    public init(vault: ObsidianVault, scopeID: String = "", reviewedVersions: Set<String> = []) {
        self.vault = vault
        self.scopeID = scopeID
        self.reviewedVersions = Set(reviewedVersions.sorted().prefix(2_048))
    }

    public mutating func receive(_ changes: [CodexRecordedFileChange], cwd: String) {
        let incoming = projectedRecords(changes, cwd: cwd)
        // Historical entries precede their next known anchor, so loading old history
        // cannot replace a newer edit with an older diff or resurrect a moved source.
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let knownIDs = Set(records.map(\.id))
        var merged = records.map { incomingByID[$0.id] ?? $0 }
        var pending: [Record] = []
        for record in incoming {
            if knownIDs.contains(record.id) {
                if !pending.isEmpty, let index = merged.firstIndex(where: { $0.id == record.id }) {
                    merged.insert(contentsOf: pending, at: index)
                    pending.removeAll(keepingCapacity: true)
                }
            } else { pending.append(record) }
        }
        merged.append(contentsOf: pending)
        guard merged.count <= Self.maximumRecords,
              merged.reduce(0, { $0 + $1.byteCount }) <= Self.maximumBytes else {
            isTruncated = true
            return
        }
        guard records != merged else { return }
        records = merged
        rebuildNotes()
    }

    /// Folder captures arrive chronologically and need only the latest version of each note.
    /// Evict oldest notes at capacity so a long-running folder never stops accepting new edits.
    public mutating func receiveLatest(_ changes: [CodexRecordedFileChange], cwd: String) {
        var latest: [Record] = []
        var retainedBytes = 0
        for var record in records + projectedRecords(changes, cwd: cwd) {
            if record.byteCount > Self.maximumBytes {
                record = Record(id: record.id, path: record.path, previousPath: record.previousPath,
                                kind: record.kind, diff: nil, version: record.version)
                isTruncated = true
            }
            guard record.byteCount <= Self.maximumBytes else { continue }
            // Repeated delivery must not change review state or promote an old edit to newest.
            if latest.contains(record) { continue }
            latest.removeAll { existing in
                let replaced = existing.id == record.id || existing.path == record.path
                    || existing.path == record.previousPath
                if replaced { retainedBytes -= existing.byteCount }
                return replaced
            }
            latest.append(record)
            retainedBytes += record.byteCount
            while latest.count > Self.maximumRecords || retainedBytes > Self.maximumBytes {
                retainedBytes -= latest.removeFirst().byteCount
                isTruncated = true
            }
        }
        reviewedVersions.formIntersection(Set(latest.map(\.version)))
        guard records != latest else { return }
        records = latest
        rebuildNotes()
    }

    public mutating func toggleReview(noteID: String) {
        guard let version = noteVersions[noteID] else { return }
        if !reviewedVersions.insert(version).inserted { reviewedVersions.remove(version) }
        if reviewedVersions.count > 2_048 {
            reviewedVersions = Set(reviewedVersions.filter { $0 != version }.sorted().prefix(2_047))
            reviewedVersions.insert(version)
        }
        rebuildNotes()
    }

    private mutating func rebuildNotes() {
        var latest: [String: Record] = [:]
        for record in records {
            if let previous = record.previousPath { latest.removeValue(forKey: previous) }
            latest[record.path] = record
        }
        noteVersions.removeAll(keepingCapacity: true)
        notes = latest.values.map { record in
            let id = fingerprint([vault.rootPath, record.path])
            noteVersions[id] = record.version
            return KnowledgeNoteChange(id: id, path: record.path, previousPath: record.previousPath,
                                       kind: record.kind, diff: record.diff, isReviewed: reviewedVersions.contains(record.version),
                                       version: record.version)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func projectedRecords(_ changes: [CodexRecordedFileChange], cwd: String) -> [Record] {
        var incoming: [Record] = []
        var seen: Set<String> = []
        for change in changes where change.status == "completed" {
            guard let path = vault.notePath(change.movePath ?? change.path, cwd: cwd),
                  let original = vault.notePath(change.path, cwd: cwd),
                  seen.insert(change.id).inserted else { continue }
            let kind = change.movePath != nil ? "move" : change.kind
            guard ["add", "update", "delete", "move"].contains(kind) else { continue }
            let version = fingerprint([scopeID, vault.rootPath, change.id, path, original, kind,
                                       change.diffFingerprint ?? change.diff ?? "<unavailable>"])
            incoming.append(Record(id: change.id, path: path, previousPath: kind == "move" ? original : nil,
                                   kind: kind, diff: change.diff, version: version))
        }
        return incoming
    }

    private func fingerprint(_ parts: [String]) -> String {
        var hash = SHA256()
        for part in parts {
            hash.update(data: Data("\(part.utf8.count):".utf8))
            hash.update(data: Data(part.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
