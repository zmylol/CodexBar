import Foundation
import CodexBarCore
import CodexBarWindowing

@MainActor
func windowActivationSequencingTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "ordinary switching restores only its target and preserves other window states") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "reference — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "notes — Visual Studio Code")
            ]
            guard case let .planned(plan) = VSCodeWindowMatcher().focusPlan(
                cwd: "/work/project-alpha", windows: windows
            ) else {
                throw TestFailure(description: "target window was not matched")
            }
            let operations = FakeWindowActivationOperations()
            operations.targetMinimizedStateResult = true
            operations.minimizedWindowIDs = [3]

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: plan.windowsToMinimize, using: operations
            )

            try expect(result == .activated, "ordinary window switching failed")
            try expect(
                operations.calls == [
                    "targetMinimizedState", "makeApplicationFrontmost", "restoreTarget",
                    "makeTargetMain", "raiseTarget", "focusTarget", "raiseTarget"
                ],
                "ordinary switching changed another window's minimized state"
            )
        },
        CodexBarTestCase(name: "uses AXFrontmost before minimizing other windows") {
            let otherWindows = [
                VSCodeWindowDescriptor(id: 2, title: "Codexbar — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "project-alpha — Visual Studio Code")
            ]
            let operations = FakeWindowActivationOperations()

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: otherWindows,
                using: operations
            )

            try expect(result == .activated, "activation did not succeed")
            try expect(
                operations.calls == [
                    "targetMinimizedState",
                    "makeApplicationFrontmost",
                    "makeTargetMain",
                    "raiseTarget",
                    "isMinimized:2",
                    "minimize:2",
                    "isMinimized:3",
                    "minimize:3",
                    "focusTarget",
                    "raiseTarget"
                ],
                "window activation operations ran in an unsafe order"
            )
        },
        CodexBarTestCase(name: "reports every window rejected by AXMinimized") {
            let otherWindows = [
                VSCodeWindowDescriptor(id: 2, title: "Codexbar — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "project-alpha — Visual Studio Code")
            ]
            let operations = FakeWindowActivationOperations()
            operations.minimizeResults[2] = false

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: otherWindows,
                using: operations
            )

            try expect(
                result == .activatedWithUnminimizedWindows([otherWindows[0]]),
                "partial minimization failure was not reported"
            )
        },
        CodexBarTestCase(name: "fails closed when AXFrontmost cannot activate VS Code") {
            let operations = FakeWindowActivationOperations()
            operations.frontmostResult = false

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: [VSCodeWindowDescriptor(id: 2, title: "other")],
                using: operations
            )

            try expect(result == .failed, "asynchronous activation fallback was treated as safe")
            try expect(
                operations.calls == ["targetMinimizedState", "makeApplicationFrontmost"],
                "other windows were touched after AXFrontmost failed"
            )
        },
        CodexBarTestCase(name: "does not restore a minimized target when AXFrontmost fails") {
            let operations = FakeWindowActivationOperations()
            operations.targetMinimizedStateResult = true
            operations.frontmostResult = false

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: [],
                using: operations
            )

            try expect(result == .failed, "failed AXFrontmost was treated as success")
            try expect(
                operations.calls == ["targetMinimizedState", "makeApplicationFrontmost"],
                "the target was restored before AXFrontmost succeeded"
            )
        },
        CodexBarTestCase(name: "fails closed when target minimized state cannot be read") {
            let operations = FakeWindowActivationOperations()
            operations.targetMinimizedStateResult = nil

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: [],
                using: operations
            )

            try expect(result == .failed, "unknown target minimized state was treated as visible")
            try expect(
                operations.calls == ["targetMinimizedState"],
                "activation continued after the target state read failed"
            )
        },
        CodexBarTestCase(name: "does not touch other windows when target restore fails") {
            let operations = FakeWindowActivationOperations()
            operations.targetMinimizedStateResult = true
            operations.restoreTargetResult = false

            let result = VSCodeWindowActivationSequencer().activate(
                otherWindows: [VSCodeWindowDescriptor(id: 2, title: "other")],
                using: operations
            )

            try expect(result == .failed, "failed target restore was treated as activation success")
            try expect(
                operations.calls == [
                    "targetMinimizedState",
                    "makeApplicationFrontmost",
                    "restoreTarget"
                ],
                "other windows were touched after target restore failed"
            )
        },
        CodexBarTestCase(name: "rejects a reused VS Code process identity") {
            let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
            let identity = VSCodeApplicationIdentity(
                processIdentifier: 123,
                bundleIdentifier: "com.microsoft.VSCode",
                launchDate: launchDate
            )

            try expect(
                identity.matches(
                    processIdentifier: 123,
                    bundleIdentifier: "com.microsoft.VSCode",
                    launchDate: launchDate,
                    isTerminated: false,
                    hasValidCodeSignature: true
                ),
                "the original process identity was rejected"
            )
            try expect(
                !identity.matches(
                    processIdentifier: 123,
                    bundleIdentifier: "com.example.Other",
                    launchDate: launchDate,
                    isTerminated: false,
                    hasValidCodeSignature: true
                ),
                "a reused PID owned by another app was accepted"
            )
            try expect(
                !identity.matches(
                    processIdentifier: 123,
                    bundleIdentifier: "com.microsoft.VSCode",
                    launchDate: launchDate.addingTimeInterval(1),
                    isTerminated: false,
                    hasValidCodeSignature: true
                ),
                "a newer process with the same PID and bundle id was accepted"
            )
            try expect(
                !identity.matches(
                    processIdentifier: 123,
                    bundleIdentifier: "com.microsoft.VSCode",
                    launchDate: launchDate,
                    isTerminated: false,
                    hasValidCodeSignature: false
                ),
                "a process without the official VS Code signature was accepted"
            )
        }
    ]
}

private final class FakeWindowActivationOperations: VSCodeWindowActivationOperations {
    var calls: [String] = []
    var targetMinimizedStateResult: Bool? = false
    var restoreTargetResult = true
    var frontmostResult = true
    var raiseTargetResult = true
    var minimizedWindowIDs: Set<Int> = []
    var minimizeResults: [Int: Bool] = [:]

    func targetMinimizedState() -> Bool? {
        calls.append("targetMinimizedState")
        return targetMinimizedStateResult
    }

    func restoreTarget() -> Bool {
        calls.append("restoreTarget")
        return restoreTargetResult
    }

    func makeApplicationFrontmost() -> Bool {
        calls.append("makeApplicationFrontmost")
        return frontmostResult
    }

    func makeTargetMain() {
        calls.append("makeTargetMain")
    }

    func raiseTarget() -> Bool {
        calls.append("raiseTarget")
        return raiseTargetResult
    }

    func isMinimized(_ window: VSCodeWindowDescriptor) -> Bool {
        calls.append("isMinimized:\(window.id)")
        return minimizedWindowIDs.contains(window.id)
    }

    func minimize(_ window: VSCodeWindowDescriptor) -> Bool {
        calls.append("minimize:\(window.id)")
        return minimizeResults[window.id] ?? true
    }

    func focusTarget() {
        calls.append("focusTarget")
    }
}
