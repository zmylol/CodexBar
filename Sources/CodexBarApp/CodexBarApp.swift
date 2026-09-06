import AppKit
import CodexBarCore
import CodexBarWindowing

@main
@MainActor
enum CodexBarApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = CodexBarAppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}

@MainActor
private final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    private var model: CodexBarAppModel?
    private var panelController: FloatingPanelController?
    private var startupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        startupTask = Task { [weak self] in
            await self?.finishLaunching()
        }
    }

    private func finishLaunching() async {
        let paths = CodexBarPaths()
        do {
            try await Task.detached(priority: .userInitiated) {
                try paths.prepareStorageDirectory()
            }.value
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "CodexBar 无法安全访问本地数据目录"
            alert.informativeText = "请确认 Application Support/CodexBar 是普通文件夹，而不是符号链接。"
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        guard !Task.isCancelled else {
            return
        }
        let store = TaskStore(persistenceURL: paths.taskStore)
        await store.load()
        guard !Task.isCancelled else {
            return
        }
        let source = CodexHookEventSource(paths: paths)
        let activityStore = LiveTaskActivityStore()
        let processor = EventProcessor(
            source: source,
            store: store,
            activityStore: activityStore
        )
        let model = CodexBarAppModel(
            store: store,
            activityStore: activityStore,
            processor: processor,
            activator: AccessibilityWindowActivator(),
            inboxMonitor: CodexInboxMonitor(paths: paths),
            threadSnapshotLoader: InstalledVSCodeCodexThreadSnapshotSource()
        )
        let panelController = FloatingPanelController(model: model)
        model.onPresentationChanged = { [weak panelController] taskCount, noticeVisible, animated in
            panelController?.updateHeight(
                taskCount: taskCount,
                noticeVisible: noticeVisible,
                animated: animated
            )
        }
        model.onPanelPlacementRequested = { [weak panelController] placement in
            panelController?.place(placement)
        }
        model.onAnnouncementRequested = { [weak panelController] message, highPriority in
            panelController?.announce(message, highPriority: highPriority)
        }

        self.model = model
        self.panelController = panelController
        panelController.show()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        model?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
