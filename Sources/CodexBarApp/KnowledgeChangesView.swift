import CodexBarCore
import SwiftUI

/// Review state belongs to the knowledge store, independently of task unread state.
struct KnowledgeChangesView: View {
    let review: KnowledgeVaultReview
    @Binding var selectedNoteID: String?
    let onToggleReview: (KnowledgeNoteChange) -> Void
    let onOpenNote: (KnowledgeNoteChange) -> Void
    let onOpenConversation: () -> Void
    var emptyMessage = "这里展示已收到的文件修改；命令或其他工具写入的内容可能尚未覆盖。"

    @FocusState private var focusedNoteID: String?
    private let maximumDiffCharacters = 32_000

    private var selectedNote: KnowledgeNoteChange? {
        review.notes.first { $0.id == selectedNoteID } ?? review.notes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if review.isLoading { ProgressView().controlSize(.mini) }
                Text(review.isLoading ? "正在读取知识库变更…" : "已识别 \(review.notes.count) 篇笔记变更")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if let message = review.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let selectedNote {
                noteList
                Divider().opacity(0.4)
                difference(for: selectedNote)
                Divider().opacity(0.4)
                actions(for: selectedNote)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.isLoading ? "等待变更内容" : "尚未识别到笔记变更")
                        .font(.system(size: 12, weight: .medium))
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                Divider().opacity(0.4)
                HStack { Spacer(); conversationButton }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .onChange(of: review.notes.map(\.id)) { ids in
            if let selectedNoteID, !ids.contains(selectedNoteID) { self.selectedNoteID = ids.first }
        }
    }

    private var noteList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(review.notes) { note in
                        Button {
                            selectedNoteID = note.id
                            focusedNoteID = note.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: note.isReviewed ? "checkmark.circle.fill" : "doc.text")
                                    .foregroundStyle(note.isReviewed ? Color.secondary : Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((note.path as NSString).lastPathComponent)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(note.path)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Text("\(kindLabel(note.kind)) · \(note.isReviewed ? "已回看" : "待回看")")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(selectedNote?.id == note.id ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .focusable(true)
                        .focused($focusedNoteID, equals: note.id)
                        .accessibilityLabel("\(note.path)，\(kindLabel(note.kind))，\(note.isReviewed ? "已回看" : "待回看")")
                        .accessibilityValue(selectedNote?.id == note.id ? "已选中" : "未选中")
                        .accessibilityIdentifier("knowledge-note-\(note.id)")
                        .onMoveCommand { direction in
                            guard direction == .up || direction == .down,
                                  let index = review.notes.firstIndex(where: { $0.id == note.id }) else { return }
                            let next = min(max(0, index + (direction == .down ? 1 : -1)), review.notes.count - 1)
                            selectedNoteID = review.notes[next].id
                            focusedNoteID = selectedNoteID
                            proxy.scrollTo(review.notes[next].id)
                        }
                        .id(note.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: min(CGFloat(review.notes.count) * 47 + 6, 147))
            .accessibilityLabel("已识别变更的笔记")
        }
    }

    private func difference(for note: KnowledgeNoteChange) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text((note.path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("最近一次差异")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if let previousPath = note.previousPath {
                    Text("原位置：\(previousPath)\n新位置：\(note.path)")
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                }
                if let diff = note.diff, !diff.isEmpty {
                    Text(String(diff.prefix(maximumDiffCharacters)))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    if diff.count > maximumDiffCharacters {
                        Text("差异较长，仅显示前 \(maximumDiffCharacters) 个字符；可打开笔记查看正文。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("未收到正文差异，可打开笔记查看当前内容。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .id(note.id)
        .accessibilityLabel("\(note.path) 最近一次差异")
    }

    private func actions(for note: KnowledgeNoteChange) -> some View {
        HStack(spacing: 8) {
            Button(note.isReviewed ? "已回看 · 取消" : "标记已回看") { onToggleReview(note) }
                .accessibilityIdentifier("knowledge-review-toggle")
                .accessibilityValue(note.isReviewed ? "已回看" : "待回看")
            Spacer(minLength: 0)
            Button("打开笔记") { onOpenNote(note) }
                .disabled(note.kind == "delete")
                .accessibilityLabel("在 Obsidian 打开笔记")
                .accessibilityIdentifier("knowledge-open-note")
            conversationButton
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var conversationButton: some View {
        Button("回到 Codex", action: onOpenConversation)
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("knowledge-open-conversation")
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "add": "新增"
        case "delete": "删除"
        case "move": "移动"
        default: "更新"
        }
    }
}
