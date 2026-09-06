import AppKit
import CodexBarCore
import SwiftUI

extension CodexTaskStatus {
    var label: String { "执行中" }
    var symbolName: String { "circle.fill" }
    var color: Color { .blue }
}
@MainActor private final class PreviewPerformanceState: ObservableObject {
    @Published var preview: CodexConversationPreview
    @Published var isLoadingHistory = false
    var historyRequests = 0
    init(count: Int) {
        preview = CodexConversationPreview(sessionID: "fixture", cwd: "/fixture", items: (0..<count).map { i in
            if i % 5 == 0 { return CodexConversationItem(id: "\(i)", kind: .user, title: "你", text: "核实这次修改，保留所有正文并保证滚动位置稳定。重复点击和流式回复都需要正常工作。") }
            if i % 5 == 2 || i % 5 == 3 { return CodexConversationItem(id: "\(i)", kind: .tool, title: "工具完成 · 退出码 0", text: String(repeating: "Verification output: passed.\n", count: 80), detail: "$ verify fixture --count 80") }
            return CodexConversationItem(id: "\(i)", kind: .assistant, title: "Codex", text: "### 第 \(i) 条验证\n已经读取相关实现，下面是**结果**与下一步。这个回复模拟真实项目中的较长说明，并且包含列表、引用和代码片段。\n\n- 展示完整的正文和 `aggregatedOutput`。\n- 用户向上滚动后，流式内容保持原来的阅读位置。\n- 接收快照时仍保留已展开工具。\n\n```swift\nlet count = values.count\nfor value in values {\n    print(value)\n}\n```\n\n这段话用于模拟完成后的总结，默认展开助手信息，工具结果按需展开。")
        }, historyComplete: true, revision: 1)
    }
    func appendText() {
        var items = preview.items
        let old = items.removeLast()
        items.append(CodexConversationItem(id: old.id, kind: old.kind, title: old.title, text: old.text + "\n追加的流式文字，确保同一消息的高度和文本发生变化。", detail: old.detail, isError: old.isError, isRunning: old.isRunning))
        preview = CodexConversationPreview(sessionID: preview.sessionID, cwd: preview.cwd, items: items, historyComplete: true, revision: preview.revision + 1)
    }

    func loadHistory() {
        historyRequests += 1
        let earlier = PreviewPerformanceState(count: 60).preview.items.map { item in
            CodexConversationItem(id: "earlier-" + item.id, kind: item.kind, title: item.title, text: item.text, detail: item.detail)
        }
        preview = CodexConversationPreview(sessionID: preview.sessionID, cwd: preview.cwd, items: earlier + preview.items, historyComplete: true, revision: preview.revision + 1)
        isLoadingHistory = false
    }
}
private struct PreviewPerformanceRoot: View {
    @ObservedObject var state: PreviewPerformanceState
    let task = CodexTask(id: "fixture", sessionID: "fixture", turnID: "turn", cwd: "/fixture", workspaceName: "Fixture", title: "Performance fixture", status: .running, startedAt: Date(), updatedAt: Date(), isUnread: false)
    var body: some View {
        TaskDetailCard(task: task, summary: CodexTaskDetailSummary(task: task, plan: nil, activities: []), preview: state.preview, state: .ready, message: nil, isLoadingHistory: state.isLoadingHistory, onOpen: {}, onRefreshPreview: {}, onLoadHistory: { state.isLoadingHistory = true })
    }
}

/// Synthetic content only. Timings are observations, not hardware-dependent pass thresholds.
@main struct PreviewPerformanceChecks {
    @MainActor static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(child) { return scroll }
        }
        return nil
    }

    @MainActor static func settle() -> Double {
        let deadline = Date().addingTimeInterval(0.4)
        var longestTurn = 0.0
        while Date() < deadline {
            let start = DispatchTime.now().uptimeNanoseconds
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            longestTurn = max(longestTurn, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return longestTurn
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed", line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL preview check line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @MainActor static func verifyLoadedHistory() {
        let state = PreviewPerformanceState(count: 30)
        state.preview = CodexConversationPreview(sessionID: "fixture", cwd: "/fixture", items: state.preview.items, historyComplete: false, revision: 1)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: PreviewPerformanceRoot(state: state))
        window.contentView = host
        window.orderFront(nil)
        _ = settle()
        guard let scrollView = findScroll(host), let document = scrollView.documentView else { fatalError("Missing scroll view") }
        scroll(scrollView, to: 0)
        _ = settle()
        let previousHeight = document.frame.height
        // Drive the same model loading transition as the history button, then deliver
        // a larger snapshot. This stays independent of system Accessibility permission.
        state.isLoadingHistory = true
        _ = settle()
        state.loadHistory()
        _ = settle()
        check(state.historyRequests == 1)
        let heightDelta = document.frame.height - previousHeight
        check(heightDelta > 0 && heightDelta < previousHeight * 1.2, "History request must reveal only one new batch: previous \(previousHeight), delta \(heightDelta)")
        check(abs(scrollView.contentView.bounds.minY - heightDelta) < 2, "Loaded history displaced the reader")
        window.orderOut(nil)
        window.contentView = nil
        _ = settle()
        print("PASS loaded history: model loading transition, one new batch visible, preserved reading anchor")
    }

    @MainActor static func scroll(_ view: NSScrollView, to y: CGFloat) {
        var bounds = view.contentView.bounds
        bounds.origin.y = y
        view.contentView.scroll(to: view.contentView.constrainBoundsRect(bounds).origin)
        view.reflectScrolledClipView(view.contentView)
    }

    @MainActor private static func verifyReading(
        state: PreviewPerformanceState,
        scrollView: NSScrollView,
        count: Int
    ) {
        guard let document = scrollView.documentView else { fatalError("Missing document") }
        // All fixtures have the same message mix. A 500-item conversation must initially
        // have the height of one 30-item batch, rather than a document taller than 70,000px.
        check(document.frame.height < 10_000, "Initial layout eagerly rendered the history")
        check(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2)
        scroll(scrollView, to: 300)
        _ = settle()
        let pausedY = scrollView.contentView.bounds.minY
        let pausedHeight = document.frame.height
        state.appendText()
        _ = settle()
        check(document.frame.height > pausedHeight, "Appended text did not reach the rendered card")
        check(abs(scrollView.contentView.bounds.minY - pausedY) < 2, "Tail text displaced the reader")

        let initialHeight = document.frame.height
        let expectedBatches = max(0, (count - 30 + 29) / 30)
        for _ in 0..<expectedBatches {
            let previousHeight = document.frame.height
            scroll(scrollView, to: 0)
            _ = settle()
            let heightDelta = document.frame.height - previousHeight
            check(heightDelta > 0, "Older local content was inaccessible")
            check(abs(scrollView.contentView.bounds.minY - heightDelta) < 2, "Prepending displaced the reader: expected offset \(heightDelta), actual \(scrollView.contentView.bounds.minY)")
        }
        let fullHeight = document.frame.height
        scroll(scrollView, to: 0)
        _ = settle()
        check(abs(document.frame.height - fullHeight) < 2, "The oldest content should end local pagination")
        check(abs(scrollView.contentView.bounds.minY) < 2)
        if count > 30 { check(fullHeight > initialHeight * 2, "History was silently truncated") }

        scroll(scrollView, to: document.frame.height)
        _ = settle()
        state.appendText()
        _ = settle()
        check(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2, "Following did not resume")
        print("PASS preview reading: items=\(count), revealed_batches=\(expectedBatches), append_anchor, oldest_reachable, resume_follow")
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for count in [30, 150, 500] {
            var openingTimes: [Double] = []
            var appendTimes: [Double] = []
            for sample in 0..<3 {
                let state = PreviewPerformanceState(count: count)
                let start = DispatchTime.now().uptimeNanoseconds
                let window = NSWindow(
                    contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 520),
                    styleMask: .borderless, backing: .buffered, defer: false
                )
                let host = NSHostingView(rootView: PreviewPerformanceRoot(state: state))
                window.contentView = host
                window.orderFront(nil)
                let setupMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                let longestTurn = settle()
                openingTimes.append(longestTurn)
                print(String(format: "preview_open items=%d sample=%d setup_ms=%.2f longest_main_turn_ms=%.2f", count, sample + 1, setupMS, longestTurn))
                guard let scrollView = findScroll(host) else { fatalError("Missing scroll view") }
                for _ in 0..<3 {
                    state.appendText()
                    appendTimes.append(settle())
                }
                if sample == 0 { verifyReading(state: state, scrollView: scrollView, count: count) }
                window.orderOut(nil)
                window.contentView = nil
                _ = settle()
            }
            print(String(format: "preview_summary items=%d open_samples=3 open_median_ms=%.2f append_samples=9 append_median_ms=%.2f", count, median(openingTimes), median(appendTimes)))
        }
        verifyLoadedHistory()
    }
}
