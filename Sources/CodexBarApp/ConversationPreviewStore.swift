import CodexBarCore
import Combine
import Foundation

enum ConversationPreviewLoadState: Equatable {
    case idle
    case loading
    case ready
    case unavailable
}

/// Only the currently displayed conversation is retained, and only in memory.
@MainActor
final class ConversationPreviewStore: ObservableObject {
    @Published var preview: CodexConversationPreview?
    @Published var state: ConversationPreviewLoadState = .idle
    @Published var isLoadingHistory = false
    @Published var message: String?
    private(set) var latestRevision: Int?

    func receive(_ next: CodexConversationPreview) {
        latestRevision = next.revision
        // Revision-only traffic still advances history loading, without re-laying out the body.
        if preview?.sessionID != next.sessionID || preview?.cwd != next.cwd
            || preview?.historyComplete != next.historyComplete || preview?.items != next.items {
            preview = next
        }
    }

    func clear() {
        latestRevision = nil
        preview = nil
        state = .idle
        isLoadingHistory = false
        message = nil
    }
}

actor ConversationPreviewWorker {
    private var reducer: CodexConversationPreviewReducer

    init(sessionID: String, cwd: String) {
        reducer = CodexConversationPreviewReducer(sessionID: sessionID, cwd: cwd)
    }

    func consume(_ data: Data) -> CodexConversationPreviewResult {
        reducer.consume(data)
    }
}
