import CodexBarCore
import Combine
import Foundation

@main
@MainActor
struct KnowledgeReviewStoreChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-store-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("Test note".utf8).write(to: root.appendingPathComponent("One.md"))
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let task = CodexTask(id: "task", sessionID: "session", turnID: "turn", cwd: root.path,
            workspaceName: "Vault", title: "Organize notes", status: .ready, startedAt: Date(), updatedAt: Date(), isUnread: false)
        let worker = KnowledgeReviewWorker(defaultsSuiteName: suite)
        let store = KnowledgeReviewStore()
        let registered = await worker.synchronize(tasks: [task])
        precondition(registered.requestedSnapshots == ["session"], "Vault was not registered before hover")
        store.receive(registered.reviews, revision: registered.revision)
        precondition(store.review(for: task)?.isLoading == true)

        func frame(_ diff: String, revision: Int = 1, kind: String = "update") throws -> Data {
            let edit: [String: Any] = ["id": "edit", "type": "fileChange", "status": "completed",
                "changes": [["path": "One.md", "kind": kind, "diff": diff]]]
            let state: [String: Any] = ["id": "session", "sessionId": "session", "source": "vscode", "cwd": root.path,
                "resumeState": "resumed", "turnsPagination": ["hasLoadedOldest": true],
                "turns": [["turnId": "turn", "items": [edit]]]]
            return try JSONSerialization.data(withJSONObject: [
                "type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "owner",
                "params": ["conversationId": "session", "hostId": "local", "change": [
                    "type": "snapshot", "revision": revision, "conversationState": state
                ]]
            ])
        }
        let loaded = await worker.consume(try frame("-old\n+new"))
        store.receive(loaded.reviews, revision: loaded.revision)
        precondition(store.pendingCounts["session"] == 1, "Unhovered task did not get a pending count")
        let note = loaded.reviews["session"]!.notes[0]
        let reviewed = await worker.toggleReview(noteID: note.id, sessionID: "session", expectedVersion: note.version)
        store.receive(reviewed.reviews, revision: reviewed.revision)
        store.receive(loaded.reviews, revision: loaded.revision)
        precondition(store.pendingCounts["session"] == 0, "An older async result reversed review")
        let previewStore = ConversationPreviewStore()
        previewStore.clear()
        precondition(store.pendingCounts["session"] == 0, "Closing preview cleared review state")
        let opened = await worker.openURL(noteID: note.id, sessionID: "session")
        precondition(opened?.scheme == "obsidian", "Existing vault note did not produce a URI")

        var publications = 0
        let observation = store.$reviews.dropFirst().sink { _ in publications += 1 }
        let duplicate = await worker.consume(try frame("-old\n+new", revision: 2))
        store.receive(duplicate.reviews, revision: duplicate.revision)
        precondition(publications == 0, "Identical content unnecessarily republished")
        let disconnected = await worker.unavailable(["session"])
        precondition(disconnected.reviews["session"]?.pendingCount == 0 && disconnected.reviews["session"]?.message != nil,
                     "Disconnect lost receipts or hid stale state")
        let reconnected = await worker.synchronize(tasks: [task], refresh: true)
        precondition(reconnected.requestedSnapshots == ["session"], "Refresh did not request knowledge snapshot")
        let restoredWorker = KnowledgeReviewWorker(defaultsSuiteName: suite)
        _ = await restoredWorker.synchronize(tasks: [task])
        let restored = await restoredWorker.consume(try frame("-old\n+new"))
        precondition(restored.reviews["session"]?.pendingCount == 0, "Review receipts did not persist")
        let changed = await restoredWorker.consume(try frame("-new\n+later", revision: 2))
        precondition(changed.reviews["session"]?.pendingCount == 1, "Later edit stayed reviewed")
        let staleClick = await restoredWorker.toggleReview(noteID: note.id, sessionID: "session", expectedVersion: note.version)
        precondition(staleClick.reviews["session"]?.pendingCount == 1, "A stale click marked an unseen revision reviewed")
        let lateTimeout = await restoredWorker.expireLoading()
        precondition(lateTimeout.reviews["session"]?.message == nil, "Loading timeout invalidated a completed snapshot")
        _ = await restoredWorker.consume(try frame("-later", revision: 3, kind: "delete"))
        let deletedURL = await restoredWorker.openURL(noteID: note.id, sessionID: "session")
        precondition(deletedURL == nil, "Deleted record still opened a note")
        let removed = await restoredWorker.synchronize(tasks: [])
        precondition(removed.reviews.isEmpty, "Closed workspace retained a live subscription")
        withExtendedLifetime(observation) {}
        print("PASS knowledge background registration, versioned review, publication ordering, preview lifetime, receipt restoration, URI and removal")
    }
}
