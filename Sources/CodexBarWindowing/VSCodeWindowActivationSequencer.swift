import CodexBarCore

package protocol VSCodeWindowActivationOperations: AnyObject {
    func targetMinimizedState() -> Bool?
    func restoreTarget() -> Bool
    func makeApplicationFrontmost() -> Bool
    func makeTargetMain()
    func raiseTarget() -> Bool
    func isMinimized(_ window: VSCodeWindowDescriptor) -> Bool
    func minimize(_ window: VSCodeWindowDescriptor) -> Bool
    func focusTarget()
}

package enum VSCodeWindowActivationSequenceResult: Equatable, Sendable {
    case activated
    case activatedWithUnminimizedWindows([VSCodeWindowDescriptor])
    case failed
}

package struct VSCodeWindowActivationSequencer: Sendable {
    package init() {}

    package func activate(
        otherWindows: [VSCodeWindowDescriptor],
        using operations: any VSCodeWindowActivationOperations
    ) -> VSCodeWindowActivationSequenceResult {
        guard let targetWasMinimized = operations.targetMinimizedState() else {
            return .failed
        }

        // AXFrontmost is synchronous. Fail closed instead of scheduling
        // NSRunningApplication's asynchronous activation request, which can
        // later undo the other-window minimization.
        guard operations.makeApplicationFrontmost() else {
            return .failed
        }

        if targetWasMinimized, !operations.restoreTarget() {
            return .failed
        }

        operations.makeTargetMain()
        guard operations.raiseTarget() else {
            return .failed
        }

        var unminimizedWindows: [VSCodeWindowDescriptor] = []
        for window in otherWindows where !operations.isMinimized(window) {
            if !operations.minimize(window) {
                unminimizedWindows.append(window)
            }
        }

        operations.focusTarget()
        _ = operations.raiseTarget()
        return unminimizedWindows.isEmpty
            ? .activated
            : .activatedWithUnminimizedWindows(unminimizedWindows)
    }
}
