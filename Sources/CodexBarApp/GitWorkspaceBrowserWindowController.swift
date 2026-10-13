import AppKit
import SwiftUI

@MainActor
final class GitWorkspaceBrowserWindowController: NSWindowController {
    private let model: GitWorkspaceBrowserModel

    init(model: GitWorkspaceBrowserModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "CodexBar · 项目与 Worktree"
        window.minSize = NSSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GitWorkspaceBrowserView(model: model))
        window.setFrameAutosaveName("CodexBar.GitWorkspaceBrowser")
        super.init(window: window)
        if !window.setFrameUsingName("CodexBar.GitWorkspaceBrowser") { window.center() }
    }

    required init?(coder: NSCoder) { nil }

    func show(directory: String? = nil) {
        model.start()
        if let directory { model.followDirectory(directory) }
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
