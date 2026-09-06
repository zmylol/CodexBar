import AppKit
import SwiftUI

@MainActor final class PreviewCheckState: ObservableObject {
    @Published var rows = (1...30).map { "row-\($0)" }
    @Published var follows = true
    @Published var expandedID: String?
}
struct PreviewCheckView: View {
    @ObservedObject var state: PreviewCheckState
    var body: some View {
        ConversationPreviewScrollView(itemIDs: state.rows, isFollowingLatest: $state.follows) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.rows, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(row): 原生会话正文，验证长内容、换行与阅读位置。\nSecond line of preview content.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if state.expandedID == row {
                            Text("Expanded tool output\nstdout\nstderr\nExit code: 0")
                                .frame(height: 120)
                        }
                    }
                    .conversationPreviewItemAnchor(row)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
@main struct PreviewScrollCheck {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    @MainActor static func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
        return nil
    }
    @MainActor static func scroll(_ view: NSScrollView, to y: CGFloat) {
        var bounds = view.contentView.bounds
        bounds.origin.y = y
        view.contentView.scroll(to: view.contentView.constrainBoundsRect(bounds).origin)
        view.reflectScrolledClipView(view.contentView)
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = PreviewCheckState()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 430), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PreviewCheckView(state: state))
        window.orderFront(nil)
        settle()
        guard let view = window.contentView, let scrollView = findScroll(in: view), let document = scrollView.documentView else { fatalError("Missing preview scroll view") }
        print("initial", document.frame, scrollView.contentView.bounds, state.follows)
        precondition(document.frame.height > 430, "Content did not measure to its full height")
        precondition(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2, "Did not start at bottom")
        scroll(scrollView, to: 200)
        settle()
        precondition(!state.follows, "Scrolling up did not pause following")
        let pausedY = scrollView.contentView.bounds.minY
        let heightBeforeAppend = document.frame.height
        state.rows.append("new-message")
        settle()
        let rowHeight = document.frame.height - heightBeforeAppend
        print("appended while paused", document.frame, scrollView.contentView.bounds, state.follows)
        precondition(abs(scrollView.contentView.bounds.minY - pausedY) < 2, "Appending displaced reading position")
        state.follows = true
        settle()
        precondition(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2, "Resume did not scroll to latest")
        scroll(scrollView, to: 300)
        settle()
        let beforeExpansionY = scrollView.contentView.bounds.minY
        let beforeExpansionHeight = document.frame.height
        state.expandedID = "row-8"
        settle()
        precondition(document.frame.height > beforeExpansionHeight, "Tool expansion did not grow content")
        precondition(abs(scrollView.contentView.bounds.minY - beforeExpansionY) < 2, "Tool expansion displaced reading position")
        state.expandedID = nil
        settle()
        precondition(abs(scrollView.contentView.bounds.minY - beforeExpansionY) < 2, "Tool collapse displaced reading position")
        let previousHeight = document.frame.height
        let previousY = scrollView.contentView.bounds.minY
        state.rows.insert(contentsOf: ["older-1", "older-2", "older-3"], at: 0)
        settle()
        print("prepended", document.frame, scrollView.contentView.bounds, state.follows)
        precondition(abs(scrollView.contentView.bounds.minY - previousY - document.frame.height + previousHeight) < 2, "Prepending displaced existing content")
        let simultaneousY = scrollView.contentView.bounds.minY
        state.rows.insert(contentsOf: ["earliest-1", "earliest-2"], at: 0)
        state.rows.append(contentsOf: ["tail-1", "tail-2", "tail-3"])
        settle()
        print("simultaneous prepend+append", document.frame, scrollView.contentView.bounds)
        precondition(abs(scrollView.contentView.bounds.minY - simultaneousY - 2 * rowHeight) < 2, "Tail growth incorrectly counted in prepend anchor")
        scroll(scrollView, to: document.frame.height)
        settle()
        precondition(state.follows, "Scrolling to bottom did not restore following")
        state.rows.append("latest-message")
        settle()
        precondition(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2, "New content did not follow latest")
        window.setContentSize(NSSize(width: 420, height: 230))
        settle()
        precondition(abs(document.frame.height - scrollView.contentView.bounds.maxY) < 2, "Viewport shrink lost latest position")
        print("PASS: initial bottom, user pause, stable append, resume, prepend anchor, simultaneous prepend+append, expansion/collapse, bottom restore, viewport resize")
        window.orderOut(nil)
    }
}
