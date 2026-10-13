import Darwin
import Foundation
import CodexBarCore

@MainActor
func runtimeStatusMonitoringTests() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "runtime malformed owner frames cannot complete synchronization") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(100))
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publishChange(session: "known", change: nil)
            try await runtimeWait { deliveries.frames.count == 1 }
            try expect(monitor.connectionState != .connected, "an envelope without a state synchronized the session")
            try await runtimeWait { monitor.connectionState == .unavailable }
            try expect(router.discoveryCount == 1, "invalid data introduced a discovery loop")
        },
        CodexBarTestCase(name: "runtime invalid patches restore a bounded synchronization deadline") {
            for startsSynchronized in [false, true] {
                let router = try RuntimeTestRouter()
                defer { router.stop() }
                let deliveries = RuntimeDeliveries()
                let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                        snapshotTimeout: .milliseconds(100))
                monitor.setSessions(["known"])
                monitor.start(onChange: { deliveries.frames.append($0) })
                defer { monitor.stop() }
                try await runtimeWait { router.following("known", value: true) == 1 }
                if startsSynchronized {
                    router.publish(session: "known")
                    try await runtimeWait { monitor.connectionState == .connected }
                }
                let priorCount = deliveries.frames.count
                router.publishChange(session: "known", change: [
                    "type": "patches", "revision": 2, "baseRevision": 99, "patches": []
                ])
                try await runtimeWait { deliveries.frames.count == priorCount + 1 }
                try expect(monitor.connectionState == .synchronizing, "a revision gap kept the session synchronized")
                // The downstream reducer requests one replacement snapshot after a gap.
                monitor.requestSnapshot(sessionID: "known")
                try await runtimeWait { monitor.connectionState == .unavailable }
                try expect(router.discoveryCount == 1, "missing replacement snapshot caused polling")
            }
        },
        CodexBarTestCase(name: "runtime valid replacement snapshots cancel invalidation deadlines") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(150))
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            router.publishChange(session: "known", change: [
                "type": "patches", "revision": 2, "baseRevision": 99, "patches": []
            ])
            try await runtimeWait { monitor.connectionState == .synchronizing }
            monitor.requestSnapshot(sessionID: "known")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            monitor.refresh()
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(200))
            try expect(monitor.connectionState == .connected && monitor.unavailableReason(for: "known") == nil,
                       "same-revision replacement or refresh retained an obsolete deadline")
        },
        CodexBarTestCase(name: "runtime transient turn handoffs preserve valid patch history") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(150))
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            router.publishChange(session: "known", change: [
                "type": "patches", "revision": 2, "baseRevision": 1,
                "patches": [["op": "replace", "path": ["turns"],
                             "value": [["turnId": "turn-1", "status": "completed"]]]]
            ])
            try await runtimeWait { monitor.connectionState == .connected }
            router.publishChange(session: "known", change: [
                "type": "patches", "revision": 3, "baseRevision": 2,
                "patches": [["op": "replace", "path": ["turns"],
                             "value": [["turnId": "turn-2", "status": "inProgress"]]]]
            ])
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "runtime subscription retirement resets repeated owner revisions") {
            for peerDisconnects in [false, true] {
                let router = try RuntimeTestRouter()
                defer { router.stop() }
                let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                        snapshotTimeout: .milliseconds(200))
                monitor.setSessions(["known", "remaining"])
                monitor.start(onChange: { _ in })
                defer { monitor.stop() }
                try await runtimeWait { router.following("known", value: true) == 1
                    && router.following("remaining", value: true) == 1 }
                router.publish(session: "known")
                router.publish(session: "remaining")
                try await runtimeWait { monitor.connectionState == .connected }
                if peerDisconnects {
                    router.peerStatus("disconnected")
                } else {
                    monitor.setSessions(["remaining"])
                    monitor.setSessions(["known", "remaining"])
                }
                try await runtimeWait { router.following("known", value: true) == 2 }
                try expect(monitor.connectionState != .connected, "retired subscription retained synchronized state")
                router.publish(session: "known")
                router.publish(session: "remaining")
                try await runtimeWait { monitor.connectionState == .connected }
            }
        },
        CodexBarTestCase(name: "runtime handshake and owner discovery do not imply a synchronized session") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try expect(monitor.connectionState == .synchronizing,
                       "handshake and owner discovery falsely reported a received session stream")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "content-only first frames do not become false disconnects") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(60))
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: {
                deliveries.unavailable.merge($0) { _, latest in latest }
            })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publishContentOnly(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            try await Task.sleep(for: .milliseconds(100))
            try expect(deliveries.unavailable.isEmpty, "a body-only frame was reported as disconnected")
        },
        CodexBarTestCase(name: "runtime owner discovery failure reports unavailability without a retry loop") {
            let router = try RuntimeTestRouter()
            router.hasOwner = false
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: {
                deliveries.unavailable.merge($0) { _, latest in latest }
            })
            defer { monitor.stop() }
            try await runtimeWait { router.discoveryCount == 1 }
            try await Task.sleep(for: .milliseconds(80))
            try expect(deliveries.unavailable["known"] == .connectionUnavailable,
                       "a no-owner response silently left the session connected")
            try expect(monitor.unavailableReason(for: "known") == .connectionUnavailable,
                       "late subscribers cannot identify the unavailable session")
            try expect(monitor.connectionState != .connected, "failed discovery remained connected")
            try await Task.sleep(for: .milliseconds(100))
            try expect(router.discoveryCount == 1, "failed discovery caused unbounded retries")
            router.hasOwner = true
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 1 }
            try expect(monitor.connectionState != .connected, "rediscovery hid missing stream data")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            try expect(monitor.unavailableReason(for: "known") == nil, "received stream retained failure")
        },
        CodexBarTestCase(name: "runtime owner timeout reports failure and ignores a delayed discovery reply") {
            let router = try RuntimeTestRouter()
            router.repliesToDiscovery = false
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    requestTimeout: .milliseconds(50))
            let deliveries = RuntimeDeliveries()
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: {
                deliveries.unavailable.merge($0) { _, latest in latest }
            })
            defer { monitor.stop() }
            try await runtimeWait { monitor.connectionState == .unavailable }
            try expect(deliveries.unavailable["known"] == .connectionUnavailable, "timeout was not reported")
            let request = try require(router.messages.last { $0["method"] as? String == "thread-owner-discovery" },
                                      "missing discovery request")
            router.replyToDiscovery(request)
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(100))
            try expect(router.discoveryCount == 1 && router.following("known", value: true) == 0
                        && deliveries.frames.isEmpty, "late reply regained authority or triggered a retry loop")
            router.repliesToDiscovery = true
            monitor.retryDiscovery()
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "runtime first-frame timeout is bounded and refresh can recover") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(60))
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: {
                deliveries.unavailable.merge($0) { _, latest in latest }
            })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try expect(monitor.connectionState == .synchronizing, "owner handshake skipped synchronization")
            router.publish(session: "known", source: "other-owner")
            router.publish(session: "known", target: "other-client")
            try await runtimeWait { monitor.connectionState == .unavailable }
            try expect(deliveries.unavailable["known"] == .connectionUnavailable, "missing first frame remained silent")
            let settled = router.discoveryCount
            try await Task.sleep(for: .milliseconds(100))
            try expect(router.discoveryCount == settled, "first-frame timeout created an owner retry loop")
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 2 }
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            try await Task.sleep(for: .milliseconds(100))
            try expect(monitor.connectionState == .connected && monitor.unavailableReason(for: "known") == nil,
                       "valid first frame left a timer or introduced an idle heartbeat")
        },
        CodexBarTestCase(name: "runtime connection reflects every subscribed session and keeps incompatibility priority") {
            let router = try RuntimeTestRouter()
            router.unownedSessions = ["missing"]
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known", "missing"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 && monitor.connectionState == .unavailable }
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(40))
            try expect(monitor.connectionState == .unavailable, "one healthy session hid another missing owner")
            router.publish(session: "known", version: 12)
            try await runtimeWait { monitor.connectionState == .incompatible }
            monitor.setSessions(["missing"])
            try expect(monitor.connectionState == .unavailable, "removed protocol error retained priority")
            router.unownedSessions = []
            monitor.refresh()
            try await runtimeWait { router.following("missing", value: true) == 1 }
            router.publish(session: "missing")
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "runtime pending discovery and first-frame deadlines stop with removed sessions") {
            for awaitsOwner in [false, true] {
                for removesSession in [false, true] {
                    let router = try RuntimeTestRouter()
                    router.repliesToDiscovery = !awaitsOwner
                    defer { router.stop() }
                    let deliveries = RuntimeDeliveries()
                    let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                            requestTimeout: .milliseconds(80), snapshotTimeout: .milliseconds(80))
                    monitor.setSessions(["known"])
                    monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: {
                        deliveries.unavailable.merge($0) { _, latest in latest }
                    })
                    defer { monitor.stop() }
                    try await runtimeWait { awaitsOwner ? router.discoveryCount == 1 : router.following("known", value: true) == 1 }
                    if removesSession { monitor.setSessions([]) } else { monitor.stop() }
                    deliveries.unavailable.removeAll()
                    router.publish(session: "known")
                    try await Task.sleep(for: .milliseconds(140))
                    try expect(monitor.connectionState == .idle && deliveries.unavailable.isEmpty
                               && deliveries.frames.isEmpty && monitor.unavailableReason(for: "known") == nil,
                               "retired session received a timeout or stale stream callback")
                }
            }
        },
        CodexBarTestCase(name: "runtime explicit refresh replaces the pending first-frame deadline") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [],
                                                    snapshotTimeout: .milliseconds(200))
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try await Task.sleep(for: .milliseconds(120))
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 2 }
            try await Task.sleep(for: .milliseconds(110))
            try expect(deliveries.unavailable.isEmpty && monitor.connectionState == .synchronizing,
                       "pre-refresh timer expired the new subscription")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "runtime reconnect cancels the previous owner's first-frame deadline") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home, reconnectDelays: [.milliseconds(20)],
                                                    snapshotTimeout: .milliseconds(200))
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try await Task.sleep(for: .milliseconds(120))
            router.closeClient()
            try await runtimeWait { router.following("known", value: true) == 2 }
            deliveries.unavailable.removeAll()
            try await Task.sleep(for: .milliseconds(100))
            try expect(deliveries.unavailable.isEmpty && router.following("known", value: false) == 0,
                       "old connection's deadline revoked the replacement owner")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
        },
        CodexBarTestCase(name: "runtime monitor reconnects after EOF without replacing its socket") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(
                codexHome: router.home, reconnectDelays: [.milliseconds(30), .milliseconds(60)]
            )
            var states: [CodexRuntimeConnectionState] = []
            monitor.onConnectionStateChange = { states.append($0) }
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try expect(monitor.connectionState == .synchronizing, "initialized transport incorrectly skipped first-frame synchronization")
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            deliveries.frames.removeAll()
            router.closeClient()
            try await runtimeWait { router.following("known", value: true) == 2 }
            try expect(states.contains(.retrying(attempt: 1)), "connection interruption was not reported as retrying")
            try expect(monitor.connectionState != .connected, "reconnection reused the previous stream's authority")
            router.publish(session: "known", source: "other-owner")
            router.publish(session: "known", target: "other-client")
            router.publish(session: "known")
            try await runtimeWait { deliveries.frames.count == 1 }
            try expect(monitor.connectionState == .connected, "reconnected stream did not recover its state")
            try expect(router.acceptedConnections == 2, "reconnection created extra clients")
        },
        CodexBarTestCase(name: "runtime monitor bounds failed reconnects and explicit refresh restarts recovery") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(
                codexHome: router.home, reconnectDelays: [.milliseconds(20), .milliseconds(40), .milliseconds(80)]
            )
            var attempts: [Int] = []
            monitor.onConnectionStateChange = { [weak monitor] state in
                if case let .retrying(attempt) = state { attempts.append(attempt) }
                // Presentation changes may synchronize the same visible sessions again.
                monitor?.setSessions(["known"])
            }
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.rejectsInitialization = true
            router.closeClient()
            try await runtimeWait { monitor.connectionState == .exhausted }
            try expect(attempts == [1, 2, 3], "retry budget was not bounded")
            let settled = router.acceptedConnections
            try await Task.sleep(for: .milliseconds(180))
            try expect(settled == 4 && router.acceptedConnections == settled, "exhausted monitor kept reconnecting")
            router.rejectsInitialization = false
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 2 }
            router.publish(session: "known")
            try await runtimeWait { monitor.connectionState == .connected }
            try expect(monitor.connectionState == .connected, "manual refresh could not recover an exhausted connection")
        },
        CodexBarTestCase(name: "runtime monitor bounds initialization-only connections that immediately close") {
            let router = try RuntimeTestRouter()
            router.closesAfterInitialization = true
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(
                codexHome: router.home, reconnectDelays: [.milliseconds(20), .milliseconds(40), .milliseconds(80)]
            )
            var initializedConnections = 0
            monitor.onConnectionStateChange = { state in
                if state == .synchronizing { initializedConnections += 1 }
            }
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { monitor.connectionState == .exhausted || router.acceptedConnections > 4 }
            try expect(initializedConnections > 0, "fixture never completed a successful initialization")
            try expect(router.acceptedConnections == 4 && monitor.connectionState == .exhausted,
                       "initialization without a trusted stream reset the reconnect budget")
            try await Task.sleep(for: .milliseconds(180))
            try expect(router.acceptedConnections == 4, "initialization-only connections continued after exhaustion")
        },
        CodexBarTestCase(name: "runtime monitor cancels scheduled reconnects on stop or empty sessions") {
            for clearsSessions in [false, true] {
                let router = try RuntimeTestRouter()
                defer { router.stop() }
                let monitor = CodexRuntimeStatusMonitor(
                    codexHome: router.home, reconnectDelays: [.milliseconds(100), .milliseconds(200)]
                )
                var states: [CodexRuntimeConnectionState] = []
                monitor.onConnectionStateChange = { states.append($0) }
                monitor.setSessions(["known"])
                monitor.start(onChange: { _ in })
                defer { monitor.stop() }
                try await runtimeWait { router.following("known", value: true) == 1 }
                router.closeClient()
                try await runtimeWait { monitor.connectionState == .retrying(attempt: 1) }
                if clearsSessions { monitor.setSessions([]) } else { monitor.stop() }
                try expect(monitor.connectionState == .idle, "inactive monitor did not become idle")
                let settled = states.count
                try await Task.sleep(for: .milliseconds(180))
                try expect(router.acceptedConnections == 1 && states.count == settled,
                           "cancelled retry reconnected or delivered a stale state callback")
            }
        },
        CodexBarTestCase(name: "history loading targets the known owner and reports its snapshot revision") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            var completed = false
            var revision: Int?
            monitor.requestCompleteHistory(sessionID: "known") { value in
                revision = value
                completed = true
            }
            try await runtimeWait { completed }
            let request = router.messages.last { $0["method"] as? String == "thread-follower-load-complete-history" }
            try expect(revision == 3, "history completion lost the owner's revision")
            try expect(request?["version"] as? Int == 2 && request?["hostId"] as? String == "local",
                       "history request did not use the host-routed protocol")
            try expect(request?["targetClientId"] as? String == "owner", "history request was not owner-targeted")
            let parameters = request?["params"] as? [String: String]
            try expect(parameters == ["conversationId": "known"], "history request included unrelated parameters")
        },
        CodexBarTestCase(name: "history loading rejects unowned tasks and releases callbacks on stop") {
            let router = try RuntimeTestRouter()
            router.repliesToHistory = false
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            var unknownCompleted = false
            monitor.requestCompleteHistory(sessionID: "unknown") { value in unknownCompleted = value == nil }
            try expect(unknownCompleted, "unknown task attempted a history request")
            var stoppedCompleted = false
            monitor.requestCompleteHistory(sessionID: "known") { value in stoppedCompleted = value == nil }
            try await runtimeWait { router.messages.contains { $0["method"] as? String == "thread-follower-load-complete-history" } }
            monitor.stop()
            try expect(stoppedCompleted, "stop left a history request waiting")
        },
        CodexBarTestCase(name: "history loading rejects a reply from a different owner") {
            let router = try RuntimeTestRouter()
            router.historyReplyOwner = "different-owner"
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            var completed = false
            var accepted = false
            monitor.requestCompleteHistory(sessionID: "known") { value in
                accepted = value != nil
                completed = true
            }
            try await runtimeWait { completed }
            try expect(!accepted, "an unrelated owner completed the history request")
        },
        CodexBarTestCase(name: "runtime monitor follows only known sessions and validates owners without idle requests") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            try expect(router.messages.first?["method"] as? String == "initialize", "initial handshake missing")
            let initialParameters = router.messages.first?["params"] as? [String: Any]
            try expect(initialParameters?["clientType"] as? String == "codexbar", "monitor impersonated an official client")
            let settled = router.messages.count
            try await Task.sleep(for: .milliseconds(180))
            try expect(router.messages.count == settled, "idle monitor issued periodic requests")

            router.publishUnrelated()
            router.publish(session: "unknown")
            router.publish(session: "known", source: "other-owner")
            router.publish(session: "known", target: "other-client")
            router.publish(session: "known", split: true)
            try await runtimeWait { deliveries.frames.count == 1 }
            try expect(deliveries.frames.count == 1, "unowned, incompatible, or untargeted message reached projection")

            monitor.requestSnapshot(sessionID: "known")
            try await runtimeWait { router.following("known", value: true) == 2 }
            monitor.setSessions([])
            try await runtimeWait { deliveries.unavailable["known"] != nil }
            try await runtimeWait { router.disconnected }
        },
        CodexBarTestCase(name: "runtime monitor revokes incompatible streams without retrying on every Hook") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known")
            try await runtimeWait { deliveries.frames.count == 1 }
            router.publish(session: "known", version: 12)
            try await runtimeWait { deliveries.unavailable["known"] != nil }
            try await runtimeWait { router.following("known", value: false) == 1 }
            let unsupported = CodexRuntimeUnavailableReason.unsupportedProtocol(expected: 11, received: 12)
            try expect(deliveries.unavailable["known"] == unsupported, "incompatible stream was reported as a connection failure")
            try expect(monitor.unavailableReason(for: "known") == unsupported, "late preview cannot query incompatibility")
            try expect(monitor.connectionState == .incompatible, "connection state hid stream incompatibility")
            monitor.retryDiscovery()
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(100))
            try expect(deliveries.frames.count == 1 && router.discoveryCount == 1,
                       "incompatible owner was retried or retained authority")
            try expect(router.acceptedConnections == 1, "protocol incompatibility triggered transport reconnects")
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 2 }
            try expect(monitor.unavailableReason(for: "known") == unsupported, "refresh hid incompatibility before supported data arrived")
            router.hasOwner = false
            router.peerStatus("disconnected")
            try await Task.sleep(for: .milliseconds(100))
            try expect(monitor.unavailableReason(for: "known") == unsupported, "disconnect obscured known incompatibility")
            router.hasOwner = true
            router.peerStatus("connected")
            try await runtimeWait { router.following("known", value: true) == 3 }
            router.publish(session: "known")
            try await runtimeWait { deliveries.frames.count == 2 }
            try expect(monitor.unavailableReason(for: "known") == nil, "supported stream did not clear incompatibility")
            try expect(monitor.connectionState == .connected, "supported stream did not restore connected state")
        },
        CodexBarTestCase(name: "snapshot retry explicitly renegotiates an incompatible selected session") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known", version: 12)
            try await runtimeWait { monitor.unavailableReason(for: "known") != nil }
            monitor.requestSnapshot(sessionID: "known")
            try await Task.sleep(for: .milliseconds(80))
            try expect(router.discoveryCount == 1, "ordinary snapshot bypassed incompatible stream suppression")
            monitor.requestSnapshot(sessionID: "known", retryIncompatible: true)
            try await runtimeWait { router.following("known", value: true) == 2 }
            try expect(monitor.unavailableReason(for: "known") != nil, "retry cleared reason before receiving a supported frame")
            monitor.setSessions([])
            try expect(monitor.unavailableReason(for: "known") == nil, "removed session retained unavailable metadata")
        },
        CodexBarTestCase(name: "runtime monitor discovers new peers and invalidates disconnected owners") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            router.hasOwner = false
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            defer { monitor.stop() }
            try await runtimeWait { router.discoveryCount == 1 }
            try await Task.sleep(for: .milliseconds(120))
            try expect(router.discoveryCount == 1, "no-owner response caused a discovery loop")
            router.hasOwner = true
            router.peerStatus("connected")
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.publish(session: "known")
            try await runtimeWait { deliveries.frames.count == 1 }
            router.hasOwner = false
            router.peerStatus("disconnected")
            try await runtimeWait { deliveries.unavailable["known"] != nil }
            try expect(deliveries.unavailable["known"] == .connectionUnavailable, "ordinary disconnect has no distinct reason")
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(100))
            try expect(deliveries.frames.count == 1, "disconnected owner remained trusted")
        },
        CodexBarTestCase(name: "runtime monitor connects when a secure socket appears and rejects exposed sockets") {
            let router = try RuntimeTestRouter(startImmediately: false)
            defer { router.stop() }
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { _ in })
            defer { monitor.stop() }
            try router.start(mode: 0o666)
            try await Task.sleep(for: .milliseconds(160))
            try expect(router.messages.isEmpty, "monitor connected to a world-accessible socket")
            try expect(chmod(router.socketPath, 0o600) == 0, "could not secure fixture socket")
            monitor.refresh()
            try await runtimeWait { router.following("known", value: true) == 1 }
        },
        CodexBarTestCase(name: "runtime monitor reconnects on socket replacement and stops stale callbacks") {
            let router = try RuntimeTestRouter()
            defer { router.stop() }
            let deliveries = RuntimeDeliveries()
            let monitor = CodexRuntimeStatusMonitor(codexHome: router.home)
            monitor.setSessions(["known"])
            monitor.start(onChange: { deliveries.frames.append($0) }, onUnavailable: { deliveries.unavailable.merge($0) { _, latest in latest } })
            try await runtimeWait { router.following("known", value: true) == 1 }
            router.closeListenerAndClient()
            try await runtimeWait { deliveries.unavailable["known"] != nil }
            try router.start()
            try await runtimeWait { router.following("known", value: true) == 2 }
            monitor.stop()
            router.publish(session: "known")
            try await Task.sleep(for: .milliseconds(100))
            try expect(deliveries.frames.isEmpty, "stopped monitor delivered a stale frame")
        }
    ]
}

@MainActor
private final class RuntimeDeliveries {
    var frames: [Data] = []
    var unavailable: [String: CodexRuntimeUnavailableReason] = [:]
}

@MainActor
private func runtimeWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(condition(), "runtime socket event did not arrive")
}

/// A synthetic router; every path and thread ID belongs to this fixture.
@MainActor
private final class RuntimeTestRouter {
    let directory: URL
    let home: URL
    let socketPath: String
    var messages: [[String: Any]] = []
    var hasOwner = true
    var repliesToDiscovery = true
    var unownedSessions: Set<String> = []
    var repliesToHistory = true
    var historyReplyOwner = "owner"
    var disconnected = false
    var rejectsInitialization = false
    var closesAfterInitialization = false
    private(set) var acceptedConnections = 0
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var readSource: (any DispatchSourceRead)?
    private var buffer = Data()

    var discoveryCount: Int { messages.filter { $0["method"] as? String == "thread-owner-discovery" }.count }

    init(startImmediately: Bool = true) throws {
        directory = URL(fileURLWithPath: "/tmp/cbr-\(UUID().uuidString.prefix(12))")
        home = directory.appendingPathComponent("home")
        socketPath = home.appendingPathComponent("ipc/ipc.sock").path
        try FileManager.default.createDirectory(at: home.appendingPathComponent("ipc"), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if startImmediately { try start() }
    }

    func start(mode: mode_t = 0o600) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try expect(listener >= 0, "fixture socket creation failed")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try expect(bound == 0, "fixture bind failed")
        try expect(chmod(socketPath, mode) == 0 && listen(listener, 4) == 0, "fixture listen failed")
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.acceptClient() }
        }
        let descriptor = listener
        source.setCancelHandler { close(descriptor) }
        acceptSource = source
        source.activate()
    }

    func following(_ session: String, value: Bool) -> Int {
        messages.filter {
            let parameters = $0["params"] as? [String: Any]
            return $0["method"] as? String == "thread-stream-following-changed"
                && parameters?["conversationId"] as? String == session
                && parameters?["following"] as? Bool == value
        }.count
    }

    func replyToDiscovery(_ request: [String: Any]) {
        guard let requestID = request["requestId"] as? String else { return }
        let session = (request["params"] as? [String: Any])?["conversationId"] as? String ?? ""
        if hasOwner && !unownedSessions.contains(session) {
            send(["type": "response", "requestId": requestID, "resultType": "success", "method": "thread-owner-discovery",
                  "handledByClientId": "owner", "result": ["supportsUntrustedAppInput": true]])
        } else {
            send(["type": "response", "requestId": requestID, "resultType": "error", "error": "no-client-found"])
        }
    }

    func publishUnrelated() {
        send(["type": "broadcast", "method": "unrelated-notification", "version": 0,
              "sourceClientId": "other-client", "params": ["status": ["type": "active"]]])
    }

    func peerStatus(_ status: String) {
        send(["type": "broadcast", "method": "client-status-changed", "version": 0,
              "sourceClientId": "owner", "params": ["clientId": "owner", "clientType": "vscode", "status": status]])
    }

    func publish(session: String, source: String = "owner", version: Int = 11, target: String = "fixture-client", split: Bool = false) {
        send(["type": "broadcast", "method": "thread-stream-state-changed", "version": version,
              "sourceClientId": source, "targetClientIds": [target],
              "params": ["hostId": "local", "conversationId": session,
                         "change": ["type": "snapshot", "revision": 1,
                                    "conversationState": [
                                        "id": session, "source": "vscode", "cwd": "/tmp/runtime-fixture",
                                        "requests": [], "turns": [["turnId": "turn-1", "status": "inProgress"]],
                                        "threadRuntimeStatus": ["type": "active", "activeFlags": []]
                                    ]]]], split: split)
    }

    func publishContentOnly(session: String) {
        send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
              "sourceClientId": "owner", "targetClientIds": ["fixture-client"],
              "params": ["hostId": "local", "conversationId": session,
                         "change": ["type": "snapshot", "revision": 1,
                                    "conversationState": [
                                        "id": session, "source": "vscode", "cwd": "/tmp/runtime-fixture",
                                        "turns": [["turnId": "turn-1", "items": [[
                                            "id": "message-1", "type": "userMessage", "content": "正文"
                                        ]]]]
                                    ]]]])
    }

    func publishChange(session: String, change: [String: Any]?) {
        var parameters: [String: Any] = ["hostId": "local", "conversationId": session]
        parameters["change"] = change
        send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
              "sourceClientId": "owner", "targetClientIds": ["fixture-client"], "params": parameters])
    }

    func closeClient() {
        if client >= 0 { shutdown(client, SHUT_RDWR) }
        readSource?.cancel()
        readSource = nil
        client = -1
        buffer.removeAll()
    }

    func closeListenerAndClient() {
        acceptSource?.cancel()
        acceptSource = nil
        listener = -1
        closeClient()
        unlink(socketPath)
    }

    func stop() {
        closeListenerAndClient()
        try? FileManager.default.removeItem(at: directory)
    }

    private func acceptClient() {
        guard listener >= 0 else { return }
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { return }
        acceptedConnections += 1
        client = accepted
        disconnected = false
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        var enabled: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.readMessages() }
        }
        source.setCancelHandler { close(accepted) }
        readSource = source
        source.activate()
    }

    private func readMessages() {
        guard client >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(client, &bytes, bytes.count, 0)
        if count == 0 {
            disconnected = true
            readSource?.cancel()
            readSource = nil
            client = -1
            return
        }
        guard count > 0 else { return }
        buffer.append(contentsOf: bytes.prefix(count))
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard buffer.count >= length + 4 else { return }
            let data = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            messages.append(message)
            guard let requestID = message["requestId"] as? String else { continue }
            if message["method"] as? String == "initialize" {
                if rejectsInitialization {
                    closeClient()
                    return
                }
                send(["type": "response", "requestId": requestID, "resultType": "success", "method": "initialize",
                      "handledByClientId": "fixture-client", "result": ["clientId": "fixture-client"]])
            } else if message["method"] as? String == "thread-owner-discovery" {
                // This request proves the client consumed the successful handshake.
                if closesAfterInitialization {
                    closeClient()
                    return
                }
                if repliesToDiscovery { replyToDiscovery(message) }
            } else if message["method"] as? String == "thread-follower-load-complete-history", repliesToHistory {
                send(["type": "response", "requestId": requestID, "resultType": "success",
                      "method": "thread-follower-load-complete-history", "handledByClientId": historyReplyOwner,
                      "result": ["revision": 3]])
            }
        }
    }

    private func send(_ object: [String: Any], split: Bool = false) {
        guard client >= 0, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        if split {
            frame.prefix(2).withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
            frame.dropFirst(2).withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
        } else {
            frame.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
        }
    }
}
