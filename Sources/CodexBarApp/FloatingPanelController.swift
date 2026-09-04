import AppKit
import CodexBarCore
import SwiftUI

private final class CodexBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CodexBarDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    private var detailTaskID: String?
    private var isDetailHovered = false
    private var isUpdatingPanelFrame = false

    init(model: CodexBarAppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        let initialHeight = Self.height(taskCount: model.store.tasks.count, noticeVisible: false)
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
        let initialDetailHeight = CodexBarPanelLayout.detailHeight(visibleItemCount: 0)
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
            onDismissTaskDetail: { [weak self] in
                self?.hideTaskDetail(clearTriggers: true)
            }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        detailPanel.level = .floating
        detailPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        detailPanel.hidesOnDeactivate = false
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = true
        detailPanel.becomesKeyOnlyIfNeeded = true
        detailPanel.animationBehavior = .none
        restorePosition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func updateHeight(taskCount: Int, noticeVisible: Bool, animated: Bool) {
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size.height = Self.height(taskCount: taskCount, noticeVisible: noticeVisible)
        frame.origin.y = topEdge - frame.height
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
        if isUpdatingPanelFrame && NSEvent.pressedMouseButtons == 0 {
            return
        }
        panelFrameUpdateTask?.cancel()
        panelFrameUpdateTask = nil
        isUpdatingPanelFrame = false
        hideTaskDetail(clearTriggers: true)
        persistPanelOrigin()
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
        guard let target = detailSelection.selected else {
            hideTaskDetail(clearTriggers: false)
            return
        }
        guard let task = model.store.tasks.first(where: { $0.cwd == target.cwd }) else {
            detailSelection.clear()
            hideTaskDetail(clearTriggers: false)
            return
        }
        showTaskDetail(task, rowMidY: target.rowMidY)
    }

    private func showTaskDetail(_ task: CodexTask, rowMidY: CGFloat) {
        detailHideTask?.cancel()
        detailHideTask = nil
        let preferredHeight = preferredDetailHeight(for: task)

        if detailTaskID != task.id {
            let cwd = task.cwd
            let detailView = TaskHoverDetailView(
                store: model.store,
                activityStore: model.activityStore,
                cwd: cwd,
                onOpen: { [weak self] in
                    guard let self,
                          let currentTask = model.store.tasks.first(where: { $0.cwd == cwd })
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
                    self?.detailHeightChanged(preferredHeight, cwd: cwd)
                },
                onDismiss: { [weak self] in
                    self?.hideTaskDetail(clearTriggers: true)
                }
            )
            let hostingView = NSHostingView(rootView: detailView)
            hostingView.sizingOptions = []
            detailPanel.contentView = hostingView
            detailTaskID = task.id
        }

        updateDetailFrame(rowMidY: rowMidY, preferredHeight: preferredHeight)
        detailPanel.orderFrontRegardless()
    }

    private func preferredDetailHeight(for task: CodexTask) -> CGFloat {
        let visibleItemCount: Int
        if let plan = model.activityStore.plan(for: task) {
            visibleItemCount = plan.visibleSteps(
                maximumCount: CodexBarPanelLayout.maximumVisiblePlanSteps
            ).count
        } else {
            visibleItemCount = model.activityStore.nodes(for: task).count
        }
        return CodexBarPanelLayout.detailHeight(visibleItemCount: visibleItemCount)
    }

    private func detailHeightChanged(_ preferredHeight: CGFloat, cwd: String) {
        guard detailPanel.isVisible,
              let target = detailSelection.selected,
              target.cwd == cwd,
              let task = model.store.tasks.first(where: { $0.cwd == cwd }),
              detailTaskID == task.id
        else {
            return
        }
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
                  !isDetailHovered else {
                return
            }
            refreshTaskDetail()
        }
    }

    private func hideTaskDetail(clearTriggers: Bool) {
        detailHideTask?.cancel()
        detailHideTask = nil
        detailPanel.orderOut(nil)
        detailPanel.contentView = nil
        detailTaskID = nil
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

    private static func height(taskCount: Int, noticeVisible: Bool) -> CGFloat {
        CodexBarPanelLayout.height(
            taskCount: taskCount,
            noticeVisible: noticeVisible
        )
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
