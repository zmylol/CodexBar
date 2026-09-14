import Foundation

@MainActor
public struct StartupTaskReconciler {
    private let store: TaskStore
    private let worker: StartupTaskRecoveryWorker

    public init(
        store: TaskStore,
        matcher: VSCodeWindowMatcher = VSCodeWindowMatcher()
    ) {
        self.store = store
        self.worker = StartupTaskRecoveryWorker(matcher: matcher)
    }

    /// Reconciles persisted VS Code turns that belong to windows open right now.
    /// Hook state always wins for the same turn; a newer different turn may
    /// replace an old row during startup recovery.
    @discardableResult
    public func reconcile(
        snapshots: [CodexThreadSnapshot],
        windows: [VSCodeWindowDescriptor]
    ) async throws -> Int {
        let recoveredTasks = await worker.recoveredTasks(
            snapshots: snapshots,
            windows: windows
        )
        guard !Task.isCancelled else {
            return 0
        }
        return try await store.mergeRecoveredTasks(recoveredTasks)
    }
}

private actor StartupTaskRecoveryWorker {
    private let matcher: VSCodeWindowMatcher

    init(matcher: VSCodeWindowMatcher) {
        self.matcher = matcher
    }

    func recoveredTasks(
        snapshots: [CodexThreadSnapshot],
        windows: [VSCodeWindowDescriptor]
    ) -> [CodexTask] {
        guard !Task.isCancelled else {
            return []
        }
        var latestByCWD: [String: CodexThreadSnapshot] = [:]
        let latestAllowedDate = Date().addingTimeInterval(7 * 24 * 60 * 60)

        for snapshot in snapshots {
            guard !Task.isCancelled else {
                return []
            }
            guard let normalized = normalizedSnapshot(
                snapshot,
                latestAllowedDate: latestAllowedDate
            ) else {
                continue
            }
            if let current = latestByCWD[normalized.cwd],
               !isNewer(normalized, than: current) {
                continue
            }
            latestByCWD[normalized.cwd] = normalized
        }

        var candidatesByWindowID: [Int: [CodexThreadSnapshot]] = [:]
        for snapshot in latestByCWD.values {
            guard !Task.isCancelled else {
                return []
            }
            let window: VSCodeWindowDescriptor
            switch matcher.match(cwd: snapshot.cwd, windows: windows) {
            case let .matched(candidate):
                window = candidate
            case let .ambiguous(candidates):
                guard candidates.allSatisfy({ $0.workspace != nil }),
                      let candidate = candidates.min(by: { $0.id < $1.id }) else { continue }
                // Shared roots identify one session even when several windows contain it.
                window = candidate
            case .notFound:
                continue
            }
            candidatesByWindowID[window.id, default: []].append(snapshot)
        }

        let workspaceWindowIDs = Set(windows.filter { $0.workspaceFolderPaths != nil }.map(\.id))
        return candidatesByWindowID.flatMap { windowID, candidates -> [CodexTask] in
            // Explicit folder membership supports multiple tasks in one workspace.
            // A title alone cannot distinguish different paths with the same name.
            guard candidates.count == 1 || workspaceWindowIDs.contains(windowID) else {
                return []
            }
            return candidates.compactMap { task(from: $0) }
        }
    }

    private func normalizedSnapshot(
        _ snapshot: CodexThreadSnapshot,
        latestAllowedDate: Date
    ) -> CodexThreadSnapshot? {
        guard validIdentifier(snapshot.sessionID),
              validIdentifier(snapshot.turnID),
              let cwd = PathNormalizer.normalize(snapshot.cwd),
              snapshot.startedAt.timeIntervalSince1970.isFinite,
              snapshot.updatedAt.timeIntervalSince1970.isFinite,
              snapshot.startedAt.timeIntervalSince1970 >= 0,
              snapshot.startedAt <= snapshot.updatedAt,
              snapshot.updatedAt <= latestAllowedDate
        else {
            return nil
        }

        return CodexThreadSnapshot(
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            cwd: cwd,
            title: snapshot.title,
            status: snapshot.status,
            startedAt: snapshot.startedAt,
            updatedAt: snapshot.updatedAt
        )
    }

    private func task(from snapshot: CodexThreadSnapshot) -> CodexTask? {
        let workspaceComponent = URL(fileURLWithPath: snapshot.cwd).lastPathComponent
        guard let workspaceName = PromptSanitizer.sanitizeDisplayText(
            workspaceComponent,
            maxLength: 160
        ) else {
            return nil
        }

        let title = PromptSanitizer.sanitize(snapshot.title, maxLength: 80)
            ?? workspaceName
        let status: CodexTaskStatus
        switch snapshot.status {
        case .inProgress:
            status = .running
        case .completed, .interrupted, .failed:
            status = .ready
        }

        return CodexTask(
            id: "\(snapshot.sessionID):\(snapshot.turnID)",
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            cwd: snapshot.cwd,
            workspaceName: workspaceName,
            title: title,
            status: status,
            startedAt: snapshot.startedAt,
            updatedAt: snapshot.updatedAt,
            isUnread: false
        )
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 512
    }

    private func isNewer(
        _ candidate: CodexThreadSnapshot,
        than current: CodexThreadSnapshot
    ) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        if candidate.startedAt != current.startedAt {
            return candidate.startedAt > current.startedAt
        }
        if candidate.sessionID != current.sessionID {
            return candidate.sessionID > current.sessionID
        }
        return candidate.turnID > current.turnID
    }
}
