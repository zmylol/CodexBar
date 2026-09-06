import AppKit
import CodexBarCore
import SwiftUI

private final class CodexBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CodexBarDetailPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onNavigate: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        if onNavigate?(event) != true {
            super.keyDown(with: event)
        }
    }
}

enum PanelPlacement {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private enum Metrics {
        static let margin: CGFloat = 18
        static let detailDismissDelayNanoseconds: UInt64 = 180_000_000
    }

    private enum DefaultsKey {
        static let originX = "CodexBar.panel.originX"
        static let originY = "CodexBar.panel.originY"
    }

    private let model: CodexBarAppModel
    private let panel: NSPanel
    private let detailPanel: NSPanel
    private let defaults: UserDefaults
    private var detailHideTask: Task<Void, Never>?
    private var panelFrameUpdateTask: Task<Void, Never>?
    private var detailSelection = CodexBarDetailSelection()
    private var displayedDetailTarget: CodexBarDetailTarget?
    private var detailTaskID: String?
    private var measuredDetailHeight: CGFloat?
    private var isDetailHovered = false
    private var isUpdatingPanelFrame = false
    private weak var taskListResponder: NSResponder?

    init(model: CodexBarAppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        let initialHeight = CodexBarPanelLayout.height(
            taskCount: model.visibleTasks.count,
            noticeVisible: false,
            displayMode: model.panelDisplayMode,
            maximumHeight: max(0, (NSScreen.main?.visibleFrame.height ?? 900) - 2 * Metrics.margin)
        )
        self.panel = CodexBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CodexBarPanelLayout.compactWidth,
                height: initialHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let initialDetailHeight = CodexBarPanelLayout.defaultDetailHeight
        self.detailPanel = CodexBarDetailPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CodexBarPanelLayout.detailWidth,
                height: initialDetailHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.title = "CodexBar 任务"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        let hostingView = NSHostingView(rootView: TaskListView(
            model: model,
            onTaskHoverChanged: { [weak self] task, rowMidY, hovering in
                self?.taskHoverChanged(task, rowMidY: rowMidY, hovering: hovering)
            },
            onTaskFocusChanged: { [weak self] task, rowMidY, focused in
                self?.taskFocusChanged(task, rowMidY: rowMidY, focused: focused)
            },
            onTaskDetailRequested: { [weak self] task, rowMidY in
                self?.focusTaskDetail(task, rowMidY: rowMidY)
            },
            onDismissTaskDetail: { [weak self] in
                self?.hideTaskDetail(clearTriggers: true)
            }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        detailPanel.delegate = self
        (detailPanel as? CodexBarDetailPanel)?.onDismiss = { [weak self] in
            self?.dismissTaskDetail()
        }
        (detailPanel as? CodexBarDetailPanel)?.onNavigate = { [weak self] event in
            self?.navigateTaskDetail(event) ?? false
        }
        detailPanel.level = .floating
        detailPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        detailPanel.hidesOnDeactivate = false
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = true
        detailPanel.becomesKeyOnlyIfNeeded = true
        detailPanel.animationBehavior = .none
        restorePosition()
        updateHeight(
            taskCount: model.visibleTasks.count,
            noticeVisible: model.notice != nil,
            animated: false
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func updateHeight(taskCount: Int, noticeVisible: Bool, animated: Bool) {
        let visibleFrame = ((panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame)
            .insetBy(dx: Metrics.margin, dy: Metrics.margin)
        let frame = CodexBarPanelLayout.panelFrame(
            currentFrame: panel.frame,
            taskCount: taskCount,
            noticeVisible: noticeVisible,
            displayMode: model.panelDisplayMode,
            visibleFrame: visibleFrame
        )
        guard frame != panel.frame else {
            if detailPanel.isVisible {
                refreshTaskDetail()
            }
            return
        }

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panelFrameUpdateTask?.cancel()
        isUpdatingPanelFrame = true
        let animationDuration = shouldAnimate ? panel.animationResizeTime(frame) : 0
        panel.setFrame(frame, display: true, animate: shouldAnimate)

        if shouldAnimate {
            let delay = UInt64(max(animationDuration + 0.05, 0.05) * 1_000_000_000)
            panelFrameUpdateTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                self?.finishPanelFrameUpdate()
            }
        } else {
            finishPanelFrameUpdate()
        }
    }

    func place(_ placement: PanelPlacement) {
        panelFrameUpdateTask?.cancel()
        panelFrameUpdateTask = nil
        isUpdatingPanelFrame = false
        hideTaskDetail(clearTriggers: true)
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x: CGFloat
        let y: CGFloat
        switch placement {
        case .topLeft:
            x = visibleFrame.minX + Metrics.margin
            y = visibleFrame.maxY - panel.frame.height - Metrics.margin
        case .topRight:
            x = visibleFrame.maxX - panel.frame.width - Metrics.margin
            y = visibleFrame.maxY - panel.frame.height - Metrics.margin
        case .bottomLeft:
            x = visibleFrame.minX + Metrics.margin
            y = visibleFrame.minY + Metrics.margin
        case .bottomRight:
            x = visibleFrame.maxX - panel.frame.width - Metrics.margin
            y = visibleFrame.minY + Metrics.margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func announce(_ message: String, highPriority: Bool) {
        guard let contentView = panel.contentView else {
            return
        }
        NSAccessibility.post(
            element: contentView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: highPriority
                    ? NSAccessibilityPriorityLevel.high.rawValue
                    : NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        if isUpdatingPanelFrame && NSEvent.pressedMouseButtons == 0 {
            return
        }
        panelFrameUpdateTask?.cancel()
        panelFrameUpdateTask = nil
        isUpdatingPanelFrame = false
        hideTaskDetail(clearTriggers: true)
        persistPanelOrigin()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !isUpdatingPanelFrame else { return }
        screenParametersDidChange(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === detailPanel, displayedDetailTarget != nil else { return }
        scheduleTaskDetailHide()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        updateHeight(
            taskCount: model.visibleTasks.count,
            noticeVisible: model.notice != nil,
            animated: false
        )
    }

    private func taskHoverChanged(
        _ task: CodexTask,
        rowMidY: CGFloat,
        hovering: Bool
    ) {
        detailSelection.updateHover(
            cwd: task.cwd,
            rowMidY: rowMidY,
            active: hovering
        )
        if hovering {
            refreshTaskDetail()
        } else {
            scheduleTaskDetailHide()
        }
    }

    private func taskFocusChanged(
        _ task: CodexTask,
        rowMidY: CGFloat,
        focused: Bool
    ) {
        detailSelection.updateFocus(
            cwd: task.cwd,
            rowMidY: rowMidY,
            active: focused
        )
        if focused {
            refreshTaskDetail()
        } else {
            scheduleTaskDetailHide()
        }
    }

    private func refreshTaskDetail() {
        let retainedTarget = isDetailHovered || detailPanel.isKeyWindow ? displayedDetailTarget : nil
        guard let target = detailSelection.selected ?? retainedTarget else {
            hideTaskDetail(clearTriggers: false)
            return
        }
        guard let task = model.visibleTasks.first(where: { $0.cwd == target.cwd }) else {
            detailSelection.clear()
            hideTaskDetail(clearTriggers: false)
            return
        }
        showTaskDetail(task, rowMidY: target.rowMidY)
    }

    private func focusTaskDetail(_ task: CodexTask, rowMidY: CGFloat) {
        guard let currentTask = model.visibleTasks.first(where: { $0.id == task.id }) else { return }
        if !detailPanel.isKeyWindow {
            taskListResponder = panel.firstResponder
        }
        showTaskDetail(currentTask, rowMidY: rowMidY)
        detailPanel.makeKeyAndOrderFront(nil)
        if let contentView = detailPanel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let responder = detailScrollView(in: contentView) ?? contentView
            if !detailPanel.makeFirstResponder(responder) {
                detailPanel.makeFirstResponder(detailPanel)
            }
        }
    }

    private func detailScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = detailScrollView(in: child) { return scrollView }
        }
        return nil
    }

    private func navigateTaskDetail(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
              let contentView = detailPanel.contentView,
              let scrollView = detailScrollView(in: contentView)
        else {
            return false
        }
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        let direction: CGFloat = clipView.isFlipped ? 1 : -1
        let line = scrollView.verticalLineScroll
        let page = max(bounds.height - scrollView.verticalPageScroll, line)
        switch Int(key) {
        case NSUpArrowFunctionKey:
            bounds.origin.y -= direction * line
        case NSDownArrowFunctionKey:
            bounds.origin.y += direction * line
        case NSPageUpFunctionKey:
            bounds.origin.y -= direction * page
        case NSPageDownFunctionKey:
            bounds.origin.y += direction * page
        case NSHomeFunctionKey:
            bounds.origin.y = clipView.isFlipped ? clipView.documentRect.minY : clipView.documentRect.maxY - bounds.height
        case NSEndFunctionKey:
            bounds.origin.y = clipView.isFlipped ? clipView.documentRect.maxY - bounds.height : clipView.documentRect.minY
        default:
            return false
        }
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func dismissTaskDetail() {
        let restoreFocus = detailPanel.isKeyWindow
        let responder = taskListResponder
        hideTaskDetail(clearTriggers: true)
        if restoreFocus {
            panel.makeKeyAndOrderFront(nil)
            if let responder { panel.makeFirstResponder(responder) }
        }
    }

    private func showTaskDetail(_ task: CodexTask, rowMidY: CGFloat) {
        detailHideTask?.cancel()
        detailHideTask = nil
        displayedDetailTarget = CodexBarDetailTarget(cwd: task.cwd, rowMidY: rowMidY)
        let preferredHeight = detailTaskID == task.id
            ? measuredDetailHeight ?? CodexBarPanelLayout.defaultDetailHeight
            : CodexBarPanelLayout.defaultDetailHeight

        if detailTaskID != task.id {
            measuredDetailHeight = nil
            detailTaskID = task.id
            let cwd = task.cwd
            let detailView = TaskHoverDetailView(
                store: model.store,
                activityStore: model.activityStore,
                cwd: cwd,
                onOpen: { [weak self] in
                    guard let self,
                          let currentTask = model.visibleTasks.first(where: { $0.cwd == cwd })
                    else {
                        return
                    }
                    hideTaskDetail(clearTriggers: true)
                    model.activate(currentTask)
                },
                onHoverChanged: { [weak self] hovering in
                    self?.detailHoverChanged(hovering)
                },
                onPreferredHeightChanged: { [weak self] preferredHeight in
                    self?.detailHeightChanged(preferredHeight, cwd: cwd, taskID: task.id)
                },
                onDismiss: { [weak self] in
                    self?.dismissTaskDetail()
                }
            )
            let hostingView = NSHostingView(rootView: detailView)
            hostingView.sizingOptions = []
            detailPanel.contentView = hostingView
        }

        updateDetailFrame(rowMidY: rowMidY, preferredHeight: measuredDetailHeight ?? preferredHeight)
        detailPanel.orderFrontRegardless()
    }

    private func detailHeightChanged(_ preferredHeight: CGFloat, cwd: String, taskID: String) {
        guard let target = displayedDetailTarget,
              target.cwd == cwd,
              let task = model.visibleTasks.first(where: { $0.cwd == cwd }),
              detailTaskID == taskID,
              task.id == taskID
        else {
            return
        }
        measuredDetailHeight = preferredHeight
        updateDetailFrame(rowMidY: target.rowMidY, preferredHeight: preferredHeight)
    }

    private func updateDetailFrame(rowMidY: CGFloat, preferredHeight: CGFloat) {
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let detailFrame = CodexBarPanelLayout.detailFrame(
            panelFrame: panel.frame,
            rowMidYFromTop: rowMidY,
            visibleFrame: visibleFrame,
            detailHeight: preferredHeight
        )
        guard detailFrame != detailPanel.frame else {
            return
        }
        detailPanel.setFrame(detailFrame, display: true)
    }

    private func detailHoverChanged(_ hovering: Bool) {
        isDetailHovered = hovering
        if hovering {
            detailHideTask?.cancel()
            detailHideTask = nil
        } else {
            scheduleTaskDetailHide()
        }
    }

    private func scheduleTaskDetailHide() {
        detailHideTask?.cancel()
        detailHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Metrics.detailDismissDelayNanoseconds)
            } catch {
                return
            }
            guard let self,
                  !isDetailHovered,
                  !detailPanel.isKeyWindow else {
                return
            }
            refreshTaskDetail()
        }
    }

    private func hideTaskDetail(clearTriggers: Bool) {
        detailHideTask?.cancel()
        detailHideTask = nil
        displayedDetailTarget = nil
        taskListResponder = nil
        detailPanel.orderOut(nil)
        detailPanel.contentView = nil
        detailTaskID = nil
        measuredDetailHeight = nil
        isDetailHovered = false
        if clearTriggers {
            detailSelection.clear()
        }
    }

    private func finishPanelFrameUpdate() {
        panelFrameUpdateTask = nil
        isUpdatingPanelFrame = false
        persistPanelOrigin()
        if detailPanel.isVisible {
            refreshTaskDetail()
        }
    }

    private func persistPanelOrigin() {
        defaults.set(panel.frame.origin.x, forKey: DefaultsKey.originX)
        defaults.set(panel.frame.origin.y, forKey: DefaultsKey.originY)
    }

    private func restorePosition() {
        if defaults.object(forKey: DefaultsKey.originX) != nil,
           defaults.object(forKey: DefaultsKey.originY) != nil {
            panel.setFrameOrigin(NSPoint(
                x: defaults.double(forKey: DefaultsKey.originX),
                y: defaults.double(forKey: DefaultsKey.originY)
            ))
            if panel.screen == nil {
                placeAtDefaultPosition()
            }
        } else {
            placeAtDefaultPosition()
        }
    }

    private func placeAtDefaultPosition() {
        place(.topRight)
    }
}
