import AppKit
import CodexBarCore
import SwiftUI

struct GitWorkspaceBrowserView: View {
    @ObservedObject var model: GitWorkspaceBrowserModel
    @State private var creation: WorktreeCreationSource?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("项目与 Worktree").font(.headline)
                Spacer()
                if model.isBusy || model.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(model.isBusy ? "正在执行 Git 操作" : "正在刷新工作目录")
                }
                Button(action: chooseProject) { Label("添加项目", systemImage: "folder.badge.plus") }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("workspace-add-project")
                Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy || model.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("读取工作目录、Git 分支及外部创建的 worktree")
            }
            .padding(16)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 260, idealWidth: 330)
                details.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("关闭提示") { model.errorMessage = nil }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Git 操作提示")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $creation) { source in
            WorktreeCreationView(model: model, source: source) { creation = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("创建层级")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(12)
            if model.snapshot.records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未添加项目").font(.headline)
                    Text("选择已有的 Git 项目目录，查看分支并创建 worktree。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择项目目录…", action: chooseProject).disabled(model.isBusy)
                }
                .padding(16)
                Spacer()
            } else {
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.rows) { row in workspaceRow(row) }
                        }
                        .frame(
                            minWidth: max(geometry.size.width - 12, 250 + CGFloat(model.rows.map(\.depth).max() ?? 0) * 18),
                            minHeight: max(0, geometry.size.height - 12), alignment: .topLeading
                        )
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                    }
                    .accessibilityLabel("项目与工作目录树")
                    .onMoveCommand(perform: moveSelection)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func workspaceRow(_ row: GitWorkspaceBrowserRow) -> some View {
        let identity = model.snapshot.identities[row.id]
        let selected = model.activeDirectory == row.id
        let name = URL(fileURLWithPath: row.id).lastPathComponent
        let branch = identity?.branch ?? "目录不可用"
        return Button { model.selectDirectory(row.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                if row.depth > 0 {
                    Text("↳").fixedSize().foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Image(systemName: row.record.isMainWorkspace ? "folder" : "arrow.triangle.branch")
                    .frame(width: 16)
                    .foregroundStyle(identity == nil ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(name) · \(branch)")
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .fixedSize(horizontal: true, vertical: false)
                    if row.hasUnknownOrigin {
                        Text("创建来源未知").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(row.depth) * 18 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.id)
        .accessibilityLabel("\(name)，\(branch)，第 \(row.depth + 1) 层\(row.hasUnknownOrigin ? "，创建来源未知" : "")")
        .accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityIdentifier("workspace-node:\(row.id)")
    }

    @ViewBuilder
    private var details: some View {
        if let directory = model.activeDirectory,
           let record = model.snapshot.records.first(where: { $0.workspaceRoot == directory }) {
            ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.isMainWorkspace ? "项目目录" : "Worktree")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: directory).lastPathComponent)
                        .font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(directory).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                branchBar
                if model.activeIdentity == nil {
                    Label("工作目录不存在或 Git 元数据不可用。恢复目录后点击刷新。", systemImage: "folder.badge.questionmark")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("创建来源").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if record.isMainWorkspace {
                        Text("项目主目录")
                    } else if let parent = record.parentWorkspaceRoot {
                        Text(parent).textSelection(.enabled)
                    } else {
                        Text("未知 · 从 Git 导入的既有 worktree")
                    }
                }
                .font(.callout)
                HStack {
                    Button {
                        creation = WorktreeCreationSource(directory: directory)
                    } label: {
                        Label("创建子 Worktree…", systemImage: "plus")
                    }
                    .disabled(model.isBusy || model.activeIdentity == nil)
                    .accessibilityIdentifier("workspace-create")
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                    }
                    .disabled(model.activeIdentity == nil)
                }
                Text("子节点记录从哪个工作目录创建。切换分支后，目录及创建层级保持原位。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
              }
              .padding(24)
              .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("选择一个工作目录").font(.title3)
                Text("在这里查看分支、切换分支和创建 worktree。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var branchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("当前目录的分支").font(.caption).foregroundStyle(.secondary)
                Text(model.activeIdentity?.branch ?? "不可用")
                    .font(.headline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-current-branch")
            }
            Spacer(minLength: 6)
            if model.isLoadingBranches { ProgressView().controlSize(.small) }
            Menu("切换分支") {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        guard let directory = model.activeDirectory else { return }
                        Task { await model.switchBranch(branch, in: directory) }
                    } label: {
                        if branch == model.activeIdentity?.branch {
                            Label(branch, systemImage: "checkmark")
                        } else { Text(branch) }
                    }
                    .disabled(branch == model.activeIdentity?.branch)
                }
                if model.branches.isEmpty { Text("暂无本地分支") }
                Divider()
                Button("刷新分支", action: model.refresh)
            }
            .fixedSize()
            .disabled(model.isBusy || model.activeIdentity == nil || model.isLoadingBranches)
            .accessibilityIdentifier("workspace-switch-branch")
            .help("切换所选工作目录的本地分支；Git 会保留或拒绝覆盖未提交的修改")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "添加 Git 项目"
        panel.prompt = "添加项目"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            Task { await model.addProject(directory) }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let rows = model.rows
        guard let selected = rows.firstIndex(where: { $0.id == model.activeDirectory }) else { return }
        let destination: String?
        switch direction {
        case .up: destination = selected > 0 ? rows[selected - 1].id : nil
        case .down: destination = selected + 1 < rows.count ? rows[selected + 1].id : nil
        case .left: destination = rows[selected].record.parentWorkspaceRoot
        case .right:
            destination = rows.first(where: { $0.record.parentWorkspaceRoot == rows[selected].id })?.id
        @unknown default: destination = nil
        }
        if let destination { model.selectDirectory(destination) }
    }
}

private struct WorktreeCreationSource: Identifiable {
    let id = UUID()
    let directory: String
}

private struct WorktreeCreationView: View {
    @ObservedObject var model: GitWorkspaceBrowserModel
    let source: WorktreeCreationSource
    let dismiss: () -> Void
    @State private var branch = ""
    @State private var directoryName = ""
    @State private var parentDirectory: URL?

    private var parent: URL {
        parentDirectory ?? URL(fileURLWithPath: source.directory).deletingLastPathComponent()
    }
    private var validInput: Bool {
        !branch.isEmpty && !directoryName.isEmpty && directoryName != "." && directoryName != ".."
            && !directoryName.contains("/") && !directoryName.contains("\0")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建子 Worktree").font(.title2.weight(.semibold))
            Text("创建来源：\(source.directory)")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("新分支从来源目录当前的提交创建。未提交的文件修改不会复制到新目录。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                TextField("新分支名称", text: $branch)
                    .accessibilityLabel("新分支名称")
                    .accessibilityIdentifier("workspace-new-branch")
                TextField("工作目录名称", text: $directoryName)
                    .accessibilityLabel("工作目录名称")
                    .accessibilityIdentifier("workspace-new-directory")
                HStack {
                    Text("保存到：\(parent.path)").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("选择位置…", action: chooseParent)
                }
            }
            .disabled(model.isBusy)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(model.isBusy ? "正在创建…" : "创建 Worktree") {
                    let destination = parent.appendingPathComponent(directoryName, isDirectory: true)
                    Task {
                        await model.createWorktree(from: source.directory, at: destination, branch: branch)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !validInput)
                .accessibilityIdentifier("workspace-confirm-create")
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            directoryName = URL(fileURLWithPath: source.directory).lastPathComponent + "-worktree"
            model.errorMessage = nil
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "选择 Worktree 保存位置"
        panel.prompt = "选择位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.begin { response in
            if response == .OK { parentDirectory = panel.url }
        }
    }
}
