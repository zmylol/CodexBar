import CodexBarCore
import SwiftUI

/// A local conversation preview with a stationary header and footer.
struct TaskDetailCard: View {
    let task: CodexTask
    let summary: CodexTaskDetailSummary
    let preview: CodexConversationPreview?
    let state: ConversationPreviewLoadState
    let message: String?
    let isLoadingHistory: Bool
    let onOpen: () -> Void
    let onRefreshPreview: () -> Void
    let onLoadHistory: () -> Void
    var knowledge: KnowledgeVaultReview? = nil
    var onToggleReview: (KnowledgeNoteChange) -> Void = { _ in }
    var onOpenNote: (KnowledgeNoteChange) -> Void = { _ in }

    @State private var showsConversation = false
    @State private var selectedNoteID: String?
    @State private var isFollowingLatest = true
    @State private var firstVisibleItemID: String?
    @State private var requestedHistoryAnchorID: String?
    @State private var historyWasLoading = false

    private let initialItemCount = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if let knowledge {
                knowledgeTabs
                Divider().opacity(0.4)
                if !showsConversation {
                    KnowledgeChangesView(
                        review: knowledge,
                        selectedNoteID: $selectedNoteID,
                        onToggleReview: onToggleReview,
                        onOpenNote: onOpenNote,
                        onOpenConversation: onOpen
                    )
                } else {
                    conversationContent
                    Divider().opacity(0.4)
                    footer
                }
            } else {
                conversationContent
                Divider().opacity(0.4)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ConversationHistoryUpdate(
            itemIDs: preview?.items.map(\.id) ?? [], isLoading: isLoadingHistory
        )) { update in
            if update.isLoading, !historyWasLoading, requestedHistoryAnchorID == nil {
                requestedHistoryAnchorID = update.itemIDs.first
            }
            historyWasLoading = update.isLoading
            revealRequestedHistory(itemIDs: update.itemIDs)
            if !update.isLoading { requestedHistoryAnchorID = nil }
        }
    }

    @ViewBuilder
    private var conversationContent: some View {
            if let preview, !preview.items.isEmpty {
                let firstIndex = firstVisibleIndex(in: preview)
                ConversationPreviewScrollView(
                    itemIDs: preview.items[firstIndex...].map(\.id),
                    isFollowingLatest: $isFollowingLatest,
                    onApproachTop: { showEarlierItems(in: preview) }
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        if firstIndex > 0 {
                            Button("显示较早内容（还有 \(firstIndex) 条）") {
                                showEarlierItems(in: preview)
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 26)
                        } else if !preview.historyComplete {
                            historyButton
                        }
                        ForEach(preview.items[firstIndex...]) { item in
                            ConversationItemView(item: item) {
                                isFollowingLatest = false
                                if item.kind == .tool { onRefreshPreview() }
                            }
                            .equatable()
                            .conversationPreviewItemAnchor(item.id)
                        }
                        if state == .unavailable {
                            availabilityNotice
                        } else if let message {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("会话内容")
                .onAppear {
                    if firstVisibleItemID == nil {
                        firstVisibleItemID = preview.items[firstIndex].id
                    }
                }
            } else {
                emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
    }

    private var knowledgeTabs: some View {
        HStack(spacing: 4) {
            knowledgeTab("变更", conversation: false)
            knowledgeTab("会话", conversation: true)
            Spacer(minLength: 4)
            if let knowledge {
                Text(knowledge.pendingCount == 0 ? "全部已回看" : "\(knowledge.pendingCount) 条待回看")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("knowledge-pending-count")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func knowledgeTab(_ label: String, conversation: Bool) -> some View {
        Button { showsConversation = conversation } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 26)
                .background(showsConversation == conversation ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsConversation == conversation ? "已选中" : "未选中")
        .accessibilityIdentifier(conversation ? "knowledge-tab-conversation" : "knowledge-tab-changes")
    }

    private func firstVisibleIndex(in preview: CodexConversationPreview) -> Int {
        if let firstVisibleItemID,
           let index = preview.items.firstIndex(where: { $0.id == firstVisibleItemID }) {
            return index
        }
        return max(0, preview.items.count - initialItemCount)
    }

    private func showEarlierItems(in preview: CodexConversationPreview) {
        let firstIndex = firstVisibleIndex(in: preview)
        guard firstIndex > 0 else { return }
        isFollowingLatest = false
        firstVisibleItemID = preview.items[max(0, firstIndex - initialItemCount)].id
    }

    private func revealRequestedHistory(itemIDs: [String]) {
        guard let requestedHistoryAnchorID,
              let index = itemIDs.firstIndex(of: requestedHistoryAnchorID),
              index > 0 else { return }
        firstVisibleItemID = itemIDs[max(0, index - initialItemCount)]
        self.requestedHistoryAnchorID = nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(knowledge?.vault.name ?? task.workspaceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(knowledge == nil ? "会话预览" : "知识库 · 已识别变更")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Label(task.status.label, systemImage: task.status.symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(task.status.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var historyButton: some View {
        Button {
            isFollowingLatest = false
            requestedHistoryAnchorID = preview?.items.first?.id
            onLoadHistory()
        } label: {
            HStack(spacing: 6) {
                if isLoadingHistory {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text(isLoadingHistory ? "正在加载较早内容…" : "加载较早内容")
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isLoadingHistory)
    }

    private var availabilityNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message ?? "连接暂不可用，显示已接收内容。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button("重试", action: onRefreshPreview)
                .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state == .loading || state == .idle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取会话内容…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if state == .unavailable {
                availabilityNotice
            } else {
                Text("尚未收到会话正文")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(task.title)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
            if let detail = summary.focusDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                isFollowingLatest.toggle()
            } label: {
                Label(
                    isFollowingLatest ? "跟随最新" : "回到最新",
                    systemImage: isFollowingLatest ? "arrow.down.to.line" : "arrow.down"
                )
                .font(.system(size: 11, weight: .medium))
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFollowingLatest ? Color.secondary : Color.accentColor)
            .disabled(preview?.items.isEmpty != false)
            .accessibilityValue(isFollowingLatest ? "自动跟随已开启" : "自动跟随已暂停")
            .accessibilityHint(isFollowingLatest ? "暂停自动滚动，保留当前阅读位置" : "滚动到最新内容并恢复自动跟随")
            Spacer(minLength: 4)
            Button(action: onOpen) {
                Label("切到项目", systemImage: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("knowledge-open-conversation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ConversationHistoryUpdate: Equatable {
    let itemIDs: [String]
    let isLoading: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Tail updates do not change which earlier items should become visible.
        lhs.itemIDs.first == rhs.itemIDs.first && lhs.isLoading == rhs.isLoading
    }
}

private struct ConversationItemView: View, Equatable {
    let item: CodexConversationItem
    let onExpand: () -> Void

    @State private var isExpanded = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        Group {
            switch item.kind {
            case .assistant:
                VStack(alignment: .leading, spacing: 7) {
                    roleLabel("Codex", symbol: "sparkle")
                    ConversationMarkdownView(text: item.text)
                }
            case .user:
                VStack(alignment: .leading, spacing: 7) {
                    expansionButton(title: "你", symbol: "person")
                    if isExpanded {
                        ConversationMarkdownView(text: item.text)
                    } else {
                        Text(item.text)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            case .tool:
                VStack(alignment: .leading, spacing: 8) {
                    expansionButton(title: item.title, symbol: item.isError ? "exclamationmark.circle" : "terminal")
                    if isExpanded {
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !item.text.isEmpty {
                            Text(item.text)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else if item.isRunning {
                            Text("等待工具输出…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
            case .information:
                VStack(alignment: .leading, spacing: 5) {
                    if !item.title.isEmpty { roleLabel(item.title, symbol: "info.circle") }
                    ConversationMarkdownView(text: item.text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func roleLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func expansionButton(title: String, symbol: String) -> some View {
        Button {
            isExpanded.toggle()
            if isExpanded { onExpand() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(item.isError ? Color.orange : .secondary)
                Text(title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.isRunning {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("工具正在运行")
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        .accessibilityHint(isExpanded ? "收起完整内容" : "展开完整内容")
    }
}
