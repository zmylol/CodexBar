import CodexBarCore
import SwiftUI

struct KnowledgeLibraryView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: KnowledgeLibraryModel
    let onChooseVault: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void

    @State private var selectedSectionID: String?
    @FocusState private var focusedItemID: String?

    private var selectedSection: KnowledgeFolderSection? {
        model.sections.first { $0.id == selectedSectionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.22)

            if let message = model.message ?? model.review?.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("knowledge-library-message")
            }

            if model.review == nil {
                chooseVault
            } else if model.sections.isEmpty {
                emptySections
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(model.sections) { section in
                                    categoryRow(section)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                        }
                        .frame(width: min(170, max(120, geometry.size.width * 0.3)))
                        .accessibilityLabel("知识库分类")
                        .accessibilityIdentifier("knowledge-library-sections")
                        Divider().opacity(0.22)
                        articleDetail
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.20 : 0))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.24 : 0.65),
                                 Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onExitCommand(perform: onClose)
        .onHover(perform: onHoverChanged)
        .onChange(of: model.review?.vault.rootPath) { _ in
            selectedSectionID = nil
            focusedItemID = nil
        }
        .onChange(of: model.sections.map(\.id)) { ids in
            if let selectedSectionID, !ids.contains(selectedSectionID) {
                self.selectedSectionID = nil
                focusedItemID = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日新增")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("今日新增")
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            if model.review != nil {
                Button(action: onChooseVault) {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更换知识库总目录")
                .accessibilityIdentifier("knowledge-library-change-vault")
                .help(model.review?.vault.rootPath ?? "更换知识库总目录")

                Button(action: model.refresh) {
                    if model.isLoading {
                        ProgressView().controlSize(.mini)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
                .disabled(model.isLoading)
                .accessibilityLabel("刷新知识库")
                .accessibilityIdentifier("knowledge-library-refresh")
                .help("刷新知识库")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭知识库")
            .accessibilityIdentifier("knowledge-library-close")
            .help("关闭（Esc）")
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    private func categoryRow(_ section: KnowledgeFolderSection) -> some View {
        let isSelected = selectedSectionID == section.id
        let unseenCount = model.unseenCount(in: section.id)
        return Button {
            guard !model.isChoosingVault else { return }
            selectedSectionID = section.id
            model.markUpdatesSeen(in: section.id)
        } label: {
            HStack(spacing: 6) {
                Text(section.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if unseenCount > 0 {
                    Text("\(unseenCount)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($focusedItemID, equals: "section:\(section.id)")
        .keyboardShortcut(activationShortcut(for: "section:\(section.id)"))
        .accessibilityLabel(section.name + (unseenCount > 0 ? "，\(unseenCount) 篇未查看" : ""))
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("查看今日新增文章并清除此知识库的提醒")
        .accessibilityIdentifier("knowledge-library-row-\(section.id)")
    }

    @ViewBuilder private var articleDetail: some View {
        if let section = selectedSection {
            let articles = model.todayArticles.filter { $0.path.hasPrefix(section.id + "/") }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                    Text("今日新增")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 12)
                if articles.isEmpty {
                    Text("今日暂无新增")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("knowledge-library-empty-\(section.id)")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(articles) { article in
                                articleRow(article)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .id(section.id)
                    .accessibilityLabel("\(section.name)今日新增文章")
                    .accessibilityIdentifier("knowledge-library-article-list")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("选择知识库查看今日新增")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("knowledge-library-select-section")
        }
    }

    private func articleRow(_ article: KnowledgeArticle) -> some View {
        Button {
            model.openArticle(article)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let summary = article.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($focusedItemID, equals: "note:\(article.id)")
        .keyboardShortcut(activationShortcut(for: "note:\(article.id)"))
        .accessibilityLabel(article.title)
        .accessibilityValue(article.summary ?? "")
        .accessibilityHint("在 Obsidian 打开文章")
        .accessibilityIdentifier("knowledge-note-\(article.id)")
        .help(article.path)
    }

    private func activationShortcut(for id: String) -> KeyboardShortcut? {
        focusedItemID == id ? KeyboardShortcut(.space, modifiers: []) : nil
    }

    private var emptySections: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(model.isLoading ? "正在读取知识库…" : "暂无知识库分类")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("knowledge-library-empty-sections")
    }

    private var chooseVault: some View {
        VStack(spacing: 12) {
            Text("查看知识库今日新增的文章")
                .font(.system(size: 13, weight: .medium))
            Text("选择 Obsidian 知识库总目录，按分类查看今日收录。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("选择知识库总目录", action: onChooseVault)
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
                .accessibilityIdentifier("knowledge-library-choose")
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
