import AppKit
import CodexBarCore
import SwiftUI

extension CodexTaskStatus {
    var label: String { "可查看" }
    var symbolName: String { "checkmark.circle" }
    var color: Color { .green }
}

@MainActor private final class KnowledgeViewFixture: ObservableObject {
    @Published var review: KnowledgeVaultReview
    var toggledIDs: [String] = []
    var openedIDs: [String] = []
    var openedConversation = false

    init() {
        review = KnowledgeVaultReview(
            vault: ObsidianVault(rootPath: "/fixture/vault", name: "示例知识库"),
            notes: [
                KnowledgeNoteChange(id: "new", path: "方法/渐进式总结.md", previousPath: nil, kind: "add", diff: "+ # 渐进式总结\n+ 先保留原句，再提炼观点。", isReviewed: false),
                KnowledgeNoteChange(id: "update", path: "方法/阅读工作流.md", previousPath: nil, kind: "update", diff: "- 只保留摘录。\n+ 写下自己的结论。", isReviewed: false),
                KnowledgeNoteChange(id: "move", path: "主题/注意力预算.md", previousPath: "收件箱/注意力预算.md", kind: "move", diff: nil, isReviewed: false)
            ],
            isLoading: false,
            message: "仅展示已识别的笔记变更。"
        )
    }

    func toggle(_ note: KnowledgeNoteChange) {
        toggledIDs.append(note.id)
        review = KnowledgeVaultReview(
            vault: review.vault,
            notes: review.notes.map { item in
                KnowledgeNoteChange(id: item.id, path: item.path, previousPath: item.previousPath, kind: item.kind, diff: item.diff, isReviewed: item.id == note.id ? !item.isReviewed : item.isReviewed)
            },
            isLoading: review.isLoading,
            message: review.message
        )
    }
}

private struct KnowledgeViewFixtureRoot: View {
    @ObservedObject var fixture: KnowledgeViewFixture
    let task = CodexTask(id: "fixture", sessionID: "fixture", turnID: "turn", cwd: "/fixture/vault", workspaceName: "示例知识库", title: "整理阅读笔记", status: .ready, startedAt: Date(), updatedAt: Date(), isUnread: true)

    var body: some View {
        TaskDetailCard(
            task: task,
            summary: CodexTaskDetailSummary(task: task, plan: nil, activities: []),
            preview: nil,
            state: .ready,
            message: nil,
            isLoadingHistory: false,
            onOpen: { fixture.openedConversation = true },
            onRefreshPreview: {},
            onLoadHistory: {},
            knowledge: fixture.review,
            onToggleReview: { fixture.toggle($0) },
            onOpenNote: { fixture.openedIDs.append($0.id) }
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }
}

/// Native controls only; no Accessibility permission or real notes are required.
@main struct KnowledgeReviewViewChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed", line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL knowledge view line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor static func element(_ identifier: String, in parent: Any) -> AnyObject? {
        // SwiftUI's virtual accessibility nodes expose selectors without declaring
        // the complete NSAccessibilityProtocol conformance used by NSView.
        let accessible = parent as AnyObject
        if accessible.accessibilityIdentifier?() == identifier { return accessible }
        for child in accessible.accessibilityChildren?() ?? [] {
            if let found = element(identifier, in: child) { return found }
        }
        return nil
    }

    @MainActor static func press(_ identifier: String, in view: NSView) {
        guard let control = element(identifier, in: view) else { fatalError("Missing control: \(identifier)") }
        check(control.accessibilityPerformPress?() == true, "Control did not accept press: \(identifier)")
        settle()
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let fixture = KnowledgeViewFixture()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 520), styleMask: .titled, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: KnowledgeViewFixtureRoot(fixture: fixture))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Could not capture native fixture") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode fixture screenshot") }
        do { try png.write(to: URL(fileURLWithPath: "/tmp/codexbar-knowledge-native.png")) }
        catch { fatalError("Could not save native fixture screenshot: \(error)") }
        check(abs(host.frame.width - 420) < 1 && abs(host.frame.height - 520) < 1)
        // Some standalone macOS sessions do not create SwiftUI's AX tree. Preserve
        // real rendering checks and report the interaction boundary explicitly.
        if (host.accessibilityChildren() ?? []).isEmpty {
            window.orderOut(nil)
            window.contentView = nil
            print("PASS knowledge native rendering: 420×520 fixture and screenshot")
            print("SKIP knowledge native actions: this graphical session did not expose a SwiftUI accessibility tree; button and keyboard interactions require manual verification")
            return
        }
        check(element("knowledge-review-toggle", in: host) != nil, "Vault preview must start on changes")
        press("knowledge-note-update", in: host)
        press("knowledge-review-toggle", in: host)
        check(fixture.toggledIDs == ["update"] && fixture.review.pendingCount == 2)
        press("knowledge-review-toggle", in: host)
        check(fixture.review.pendingCount == 3, "Unmarking must restore pending count")
        press("knowledge-note-move", in: host)
        press("knowledge-open-note", in: host)
        check(fixture.openedIDs == ["move"], "Open action must receive the selected moved note")
        press("knowledge-tab-conversation", in: host)
        check(element("knowledge-review-toggle", in: host) == nil, "Conversation tab must hide change controls")
        press("knowledge-tab-changes", in: host)
        press("knowledge-review-toggle", in: host)
        check(fixture.toggledIDs.last == "move", "Tab switch must preserve selected note")
        press("knowledge-open-conversation", in: host)
        check(fixture.openedConversation, "Return to Codex must use the existing activation action")
        check(abs(host.frame.width - 420) < 1 && abs(host.frame.height - 520) < 1)
        fixture.review = KnowledgeVaultReview(vault: fixture.review.vault, notes: [], isLoading: true, message: nil)
        settle()
        check(element("knowledge-review-toggle", in: host) == nil, "Loading an empty review must not expose a stale selected note")
        let deleted = KnowledgeNoteChange(id: "deleted", path: "旧笔记.md", previousPath: nil, kind: "delete", diff: nil, isReviewed: false)
        fixture.review = KnowledgeVaultReview(vault: fixture.review.vault, notes: [deleted], isLoading: false, message: "连接暂不可用，显示上次读取的记录。")
        settle()
        guard let openDeleted = element("knowledge-open-note", in: host) else { fatalError("Missing disabled open control") }
        check(openDeleted.isAccessibilityEnabled?() == false, "Deleted notes must not offer an active open action")
        press("knowledge-review-toggle", in: host)
        check(fixture.toggledIDs.last == "deleted", "Removed selection must fall back to the current note")
        window.orderOut(nil)
        window.contentView = nil
        print("PASS knowledge review view: default changes, selection, mark/unmark counts, moved note open, tab retention, conversation action, empty loading, deleted note, 420×520 layout")
    }
}
