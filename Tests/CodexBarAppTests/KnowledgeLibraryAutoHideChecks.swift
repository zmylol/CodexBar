import AppKit
import CodexBarCore
import CodexBarWindowing
import SwiftUI

/// Exercises the production controller and its real view callbacks using only
/// temporary task storage. The model is not started, so no saved vault is opened.
@main @MainActor enum KnowledgeLibraryAutoHideChecks {
    private static let offscreenOrigin = NSPoint(x: -20_000, y: -20_000)

    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-autohide-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "codexbar-autohide-\(UUID().uuidString)"
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
            knowledgeLibrary: KnowledgeLibraryModel(defaultsSuiteName: suiteName,
                                                    registryURL: root.appendingPathComponent("missing-registry.json"))
        )
        let controller = FloatingPanelController(model: model, defaults: defaults)
        model.onPresentationChanged = { [weak controller] taskCount, noticeVisible, animated in
            controller?.updateHeight(taskCount: taskCount, noticeVisible: noticeVisible, animated: animated)
        }
        defer {
            model.stop()
            for window in application.windows { window.orderOut(nil) }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        controller.show()
        settle(0.1)
        guard let bar = application.windows.first(where: { $0.title == "CodexBar 任务" }),
              let barHost = bar.contentView as? NSHostingView<TaskListView> else {
            fatalError("The production task bar did not install its hosting view")
        }
        let openLibrary = barHost.rootView.onKnowledgeRequested
        openLibrary()
        guard let library = application.windows.first(where: { $0.title == "CodexBar 知识库" }),
              let libraryHost = library.contentView as? NSHostingView<KnowledgeLibraryView> else {
            fatalError("The real knowledge entry did not install KnowledgeLibraryView")
        }
        let view = libraryHost.rootView
        library.setFrameOrigin(offscreenOrigin)
        settle(0.6)
        check(library.isVisible && library.alphaValue > 0.98,
              "Opening the book outside the pointer must keep the library available before hover enters")
        view.onHoverChanged(true)
        settle(0.1)
        check(model.visibleTasks.isEmpty && model.knowledgeLibrary.review == nil,
              "The native entry must work without tasks or a selected vault")

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            view.onHoverChanged(false)
            check(waitUntil(timeout: 0.3) { !library.isVisible },
                  "Reduced motion must dismiss the library without a delay")
            openLibrary()
            view.onHoverChanged(true)
            library.setFrameOrigin(offscreenOrigin)
        } else {
            view.onHoverChanged(false)
            settle(0.22)
            let midwayAlpha = library.alphaValue
            print("OBSERVE knowledge fade at approximately 0.22 s: alpha=\(midwayAlpha)")
            check(library.isVisible && midwayAlpha > 0.02 && midwayAlpha < 0.98,
                  "Leaving the library must immediately begin a half-second fade")
            view.onHoverChanged(true)
        }
        settle(0.65)
        check(library.isVisible && library.alphaValue > 0.98,
              "Returning to the library failed to cancel the fade or its old completion")

        let hideStarted = Date()
        view.onHoverChanged(false)
        check(waitUntil(timeout: 0.8) { !library.isVisible },
              "The library remained visible beyond its immediate half-second fade")
        let hideElapsed = Date().timeIntervalSince(hideStarted)
        check(reduceMotion || hideElapsed >= 0.4, "The library skipped its configured fade")
        print("OBSERVE knowledge hidden after \(hideElapsed) s; reduce motion=\(reduceMotion)")

        openLibrary()
        view.onHoverChanged(true)
        library.setFrameOrigin(offscreenOrigin)
        settle(0.1)
        check(library.isVisible && library.alphaValue > 0.98,
              "Reopening retained the previous fade's transparency")

        guard let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: library.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else {
            fatalError("Could not create an in-process keyboard navigation event")
        }
        view.onClose()
        openLibrary()
        library.setFrameOrigin(offscreenOrigin)
        library.sendEvent(keyEvent)
        settle(0.8)
        check(library.isVisible && library.alphaValue > 0.98,
              "Keyboard navigation outside the pointer was interrupted by automatic hiding")
        view.onHoverChanged(true)
        view.onHoverChanged(false)
        check(waitUntil(timeout: 0.8) { !library.isVisible },
              "Returning to mouse interaction did not restore automatic hiding")
        openLibrary()
        library.setFrameOrigin(offscreenOrigin)
        view.onHoverChanged(true)

        view.onChooseVault()
        check(waitUntil(timeout: 2) { library.attachedSheet is NSOpenPanel },
              "The real chooser action did not attach its folder sheet")
        guard let picker = library.attachedSheet as? NSOpenPanel else {
            fatalError("The attached chooser is not an NSOpenPanel")
        }
        library.setFrameOrigin(offscreenOrigin)
        view.onHoverChanged(false)
        settle(1.7)
        check(library.isVisible && library.alphaValue > 0.98 && library.attachedSheet === picker,
              "Leaving the library hid it while its folder chooser was active")

        check(!library.frame.contains(NSEvent.mouseLocation),
              "The test window must stay outside the real pointer before sheet cancellation")
        picker.cancel(nil)
        check(waitUntil(timeout: 2) { library.attachedSheet == nil },
              "Cancelling the folder chooser did not detach its sheet")
        // Do not synthesize a hover or sheet notification here: production must
        // resume the fade from AppKit's actual windowDidEndSheet callback.
        if !reduceMotion {
            settle(0.22)
            check(library.isVisible && library.alphaValue > 0.02 && library.alphaValue < 0.98,
                  "Dismissing the chooser must immediately begin fading outside the pointer")
        }
        check(waitUntil(timeout: reduceMotion ? 0.3 : 0.58) { !library.isVisible },
              "Dismissing the chooser failed to resume automatic hiding")
        check(model.knowledgeLibrary.review == nil, "Cancelling the chooser selected a real vault")

        openLibrary()
        view.onHoverChanged(true)
        library.setFrameOrigin(offscreenOrigin)
        settle(0.1)
        view.onHoverChanged(false)
        if !reduceMotion { settle(0.22) }
        view.onClose()
        openLibrary()
        view.onHoverChanged(true)
        library.setFrameOrigin(offscreenOrigin)
        settle(0.8)
        check(library.isVisible && library.alphaValue > 0.98,
              "A callback from a manually closed presentation hid its replacement")
        view.onClose()
        check(!library.isVisible, "The explicit close action did not dismiss the panel")

        try checkIndependentLibrary(model: model, controller: controller, bar: bar,
                                    barHost: barHost, library: library, root: root)
        checkLibraryPreventsTaskPreviews(model: model, bar: bar, barHost: barHost,
                                        library: library, root: root)

        withExtendedLifetime(controller) {
            print("PASS knowledge library auto-hide: real entry, immediate half-second fade, re-entry cancellation, timed hide, keyboard hold, reopen, attached chooser pause/resume and stale-callback cleanup")
        }
    }

    private static func checkLibraryPreventsTaskPreviews(
        model: CodexBarAppModel,
        bar: NSWindow,
        barHost: NSHostingView<TaskListView>,
        library: NSWindow,
        root: URL
    ) {
        var inserted = false
        Task { @MainActor in
            do {
                try await model.store.apply(CodexHookEvent(
                    id: "knowledge-hover-fixture", sessionID: "knowledge-hover-session", turnID: "turn",
                    cwd: root.appendingPathComponent("Task Fixture").path, name: .userPromptSubmit,
                    promptSummary: "Fixture", toolName: nil, timestamp: Date(),
                    lastAssistantMessagePresent: false, source: .visualStudioCode
                ))
                inserted = true
            } catch { fatalError("Could not insert temporary task: \(error)") }
        }
        check(waitUntil(timeout: 5) { inserted }, "The temporary task did not finish loading")
        guard let task = model.visibleTasks.first,
              let detail = NSApplication.shared.windows.first(where: { $0.title == "CodexBar 任务详情" }),
              let libraryHost = library.contentView as? NSHostingView<KnowledgeLibraryView> else {
            fatalError("The task preview isolation fixture is incomplete")
        }
        let callbacks = barHost.rootView
        let view = libraryHost.rootView
        let rowMidY = CodexBarPanelLayout.headerHeight + CodexBarPanelLayout.rowHeight / 2
        bar.setFrameOrigin(offscreenOrigin)
        callbacks.onTaskHoverChanged(task, rowMidY, true)
        check(detail.isVisible, "The fixture must be able to open a task preview before testing isolation")
        callbacks.onTaskHoverChanged(task, rowMidY, false)
        callbacks.onKnowledgeRequested()
        library.setFrameOrigin(offscreenOrigin)
        view.onHoverChanged(true)
        check(library.isVisible && !detail.isVisible, "Opening the book must replace an existing task preview")

        callbacks.onTaskHoverChanged(task, rowMidY, true)
        check(library.isVisible && !detail.isVisible, "An accidental task hover stole the open knowledge panel")
        callbacks.onTaskFocusChanged(task, rowMidY, true)
        callbacks.onTaskDetailRequested(task, rowMidY)
        callbacks.onTaskHoverChanged(task, rowMidY, false)
        callbacks.onTaskFocusChanged(task, rowMidY, false)
        settle(0.3)
        check(library.isVisible && !detail.isVisible, "Task focus or a delayed preview callback preempted the library")
        view.onClose()
        settle(0.3)
        check(!library.isVisible && !detail.isVisible, "Ignored task triggers resurfaced after closing the library")
        callbacks.onTaskHoverChanged(task, rowMidY, true)
        check(detail.isVisible, "Closing the library did not restore new task hover previews")

        callbacks.onKnowledgeRequested()
        library.setFrameOrigin(offscreenOrigin)
        view.onHoverChanged(true)
        view.onHoverChanged(false)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settle(0.22)
            check(library.isVisible && library.alphaValue > 0.02 && library.alphaValue < 0.98,
                  "The preview isolation fixture must be midway through its immediate fade")
            callbacks.onTaskHoverChanged(task, rowMidY, true)
            callbacks.onTaskFocusChanged(task, rowMidY, true)
            check(library.isVisible && !detail.isVisible, "Task previews interrupted a fading knowledge panel")
        }
        check(waitUntil(timeout: 0.58) { !library.isVisible }, "Ignored task hover prevented normal automatic hiding")
        settle(0.3)
        check(!detail.isVisible, "A task preview appeared from a trigger ignored during automatic hiding")
        callbacks.onTaskHoverChanged(task, rowMidY, false)
        callbacks.onTaskHoverChanged(task, rowMidY, true)
        check(detail.isVisible, "New task hover did not recover after automatic hiding")
        callbacks.onTaskDetailRequested(task, rowMidY)
        check(detail.isVisible && detail.isKeyWindow, "Explicit task preview navigation did not recover after hiding")
        callbacks.onKnowledgeRequested()
        view.onClose()
        print("PASS knowledge preview isolation: task hover/focus/navigation suppressed while open, immediate fade protected, stale triggers discarded, previews restored after close and automatic hiding")
    }

    private static func checkIndependentLibrary(
        model: CodexBarAppModel,
        controller: FloatingPanelController,
        bar: NSWindow,
        barHost: NSHostingView<TaskListView>,
        library: NSWindow,
        root: URL
    ) throws {
        let barHeight = bar.frame.height
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        let categories = ["A", "B"] + (1...34).map { "Library \($0)" }
        for directory in [".obsidian"] + categories {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let firstNoteURL = vault.appendingPathComponent("A/One.md")
        try Data("first baseline\n".utf8).write(to: firstNoteURL)
        try Data("second baseline\n".utf8).write(to: vault.appendingPathComponent("B/Two.md"))
        var selected = false
        Task { @MainActor in
            await model.knowledgeLibrary.selectVault(vault)
            selected = true
        }
        check(waitUntil(timeout: 5) { selected }, "The temporary total vault did not finish selecting")
        settle(0.4)
        check(model.visibleTasks.isEmpty && model.knowledgeLibrary.sections.count == 36,
              "The test libraries did not become available without VS Code tasks")
        controller.updateHeight(taskCount: 0, noticeVisible: false, animated: false)
        check(abs(bar.frame.height - barHeight) < 0.5,
              "Adding 36 libraries must not increase the task bar height")
        check(model.knowledgeLibrary.review?.notes.isEmpty == true && model.knowledgeLibrary.noteCount == 2,
              "Selecting classifications must establish a baseline without marking existing notes as changed")
        check(model.knowledgeLibrary.unseenChangeCount == 0,
              "An initial vault baseline must not show an update badge")
        if !(barHost.accessibilityChildren() ?? []).isEmpty {
            check(element("knowledge-library-row-A", in: barHost) == nil
                  && element("knowledge-library-row-B", in: barHost) == nil
                  && element("knowledge-library-empty-open", in: barHost) != nil,
                  "Library rows must stay inside their independent panel")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let articleHeader = "---\ntype: article\ncollected: '\(formatter.string(from: Date()))'\n---\n"
        try Data((articleHeader + "first revised\n").utf8).write(to: firstNoteURL)
        var refreshed = false
        Task { @MainActor in
            await model.knowledgeLibrary.refreshNow()
            refreshed = true
        }
        check(waitUntil(timeout: 5) { refreshed }, "The fixture note change did not finish refreshing")
        var retainedNotes = model.knowledgeLibrary.review?.notes
        check(retainedNotes?.count == 1 && retainedNotes?.first?.path == "A/One.md",
              "The real library did not retain the fixture edit before hover interaction")
        check(model.knowledgeLibrary.unseenChangeCount == 1,
              "A newly collected article must appear on the book's notification indicator")
        bar.setFrameOrigin(offscreenOrigin)
        bar.makeFirstResponder(nil)
        settle(0.2)

        let openLibrary = barHost.rootView.onKnowledgeRequested
        openLibrary()
        check(library.isVisible && model.knowledgeLibrary.unseenChangeCount == 1,
              "Opening the real knowledge panel must preserve category notifications until selection")
        model.knowledgeLibrary.markUpdatesSeen(in: "A")
        check(model.knowledgeLibrary.unseenChangeCount == 0,
              "Selecting A must acknowledge its current articles")
        check(model.knowledgeLibrary.review?.pendingCount == 1,
              "Acknowledging an update badge must leave the note pending for review")
        let screenWidth = (bar.screen ?? NSScreen.main)?.visibleFrame.width ?? 600
        check(abs(library.frame.width - min(600, screenWidth)) < 0.5,
              "The independent library must use the compact two-column width")
        library.setFrameOrigin(offscreenOrigin)
        settle(0.1)
        guard let firstHost = library.contentView as? NSHostingView<KnowledgeLibraryView> else {
            fatalError("The book button did not present the independent library view")
        }
        let firstView = firstHost.rootView
        firstView.onHoverChanged(true)
        settle(1.7)
        check(library.isVisible && library.alphaValue > 0.98,
              "The independent library hid while its contents remained hovered")
        check(model.knowledgeLibrary.review?.notes == retainedNotes,
              "Opening the library cleared or rebuilt the retained note baseline")

        firstView.onClose()
        openLibrary()
        library.setFrameOrigin(offscreenOrigin)
        guard let secondHost = library.contentView as? NSHostingView<KnowledgeLibraryView> else {
            fatalError("Reopening the library lost its hosting view")
        }
        let secondView = secondHost.rootView
        check(secondHost === firstHost,
              "Reopening must preserve the selected library by reusing the same view")
        secondView.onHoverChanged(true)
        settle(1.7)
        check(library.isVisible && library.alphaValue > 0.98,
              "Returning to the independent panel did not keep it visible")
        check(model.knowledgeLibrary.review?.notes == retainedNotes,
              "Reopening the independent panel discarded the shared review state")

        secondView.onChooseVault()
        check(waitUntil(timeout: 2) { library.attachedSheet is NSOpenPanel },
              "The classified view did not attach the real total-vault chooser")
        guard let picker = library.attachedSheet as? NSOpenPanel else { fatalError("Missing classified folder chooser") }
        try Data((articleHeader + "second revised\n").utf8).write(to: vault.appendingPathComponent("B/Two.md"))
        refreshed = false
        Task { @MainActor in
            await model.knowledgeLibrary.refreshNow()
            refreshed = true
        }
        check(waitUntil(timeout: 5) { refreshed }, "A note edit behind the chooser did not finish refreshing")
        retainedNotes = model.knowledgeLibrary.review?.notes
        check(model.knowledgeLibrary.unseenChangeCount == 1,
              "A newly collected article must show its notification even while the panel is open")
        openLibrary()
        check(model.knowledgeLibrary.unseenChangeCount == 1 && library.attachedSheet === picker,
              "An opening blocked by the attached chooser must not acknowledge updates")
        library.setFrameOrigin(offscreenOrigin)
        secondView.onHoverChanged(false)
        settle(1.7)
        check(library.contentView === firstHost && library.attachedSheet === picker
              && library.isVisible && library.alphaValue > 0.98,
              "The independent panel hid or replaced its view behind the active chooser")
        check(!library.frame.contains(NSEvent.mouseLocation), "The classified preview must be outside the pointer before dismissal")
        picker.cancel(nil)
        check(waitUntil(timeout: 2) { library.attachedSheet == nil }, "The classified chooser failed to detach")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settle(0.22)
            check(library.isVisible && library.alphaValue > 0.02 && library.alphaValue < 0.98,
                  "Closing the classified chooser must immediately begin fading outside the pointer")
        }
        check(waitUntil(timeout: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.3 : 0.58) { !library.isVisible },
              "Closing the classified chooser did not resume immediate automatic dismissal")
        check(model.knowledgeLibrary.review?.notes == retainedNotes,
              "Classification hover, chooser dismissal or hiding cleared retained note changes")

        try Data((articleHeader + "first revised again\n").utf8).write(to: firstNoteURL)
        refreshed = false
        Task { @MainActor in
            await model.knowledgeLibrary.refreshNow()
            refreshed = true
        }
        check(waitUntil(timeout: 5) { refreshed }, "Post-hover note edit did not finish refreshing")
        check(model.knowledgeLibrary.review?.notes.first?.diff?.contains("-first revised\n") == true,
              "Classification hover reset the content baseline used by the next edit")
        check(model.knowledgeLibrary.unseenChangeCount == 1,
              "Editing an already seen article must not create another new-article notification")
        let latestNotes = model.knowledgeLibrary.review?.notes
        openLibrary()
        check(library.isVisible && library.contentView === firstHost
              && model.knowledgeLibrary.unseenChangeCount == 1,
              "Reopening the retained panel must preserve subsequent category notifications")
        model.knowledgeLibrary.markUpdatesSeen(in: "B")
        check(model.knowledgeLibrary.unseenChangeCount == 0,
              "Selecting B must acknowledge only B's pending articles")
        check(model.knowledgeLibrary.review?.notes == latestNotes && model.knowledgeLibrary.review?.pendingCount == 2,
              "Reopening must preserve pending notes and their diffs after clearing the badge")
        firstHost.rootView.onClose()
        print("PASS independent library: 36 categories do not grow the task bar, compact panel, retained view, hover, chooser pause/resume, shared baseline and per-library acknowledgement")
    }

    private static func element(_ identifier: String, in parent: Any) -> AnyObject? {
        let accessible = parent as AnyObject
        if accessible.accessibilityIdentifier?() == identifier { return accessible }
        for child in accessible.accessibilityChildren?() ?? [] {
            if let found = element(identifier, in: child) { return found }
        }
        return nil
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL knowledge auto-hide line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    private static func settle(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { settle(0.02) }
        return condition()
    }
}
