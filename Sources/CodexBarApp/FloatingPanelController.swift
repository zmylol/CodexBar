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
    var onKeyboardInteraction: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { onKeyboardInteraction?() }
        super.sendEvent(event)
    }

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
        static let knowledgeFadeDuration: TimeInterval = 0.5
        static let knowledgeWidth: CGFloat = 600
    }

    private enum DefaultsKey {
        static let originX = "CodexBar.panel.originX"
        static let originY = "CodexBar.panel.originY"
    }

    private let model: CodexBarAppModel
    private let panel: NSPanel
    private let detailPanel: NSPanel
    private let knowledgePanel: NSPanel
    private let defaults: UserDefaults
    private var detailHideTask: Task<Void, Never>?
    private var knowledgeHideGeneration = UUID()
    private var isKnowledgeHovered = false
    private var isKnowledgeKeyboardActive = false
    private var panelFrameUpdateTask: Task<Void, Never>?
    private var detailSelection = CodexBarDetailSelection()
    private var displayedDetailTarget: CodexBarDetailTarget?
    private var detailSessionID: String?
    private var measuredDetailHeight: CGFloat?
    private var isDetailHovered = false
    private var isUpdatingPanelFrame = false
    private weak var taskListResponder: NSResponder?

    init(model: CodexBarAppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        let initialHeight = CodexBarPanelLayout.height(
            rowHeights: model.visibleRowHeights,
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
        self.knowledgePanel = CodexBarDetailPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metrics.knowledgeWidth,
                height: CodexBarPanelLayout.defaultDetailHeight
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
            onTaskHoverChanged: { [weak self] row, rowMidY, hovering in
                self?.taskHoverChanged(row, rowMidY: rowMidY, hovering: hovering)
            },
            onTaskFocusChanged: { [weak self] row, rowMidY, focused in
                self?.taskFocusChanged(row, rowMidY: rowMidY, focused: focused)
            },
            onTaskDetailRequested: { [weak self] row, rowMidY in
                self?.focusTaskDetail(row, rowMidY: rowMidY)
            },
            onTaskPositionChanged: { [weak self] row, rowMidY in
                self?.taskPositionChanged(row, rowMidY: rowMidY)
            },
            onDismissTaskDetail: { [weak self] in
                self?.hideTaskDetail(clearTriggers: true)
            },
            onKnowledgeRequested: { [weak self] in
                self?.showKnowledgeLibrary()
            }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        detailPanel.delegate = self
        detailPanel.title = "CodexBar 任务详情"
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

        knowledgePanel.delegate = self
        knowledgePanel.title = "CodexBar 知识库"
        // NSPanel starts with an empty NSView; clear it so the first open installs the library.
        knowledgePanel.contentView = nil
        knowledgePanel.level = .floating
        knowledgePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        knowledgePanel.hidesOnDeactivate = false
        knowledgePanel.isOpaque = false
        knowledgePanel.backgroundColor = .clear
        knowledgePanel.hasShadow = true
        knowledgePanel.becomesKeyOnlyIfNeeded = false
        knowledgePanel.animationBehavior = .none
        (knowledgePanel as? CodexBarDetailPanel)?.onDismiss = { [weak self] in
            self?.hideKnowledgeLibrary()
        }
        (knowledgePanel as? CodexBarDetailPanel)?.onKeyboardInteraction = { [weak self] in
            self?.isKnowledgeKeyboardActive = true
            self?.cancelKnowledgeHide()
        }
        restorePosition()
        updateHeight(
            taskCount: model.visibleRows.count,
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

    private func showKnowledgeLibrary() {
        guard knowledgePanel.attachedSheet == nil else { return }
        hideTaskDetail(clearTriggers: true)
        cancelKnowledgeHide()
        isKnowledgeKeyboardActive = NSApplication.shared.currentEvent?.type == .keyDown
        if knowledgePanel.contentView == nil {
            let hostingView = NSHostingView(rootView: KnowledgeLibraryView(
                model: model.knowledgeLibrary,
                onChooseVault: { [weak self] in
                    guard let self else { return }
                    cancelKnowledgeHide()
                    model.knowledgeLibrary.chooseVault(in: knowledgePanel)
                },
                onHoverChanged: { [weak self] hovering in
                    self?.knowledgeHoverChanged(hovering)
                },
                onClose: { [weak self] in self?.hideKnowledgeLibrary() }
            ))
            hostingView.sizingOptions = []
            knowledgePanel.contentView = hostingView
        }
        updateKnowledgeFrame()
        knowledgePanel.makeKeyAndOrderFront(nil)
        if knowledgePanel.isVisible {
            model.knowledgeLibrary.refreshToday()
        }
        if let contentView = knowledgePanel.contentView {
            knowledgePanel.makeFirstResponder(contentView)
            knowledgePanel.selectNextKeyView(nil)
        }
        isKnowledgeHovered = knowledgePanel.frame.contains(NSEvent.mouseLocation)
    }

    private func hideKnowledgeLibrary(restoreFocus: Bool = true) {
        let shouldRestoreFocus = restoreFocus && knowledgePanel.isKeyWindow
        knowledgePanel.orderOut(nil)
        cancelKnowledgeHide()
        isKnowledgeHovered = false
        isKnowledgeKeyboardActive = false
        if shouldRestoreFocus { panel.makeKeyAndOrderFront(nil) }
    }

    private func knowledgeHoverChanged(_ hovering: Bool) {
        isKnowledgeKeyboardActive = false
        isKnowledgeHovered = hovering
        if hovering { cancelKnowledgeHide() }
        else { scheduleKnowledgeHide() }
    }

    private func refreshKnowledgeHover() {
        knowledgeHoverChanged(knowledgePanel.frame.contains(NSEvent.mouseLocation))
    }

    private var isKnowledgeActive: Bool { isKnowledgeHovered || isKnowledgeKeyboardActive }

    private func cancelKnowledgeHide() {
        knowledgeHideGeneration = UUID()
        // Replace any in-flight fade so re-entry immediately restores the panel.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            knowledgePanel.animator().alphaValue = 1
        }
    }

    private func scheduleKnowledgeHide() {
        cancelKnowledgeHide()
        guard knowledgePanel.isVisible, !isKnowledgeActive, knowledgePanel.attachedSheet == nil else { return }
        let generation = knowledgeHideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Metrics.knowledgeFadeDuration
            knowledgePanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.knowledgeHideGeneration == generation,
                      !self.isKnowledgeActive, self.knowledgePanel.attachedSheet == nil else { return }
                self.hideKnowledgeLibrary(restoreFocus: false)
            }
        }
    }

    func windowWillBeginSheet(_ notification: Notification) {
        guard (notification.object as? NSWindow) === knowledgePanel else { return }
        cancelKnowledgeHide()
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard (notification.object as? NSWindow) === knowledgePanel, knowledgePanel.isVisible else { return }
        refreshKnowledgeHover()
    }

    private func updateKnowledgeFrame() {
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let frame = CodexBarPanelLayout.detailFrame(
            panelFrame: panel.frame,
            rowMidYFromTop: panel.frame.height / 2,
            visibleFrame: visibleFrame,
            detailHeight: CodexBarPanelLayout.defaultDetailHeight,
            detailWidth: Metrics.knowledgeWidth
        )
        if frame != knowledgePanel.frame {
            knowledgePanel.setFrame(frame, display: true)
        }
    }

    func updateHeight(taskCount: Int, noticeVisible: Bool, animated: Bool) {
        let visibleFrame = ((panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame)
            .insetBy(dx: Metrics.margin, dy: Metrics.margin)
        let frame = CodexBarPanelLayout.panelFrame(
            currentFrame: panel.frame,
            rowHeights: model.visibleRowHeights,
            noticeVisible: noticeVisible,
            displayMode: model.panelDisplayMode,
            visibleFrame: visibleFrame
        )
        guard frame != panel.frame else {
            if knowledgePanel.isVisible { updateKnowledgeFrame() }
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
        if knowledgePanel.isVisible { updateKnowledgeFrame() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !isUpdatingPanelFrame else { return }
        screenParametersDidChange(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === knowledgePanel {
            isKnowledgeKeyboardActive = false
            scheduleKnowledgeHide()
            return
        }
        guard (notification.object as? NSWindow) === detailPanel, displayedDetailTarget != nil else { return }
        scheduleTaskDetailHide()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        updateHeight(
            taskCount: model.visibleRows.count,
            noticeVisible: model.notice != nil,
            animated: false
        )
    }

    private func taskHoverChanged(
        _ row: VSCodeTaskRow,
        rowMidY: CGFloat,
        hovering: Bool
    ) {
        guard !knowledgePanel.isVisible, knowledgePanel.attachedSheet == nil else { return }
        guard row.task != nil else {
            if hovering { hideTaskDetail(clearTriggers: true) }
            return
        }
        detailSelection.updateHover(
            rowID: row.id,
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
        _ row: VSCodeTaskRow,
        rowMidY: CGFloat,
        focused: Bool
    ) {
        guard !knowledgePanel.isVisible, knowledgePanel.attachedSheet == nil else { return }
        detailSelection.updateFocus(
            rowID: row.id,
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
        guard !knowledgePanel.isVisible else { return }
        let retainedTarget = isDetailHovered || detailPanel.isKeyWindow ? displayedDetailTarget : nil
        let target = detailPanel.isKeyWindow ? retainedTarget : detailSelection.selected ?? retainedTarget
        guard let target else {
            hideTaskDetail(clearTriggers: false)
            return
        }
        guard let row = model.visibleRows.first(where: { $0.id == target.rowID }), row.task != nil else {
            detailSelection.clear()
            hideTaskDetail(clearTriggers: false)
            return
        }
        showTaskDetail(row, rowMidY: target.rowMidY)
    }

    private func taskPositionChanged(_ row: VSCodeTaskRow, rowMidY: CGFloat) {
        detailSelection.updatePosition(rowID: row.id, rowMidY: rowMidY)
        guard displayedDetailTarget?.rowID == row.id else { return }
        displayedDetailTarget = CodexBarDetailTarget(rowID: row.id, rowMidY: rowMidY)
        if detailPanel.isVisible, !isUpdatingPanelFrame {
            updateDetailFrame(rowMidY: rowMidY, preferredHeight: measuredDetailHeight ?? CodexBarPanelLayout.defaultDetailHeight)
        }
    }

    private func focusTaskDetail(_ row: VSCodeTaskRow, rowMidY: CGFloat) {
        guard !knowledgePanel.isVisible, knowledgePanel.attachedSheet == nil else { return }
        guard let currentRow = model.visibleRows.first(where: { $0.id == row.id }), currentRow.task != nil else { return }
        if !detailPanel.isKeyWindow {
            taskListResponder = panel.firstResponder
        }
        showTaskDetail(currentRow, rowMidY: rowMidY)
        detailPanel.makeKeyAndOrderFront(nil)
        if let contentView = detailPanel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let responder = singleDetailScrollView(in: contentView) ?? contentView
            if !detailPanel.makeFirstResponder(responder) {
                detailPanel.makeFirstResponder(detailPanel)
            }
            if responder === contentView { detailPanel.selectNextKeyView(nil) }
        }
    }

    private func singleDetailScrollView(in view: NSView) -> NSScrollView? {
        let scrollViews = detailScrollViews(in: view)
        return scrollViews.count == 1 ? scrollViews.first : nil
    }

    private func detailScrollViews(in view: NSView) -> [NSScrollView] {
        if let scrollView = view as? NSScrollView { return [scrollView] }
        return view.subviews.flatMap { detailScrollViews(in: $0) }
    }

    private func navigateTaskDetail(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
              let contentView = detailPanel.contentView
        else {
            return false
        }
        // A knowledge preview has separate list and diff scrollers. Preserve the
        // native control's keys instead of sending every arrow to the first one.
        let responder = detailPanel.firstResponder as? NSView
        if responder is NSTextView { return false }
        let scrollView = (responder as? NSScrollView) ?? responder?.enclosingScrollView
            ?? (responder == nil || responder === contentView ? singleDetailScrollView(in: contentView) : nil)
        guard let scrollView, scrollView.isDescendant(of: contentView) else { return false }
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

    private func showTaskDetail(_ row: VSCodeTaskRow, rowMidY: CGFloat) {
        guard let task = row.task else {
            hideTaskDetail(clearTriggers: true)
            return
        }
        detailHideTask?.cancel()
        detailHideTask = nil
        let retainsPreview = detailSessionID == task.sessionID && displayedDetailTarget?.rowID == row.id
        displayedDetailTarget = CodexBarDetailTarget(rowID: row.id, rowMidY: rowMidY)
        model.beginConversationPreview(task)
        let preferredHeight = retainsPreview
            ? measuredDetailHeight ?? CodexBarPanelLayout.defaultDetailHeight
            : CodexBarPanelLayout.defaultDetailHeight

        if !retainsPreview {
            measuredDetailHeight = nil
            detailSessionID = task.sessionID
            let rowID = row.id
            let detailView = TaskHoverDetailView(
                model: model,
                store: model.store,
                activityStore: model.activityStore,
                previewStore: model.previewStore,
                knowledgeStore: model.knowledgeStore,
                rowID: rowID,
                onRefreshPreview: { [weak self] in self?.model.refreshConversationPreview() },
                onLoadHistory: { [weak self] in self?.model.loadConversationHistory() },
                onToggleReview: { [weak self] note, currentTask in
                    self?.model.toggleKnowledgeReview(note, for: currentTask)
                },
                onOpenNote: { [weak self] note, currentTask in
                    self?.model.openObsidianNote(note, for: currentTask)
                },
                onOpen: { [weak self] in
                    guard let self,
                          let currentRow = model.visibleRows.first(where: { $0.id == rowID })
                    else {
                        return
                    }
                    hideTaskDetail(clearTriggers: true)
                    model.activate(currentRow)
                },
                onHoverChanged: { [weak self] hovering in
                    self?.detailHoverChanged(hovering)
                },
                onPreferredHeightChanged: { [weak self] preferredHeight in
                    self?.detailHeightChanged(preferredHeight, rowID: rowID, sessionID: task.sessionID)
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

    private func detailHeightChanged(_ preferredHeight: CGFloat, rowID: String, sessionID: String) {
        guard let target = displayedDetailTarget,
              target.rowID == rowID,
              let row = model.visibleRows.first(where: { $0.id == rowID }),
              detailSessionID == sessionID,
              row.task?.sessionID == sessionID
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
        model.endConversationPreview()
        detailSessionID = nil
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
        if knowledgePanel.isVisible { updateKnowledgeFrame() }
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
