import CodexBarCore
import Combine
import Foundation

@main
@MainActor
struct PreviewStoreCheck {
    static func main() {
        let store = ConversationPreviewStore()
        var publications = 0
        let observation = store.$preview.dropFirst().sink { _ in publications += 1 }
        func preview(_ revision: Int, text: String = "same body", complete: Bool = true) -> CodexConversationPreview {
            CodexConversationPreview(sessionID: "test-session", cwd: "/tmp/preview-check", items: [
                CodexConversationItem(id: "test-item", kind: .assistant, title: "Codex", text: text)
            ], historyComplete: complete, revision: revision)
        }
        store.receive(preview(1))
        precondition(publications == 1, "Initial body was not published")
        store.receive(preview(2))
        precondition(publications == 1, "Revision-only change republished the entire body")
        precondition(store.latestRevision == 2, "Suppressed rendering lost history revision progress")
        store.receive(preview(2, text: "fresh output at same revision"))
        precondition(publications == 2, "Same-revision output refresh was suppressed")
        store.receive(preview(3, text: "fresh output at same revision", complete: false))
        precondition(publications == 3, "History availability change was suppressed")
        store.clear()
        precondition(store.preview == nil && store.latestRevision == nil, "Dismissal retained conversation metadata")
        withExtendedLifetime(observation) {}
        print("PASS preview publication deduplication, revision progress, same-revision output, history flag, clear")
    }
}
