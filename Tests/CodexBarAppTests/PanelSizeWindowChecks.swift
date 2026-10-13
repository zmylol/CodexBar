import AppKit
import CodexBarCore
import CodexBarWindowing
import SwiftUI

/// Exercises real windows without starting monitors or reading saved user data.
@main @MainActor enum PanelSizeWindowChecks {
    static func main() throws {
        UserDefaults.standard.setVolatileDomain(
            ["codexbar.panelDisplayMode": "scrolling"], forName: UserDefaults.argumentDomain
        )
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-size-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "codexbar-size-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated panel defaults")
        }
        let paths = CodexBarPaths(rootDirectory: root)
        try paths.prepareStorageDirectory()
        let store = TaskStore(persistenceURL: paths.taskStore)
        let activity = LiveTaskActivityStore()
        let model = CodexBarAppModel(
            store: store,
            activityStore: activity,
            processor: EventProcessor(
                source: CodexHookEventSource(paths: paths), store: store, activityStore: activity
            ),
            activator: AccessibilityWindowActivator(),
            inboxMonitor: CodexInboxMonitor(paths: paths),
            knowledgeLibrary: KnowledgeLibraryModel(
                defaultsSuiteName: suiteName, registryURL: root.appendingPathComponent("missing-registry.json")
            ),
            gitWorkspaceBrowser: GitWorkspaceBrowserModel(
                service: GitWorkspaceService(storageURL: root.appendingPathComponent("workspaces.json")),
                defaults: defaults
            )
        )
        let controller = FloatingPanelController(model: model, defaults: defaults)
        defer {
            model.stop()
            for window in application.windows { window.orderOut(nil) }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        controller.show()
        settle(0.2)
        guard let panel = application.windows.first(where: { $0.title == "CodexBar 任务" }),
              let host = panel.contentView as? NSHostingView<TaskListView> else {
            fatalError("The production task panel did not install TaskListView")
        }
        checkSize(panel, width: 126, height: CodexBarPanelLayout.minimumHeight,
                  message: "Fresh settings changed the compact panel")
        host.rootView.onSizeSettingsRequested()
        settle(0.2)
        guard let settings = application.windows.first(where: { $0.title == "CodexBar 界面大小" }),
              let settingsHost = settings.contentView as? NSHostingView<PanelSizeSettingsView> else {
            fatalError("The real size entry did not install PanelSizeSettingsView")
        }
        let preferences = settingsHost.rootView.preferences
        check(settings.isVisible, "The size entry did not display the settings window")
        check(settings.isKeyWindow, "Opening size settings did not make its controls available to the keyboard")
        host.rootView.onSizeSettingsRequested()
        settle(0.1)
        check(settings.isKeyWindow, "Repeating the size entry did not keep settings ready for keyboard input")
        preferences.setWidth(260)
        preferences.setHeight(360)
        checkSize(panel, width: 260, height: 360, message: "Size changes were not applied immediately")

        // Exercise the presentation update directly without scanning real VS Code windows.
        controller.updateHeight(taskCount: 8, noticeVisible: true, animated: true)
        settle(0.3)
        checkSize(panel, width: 260, height: 360, message: "Presentation update overwrote the custom dimensions")
        controller.updateHeight(taskCount: 0, noticeVisible: false, animated: false)
        checkSize(panel, width: 260, height: 360, message: "Clearing the presentation overwrote the custom dimensions")

        settingsHost.rootView.onClose()
        check(!settings.isVisible, "The Done action did not close size settings")
        host.rootView.onSizeSettingsRequested()
        settle(0.2)
        guard let reopenedHost = settings.contentView as? NSHostingView<PanelSizeSettingsView> else {
            fatalError("Reopening size settings lost its view")
        }
        check(settings.isVisible && reopenedHost.rootView.preferences === preferences,
              "Reopening did not reuse the settings window and preferences")
        check(settings.isKeyWindow, "Reopening size settings did not restore keyboard input")
        check(application.windows.filter { $0.title == "CodexBar 界面大小" }.count == 1,
              "Reopening created duplicate settings windows")
        check(preferences.width == 260 && preferences.height == 360,
              "Reopening discarded the selected dimensions")
        if !(reopenedHost.accessibilityChildren() ?? []).isEmpty {
            guard let widthSlider = slider("宽度", in: reopenedHost),
                  let heightSlider = slider("高度", in: reopenedHost) else {
                fatalError("Size sliders did not expose accessible labels")
            }
            check(String(describing: widthSlider.accessibilityValue?() ?? "").contains("260")
                  && String(describing: heightSlider.accessibilityValue?() ?? "").contains("360"),
                  "The accessible slider values did not follow the selected dimensions")
            print("PASS accessible size sliders: labels and values")
        } else {
            print("SKIP accessible size sliders: AppKit did not expose accessibility children")
        }

        if CommandLine.arguments.contains("--screenshots") {
            settle(0.3)
            try capture(reopenedHost.superview ?? reopenedHost, to: "/tmp/codexbar-size-settings.png")
            try capture(host, to: "/tmp/codexbar-size-panel.png")
        }

        guard let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            fatalError("The position restoration check requires an active screen")
        }
        panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - panel.frame.width / 2,
                                     y: visibleFrame.maxY - panel.frame.height - 36))
        settle(0.2)
        let savedOrigin = panel.frame.origin
        settings.close()
        panel.orderOut(nil)
        let restoredController = FloatingPanelController(model: model, defaults: defaults)
        restoredController.show()
        settle(0.2)
        guard let restoredPanel = application.windows.first(where: {
            $0.title == "CodexBar 任务" && $0 !== panel && $0.isVisible
        }), let restoredHost = restoredPanel.contentView as? NSHostingView<TaskListView> else {
            fatalError("The replacement controller did not display its own task panel")
        }
        checkSize(restoredPanel, width: 260, height: 360,
                  message: "A new controller did not restore the saved dimensions")
        check(abs(restoredPanel.frame.minX - savedOrigin.x) < 0.5
              && abs(restoredPanel.frame.minY - savedOrigin.y) < 0.5,
              "Restoring custom dimensions moved the panel: expected \(savedOrigin), got \(restoredPanel.frame.origin)")
        restoredHost.rootView.onSizeSettingsRequested()
        guard let restoredSettings = application.windows.first(where: {
            $0.title == "CodexBar 界面大小" && $0 !== settings && $0.isVisible
        }), let restoredSettingsHost = restoredSettings.contentView as? NSHostingView<PanelSizeSettingsView> else {
            fatalError("The replacement controller did not display size settings")
        }
        restoredSettingsHost.rootView.preferences.reset()
        let defaultHeight = CodexBarPanelLayout.height(rowHeights: model.visibleRowHeights, noticeVisible: false)
        checkSize(restoredPanel, width: 126, height: defaultHeight,
                  message: "Reset did not restore compact width and automatic task height")
        let resetPreferences = PanelSizePreferences(defaults: defaults)
        check(resetPreferences.width == 126 && resetPreferences.height == nil,
              "Reset did not persist the original size settings")
        check(model.knowledgeLibrary.review == nil, "The size check opened a knowledge vault")

        withExtendedLifetime((controller, restoredController)) {
            print("PASS panel size windows: real settings entry, keyboard focus, immediate dimensions, presentation updates, reopen, saved dimensions and position, and reset")
        }
    }

    private static func checkSize(_ window: NSWindow, width: CGFloat, height: CGFloat, message: String) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            fatalError("The native size check requires an active screen")
        }
        let expectedWidth = min(width, max(0, visibleFrame.width - 36))
        let expectedHeight = min(height, max(0, visibleFrame.height - 36))
        check(abs(window.frame.width - expectedWidth) < 0.5
              && abs(window.frame.height - expectedHeight) < 0.5,
              "\(message): expected \(expectedWidth) × \(expectedHeight), got \(window.frame.size)")
    }

    private static func capture(_ view: NSView, to path: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Could not prepare a bitmap for \(path)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode a screenshot for \(path)")
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("SCREENSHOT \(path)")
    }

    private static func slider(_ label: String, in parent: Any) -> AnyObject? {
        let accessible = parent as AnyObject
        if accessible.accessibilityRole?() == NSAccessibility.Role.slider,
           accessible.accessibilityLabel?() == label { return accessible }
        for child in accessible.accessibilityChildren?() ?? [] {
            if let found = slider(label, in: child) { return found }
        }
        return nil
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL panel size line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    private static func settle(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            while let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date(), inMode: .default, dequeue: true
            ) {
                NSApplication.shared.sendEvent(event)
            }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }
}
