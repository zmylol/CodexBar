import AppKit
import CodexBarCore
import SwiftUI

@MainActor private final class DemoState: ObservableObject {
    @Published var scene = 0
    @Published var generation = 0
    let appModel = CodexBarAppModel()

    init() {
        appModel.onActivate = { [weak self] in self?.scene = 1 }
        appModel.knowledgeLibrary.onSeen = { [weak self] in
            if self?.scene == 2 { self?.scene = 3 }
        }
        appModel.knowledgeLibrary.onArrival = { [weak self] in self?.scene = 4 }
    }

    func next() {
        if scene == 3 { appModel.knowledgeLibrary.refresh() }
        else if scene == 4 { reset() }
        else { scene += 1 }
    }

    func reset() {
        appModel.knowledgeLibrary.reset()
        generation += 1
        scene = 0
    }

    var title: String {
        ["几个项目，\n一眼看清。", "读完结果，\n继续创造。", "新知识，\n有数可查。", "点开即看，\n提醒归零。", "新的文章，\n来了就知道。"][scene]
    }
    var detail: String {
        ["执行中、需要处理、可查看回复。\n把 Codex 的进展留在视线里。",
         "原生会话预览，支持 Markdown。\n工具输出按需展开。",
         "按知识库分类，只看今日收录。\n数字告诉你还有几篇没看。",
         "标题和一段摘要，快速了解内容。\n点击知识库后，它的数字消失。",
         "稍后收录的文章带着摘要到达。\n刚看过的知识库也会再次提醒。"][scene]
    }
}

private struct MarketingDemoView: View {
    @ObservedObject var state: DemoState

    private var preview: CodexConversationPreview {
        CodexConversationPreview(sessionID: "demo-Notes", cwd: "/demo/projects/notes", items: [
            CodexConversationItem(id: "request", kind: .user, title: "你",
                                  text: "给笔记应用加上即时搜索，让找到灵感更轻松。"),
            CodexConversationItem(id: "reply", kind: .assistant, title: "Codex",
                                  text: "### 搜索体验已完成\n现在输入关键词，就能即时找到相关笔记。\n\n- 支持标题与正文搜索\n- 高亮匹配的关键词\n- 键盘方向键切换结果\n\n```swift\nlet matches = notes.search(query)\n```\n\n可以回到项目试一下搜索手感。"),
            CodexConversationItem(id: "tool", kind: .tool, title: "工具完成 · 演示输出",
                                  text: "✓ Title search\n✓ Content search\n✓ Keyboard navigation\n3 demo checks passed", detail: "$ run-demo-checks")
        ], historyComplete: true, revision: 1)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.10),
                                    Color(red: 0.09, green: 0.10, blue: 0.20),
                                    Color(red: 0.035, green: 0.13, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.indigo.opacity(0.25)).frame(width: 540, height: 540)
                .blur(radius: 100).offset(x: 390, y: -240)
            Circle().fill(Color.teal.opacity(0.14)).frame(width: 470, height: 470)
                .blur(radius: 100).offset(x: 140, y: 280)

            VStack(alignment: .leading, spacing: 0) {
                masthead
                HStack(alignment: .center, spacing: 24) {
                    introduction.frame(width: 280, alignment: .leading)
                    stage.frame(width: 620, height: 548)
                }
                .frame(maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
        }
        .frame(width: 1024, height: 760)
        .preferredColorScheme(.dark)
    }

    private var masthead: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading,
                                           endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            Text("CodexBar").font(.system(size: 23, weight: .semibold, design: .rounded))
            Spacer()
            Text("KEEP THE VIBE. KEEP THE CONTEXT.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.1).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(String(format: "%02d", state.scene + 1) + " / 05")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.47, green: 0.81, blue: 0.88))
            Text(state.title).font(.system(size: 37, weight: .semibold))
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text(state.detail).font(.system(size: 13)).lineSpacing(8)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Capsule().fill(index == state.scene ? Color.teal : Color.white.opacity(0.15))
                        .frame(width: index == state.scene ? 26 : 7, height: 5)
                }
            }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stage: some View {
        if state.scene >= 2 {
            KnowledgeLibraryView(model: state.appModel.knowledgeLibrary,
                                 onChooseVault: {}, onHoverChanged: { _ in }, onClose: {})
                .id(state.generation)
                .frame(width: 600, height: 520)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
        } else if state.scene == 1 {
            HStack(alignment: .top, spacing: 14) {
                taskBar.frame(width: 126, height: 112).padding(.top, 60)
                TaskDetailCard(task: state.appModel.store.tasks[2],
                               summary: CodexTaskDetailSummary(task: state.appModel.store.tasks[2], plan: nil, activities: []),
                               preview: preview, state: .ready, message: nil, isLoadingHistory: false,
                               onOpen: {}, onRefreshPreview: {}, onLoadHistory: {})
                    .frame(width: 420, height: 466)
                    .background(VisualEffectBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
            }
            .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
        } else {
            ZStack(alignment: .trailing) {
                projectBackdrop.frame(width: 480, height: 344)
                    .rotationEffect(.degrees(-3)).offset(x: -52, y: 18)
                VStack(spacing: 16) {
                    taskBar.frame(width: 126, height: 112)
                        .scaleEffect(1.7)
                        .frame(width: 215, height: 190)
                    Text("真实悬浮条 · 放大展示")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }.offset(x: -6, y: -12)
            }
        }
    }

    private var taskBar: some View {
        TaskListView(model: state.appModel,
                     onTaskHoverChanged: { _, _, _ in },
                     onTaskDetailRequested: { _, _ in state.scene = 1 },
                     onKnowledgeRequested: { state.scene = 2 })
    }

    private var projectBackdrop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.65)).frame(width: 8, height: 8)
                }
                Text("YOUR NEXT IDEA").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(.white.opacity(0.4)).padding(.leading, 12)
                Spacer()
            }.padding(18)
            Divider().opacity(0.15)
            VStack(alignment: .leading, spacing: 15) {
                Text("Build something\nyou want to use.")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.74))
                    .lineSpacing(4)
                ForEach([0.8, 1.0, 0.65], id: \.self) { width in
                    Capsule().fill(.white.opacity(0.07)).frame(width: 245 * width, height: 8)
                }
                Text("项目场景示意").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 10)
            }.padding(28)
            Spacer()
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.teal)
            Text("原生界面 · 虚构示例数据 · 合成背景")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46))
            Spacer()
            Button("重播", action: state.reset)
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
                .accessibilityIdentifier("demo-reset")
            Button(action: state.next) {
                Image(systemName: "arrow.right").frame(width: 30, height: 24)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("下一幕").accessibilityIdentifier("demo-next")
        }
        .font(.system(size: 10))
    }
}

@main private struct MarketingDemo {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 CodexBar Public Demo",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menuBar.addItem(appMenuItem)
        app.mainMenu = menuBar
        let state = DemoState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 760),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "CodexBar · Public Demo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.035, green: 0.055, blue: 0.10, alpha: 1)
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MarketingDemoView(state: state))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
