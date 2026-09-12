import CodexBarCore
import Combine
import Foundation

@MainActor
final class KnowledgeReviewStore: ObservableObject {
    @Published private(set) var reviews: [String: KnowledgeVaultReview] = [:]
    private(set) var pendingCounts: [String: Int] = [:]
    private var latestRevision = -1

    func review(for task: CodexTask) -> KnowledgeVaultReview? { reviews[task.sessionID] }

    func receive(_ next: [String: KnowledgeVaultReview], revision: Int? = nil) {
        if let revision {
            guard revision > latestRevision else { return }
            latestRevision = revision
        } else { latestRevision = -1 }
        guard reviews != next else { return }
        pendingCounts = next.mapValues(\.pendingCount)
        reviews = next
    }
}

struct KnowledgeReviewUpdate: Sendable {
    var reviews: [String: KnowledgeVaultReview]
    var requestedSnapshots: Set<String> = []
    var revision: Int = 0
}

/// All discovery, stream projection, path checks and fingerprints stay off the UI actor.
actor KnowledgeReviewWorker {
    private static let receiptKey = "codexbar.knowledgeReviewedVersions"
    private var reducer = CodexKnowledgeChangesReducer()
    private var sessions: [String: String] = [:]
    private var ledgers: [String: KnowledgeReviewLedger] = [:]
    private var reviews: [String: KnowledgeVaultReview] = [:]
    private var latestChanges: [String: [CodexRecordedFileChange]] = [:]
    private var receiptList: [String]
    private var revision = 0
    private let defaults: UserDefaults

    init(defaultsSuiteName: String? = nil) {
        let defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = defaults
        receiptList = Array((defaults.stringArray(forKey: Self.receiptKey) ?? [])
            .filter { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }.suffix(2_048))
    }

    func synchronize(tasks: [CodexTask], refresh: Bool = false) -> KnowledgeReviewUpdate {
        let requested = Dictionary(tasks.map { ($0.sessionID, $0.cwd) }, uniquingKeysWith: { _, latest in latest })
        var next: [String: String] = [:]
        var discovered: [String: ObsidianVault] = [:]
        for (session, cwd) in requested.sorted(by: { $0.key < $1.key }) {
            let vault = sessions[session] == cwd && !refresh ? ledgers[session]?.vault : ObsidianVault.discover(cwd: cwd)
            guard let vault else { continue }
            discovered[session] = vault
            if next.count < 8 { next[session] = cwd }
        }
        var snapshots: Set<String> = []
        for (session, cwd) in next {
            guard let vault = discovered[session] else { continue }
            if sessions[session] != cwd || ledgers[session]?.vault != vault {
                ledgers[session] = KnowledgeReviewLedger(vault: vault, scopeID: session,
                                                       reviewedVersions: Set(receiptList))
                latestChanges.removeValue(forKey: session)
                reviews[session] = KnowledgeVaultReview(vault: vault, notes: [], isLoading: true, message: nil)
                snapshots.insert(session)
            } else if refresh {
                reducer.reset(sessionID: session)
                snapshots.insert(session)
            }
        }
        sessions = next
        ledgers = ledgers.filter { next[$0.key] != nil }
        latestChanges = latestChanges.filter { next[$0.key] != nil }
        reviews = reviews.filter { discovered[$0.key] != nil }
        for (session, vault) in discovered where next[session] == nil {
            reviews[session] = KnowledgeVaultReview(vault: vault, notes: [], isLoading: false,
                message: "同时跟随的知识库会话已达 8 个，请关闭不需要的 VS Code 窗口后刷新。")
        }
        reducer.setSessions(next)
        return update(requestedSnapshots: snapshots)
    }

    func consume(_ data: Data) -> KnowledgeReviewUpdate {
        let result = reducer.consume(data)
        if let session = result.invalidatedSessionID { setUnavailable(session) }
        if let snapshot = result.snapshot, var ledger = ledgers[snapshot.sessionID] {
            if latestChanges[snapshot.sessionID] != snapshot.changes {
                ledger.receive(snapshot.changes, cwd: snapshot.cwd)
                ledgers[snapshot.sessionID] = ledger
                latestChanges[snapshot.sessionID] = snapshot.changes
            }
            let message: String?
            if snapshot.isTruncated || ledger.isTruncated {
                message = "部分变更超过预览容量，当前清单不完整；请回到 Codex 查看。"
            } else if !snapshot.historyComplete {
                message = "仅显示已收到的文件修改；较早记录可在会话页加载。"
            } else { message = nil }
            reviews[snapshot.sessionID] = KnowledgeVaultReview(vault: ledger.vault, notes: ledger.notes,
                                                              isLoading: false, message: message)
        }
        return update(requestedSnapshots: result.resnapshotSessionID.map { [$0] } ?? [])
    }

    func unavailable(_ sessionIDs: Set<String>) -> KnowledgeReviewUpdate {
        for session in sessionIDs {
            reducer.reset(sessionID: session)
            setUnavailable(session)
        }
        return update()
    }

    func expireLoading() -> KnowledgeReviewUpdate {
        // Snapshot delivery and expiry are ordered on this actor, so a late timer
        // cannot invalidate a snapshot that finished while it was waiting.
        for session in reviews.keys where reviews[session]?.isLoading == true {
            reducer.reset(sessionID: session)
            setUnavailable(session)
        }
        return update()
    }

    func toggleReview(noteID: String, sessionID: String, expectedVersion: String) -> KnowledgeReviewUpdate {
        guard var ledger = ledgers[sessionID],
              ledger.notes.contains(where: { $0.id == noteID && $0.version == expectedVersion }) else { return update() }
        let previous = ledger.reviewedVersions
        ledger.toggleReview(noteID: noteID)
        ledgers[sessionID] = ledger
        let removed = previous.subtracting(ledger.reviewedVersions)
        receiptList.removeAll { removed.contains($0) }
        for added in ledger.reviewedVersions.subtracting(previous).sorted() {
            receiptList.removeAll { $0 == added }
            receiptList.append(added)
        }
        receiptList = Array(receiptList.suffix(2_048))
        defaults.set(receiptList, forKey: Self.receiptKey)
        let old = reviews[sessionID]
        reviews[sessionID] = KnowledgeVaultReview(vault: ledger.vault, notes: ledger.notes,
                                                isLoading: old?.isLoading ?? false, message: old?.message)
        return update()
    }

    func openURL(noteID: String, sessionID: String) -> URL? {
        guard let ledger = ledgers[sessionID],
              let note = ledger.notes.first(where: { $0.id == noteID }), note.kind != "delete",
              let relative = ledger.vault.notePath(note.path, cwd: ledger.vault.rootPath) else { return nil }
        let file = URL(fileURLWithPath: ledger.vault.rootPath).appendingPathComponent(relative)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return ledger.vault.openURL(notePath: relative)
    }

    private func setUnavailable(_ session: String) {
        guard let ledger = ledgers[session] else { return }
        reviews[session] = KnowledgeVaultReview(vault: ledger.vault, notes: ledger.notes, isLoading: false,
            message: "变更连接暂不可用，保留上次读取的记录；请刷新重试。")
    }

    private func update(requestedSnapshots: Set<String> = []) -> KnowledgeReviewUpdate {
        revision += 1
        return KnowledgeReviewUpdate(reviews: reviews, requestedSnapshots: requestedSnapshots, revision: revision)
    }
}
