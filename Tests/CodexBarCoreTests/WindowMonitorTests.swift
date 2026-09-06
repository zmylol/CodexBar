import Foundation
import CodexBarWindowing

@MainActor
func windowMonitorTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "window monitoring attaches once and retains zero-window applications") {
            let backend = FakeWindowObservationBackend()
            let session = VSCodeWindowObservationSession(backend: backend)
            let identity = monitoredApplication()
            try expect(session.refresh([identity]) == .observing, "initial registration failed")
            try expect(session.refresh([identity]) == .observing, "refresh failed")
            try expect(backend.created == [123], "unchanged application was registered twice")
            try expect(backend.removed.isEmpty, "zero-window application lost its window-created listener")
            try expect(backend.refreshed == [123, 123], "existing windows were not observed on each external event")
        },
        CodexBarTestCase(name: "window monitoring removes exited applications and replaces reused processes") {
            let backend = FakeWindowObservationBackend()
            let session = VSCodeWindowObservationSession(backend: backend)
            _ = session.refresh([monitoredApplication()])
            _ = session.refresh([monitoredApplication(launchTime: 20)])
            try expect(backend.removed == [123], "a reused PID kept stale AX listeners")
            try expect(backend.created == [123, 123], "new process identity was not registered")
            try expect(session.refresh([]) == .observing, "last app termination was treated as a failure")
            try expect(backend.removed == [123, 123], "terminated app listeners were not removed")
        },
        CodexBarTestCase(name: "window monitoring reports revoked permission and recovers on an external event") {
            let backend = FakeWindowObservationBackend()
            let session = VSCodeWindowObservationSession(backend: backend)
            _ = session.refresh([monitoredApplication()])
            backend.isTrusted = false
            try expect(session.refresh([monitoredApplication()]) == .accessibilityPermissionRequired,
                       "revoked permission was reported as observing")
            try expect(backend.removed == [123], "permission revocation kept stale subscriptions")
            backend.isTrusted = true
            try expect(session.refresh([monitoredApplication()]) == .observing,
                       "an event after permission grant did not recover monitoring")
            try expect(backend.created == [123, 123], "permission recovery did not reattach listeners")
        },
        CodexBarTestCase(name: "window monitoring exposes listener and window-registration failures") {
            let backend = FakeWindowObservationBackend()
            let session = VSCodeWindowObservationSession(backend: backend)
            backend.canCreate = false
            try expect(session.refresh([monitoredApplication()]) == .failed,
                       "failed AXObserver creation was hidden")
            backend.canCreate = true
            backend.canRefresh = false
            try expect(session.refresh([monitoredApplication()]) == .failed,
                       "failed per-window notifications were hidden")
            backend.canRefresh = true
            try expect(session.refresh([monitoredApplication()]) == .observing,
                       "explicit refresh did not recover failed listeners")
        },
        CodexBarTestCase(name: "window monitoring rejects stale or unsigned identities and tears down on stop") {
            let backend = FakeWindowObservationBackend()
            let session = VSCodeWindowObservationSession(backend: backend)
            backend.isCurrent = false
            try expect(session.refresh([monitoredApplication()]) == .failed,
                       "an unverified process was reported as observed")
            try expect(backend.created.isEmpty, "an unverified process received AX listeners")
            backend.isCurrent = true
            _ = session.refresh([monitoredApplication()])
            backend.isCurrent = false
            _ = session.refresh([monitoredApplication()])
            try expect(backend.removed == [123], "an invalidated identity kept active listeners")
            backend.isCurrent = true
            _ = session.refresh([monitoredApplication()])
            session.stop()
            session.stop()
            try expect(backend.removed == [123, 123], "stop leaked or removed listeners twice")
        }
    ]
}

private func monitoredApplication(launchTime: TimeInterval = 10) -> VSCodeApplicationIdentity {
    VSCodeApplicationIdentity(processIdentifier: 123, bundleIdentifier: "com.microsoft.VSCode",
                              launchDate: Date(timeIntervalSince1970: launchTime))
}

private final class FakeWindowObservationBackend: VSCodeWindowObservationBackend {
    var isTrusted = true
    var isCurrent = true
    var canCreate = true
    var canRefresh = true
    var created: [Int32] = []
    var removed: [Int32] = []
    var refreshed: [Int32] = []

    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool { isCurrent }

    func createObservation(for identity: VSCodeApplicationIdentity) -> Int32? {
        guard canCreate else { return nil }
        created.append(identity.processIdentifier)
        return identity.processIdentifier
    }

    func refreshWindows(in observation: Int32) -> Bool {
        refreshed.append(observation)
        return canRefresh
    }

    func removeObservation(_ observation: Int32) { removed.append(observation) }
}
