import Darwin
import Foundation
import CodexBarCore

@MainActor
func runtimeStatusMonitoringTests() -> [CodexBarTestCase] {
    [
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
            try expect(monitor.connectionState == .connected, "initialized connection was not reported")
            router.closeClient()
            try await runtimeWait { router.following("known", value: true) == 2 }
            try expect(states.contains(.retrying(attempt: 1)), "connection interruption was not reported as retrying")
            try expect(monitor.connectionState == .connected, "reconnected monitor did not recover its state")
            router.publish(session: "known", source: "other-owner")
            router.publish(session: "known", target: "other-client")
            router.publish(session: "known")
            try await runtimeWait { deliveries.frames.count == 1 }
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
            try expect(monitor.connectionState == .connected, "manual refresh could not recover an exhausted connection")
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
    var repliesToHistory = true
    var historyReplyOwner = "owner"
    var disconnected = false
    var rejectsInitialization = false
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
                                    "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": []]]]]], split: split)
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
                if hasOwner {
                    send(["type": "response", "requestId": requestID, "resultType": "success", "method": "thread-owner-discovery",
                          "handledByClientId": "owner", "result": ["supportsUntrustedAppInput": true]])
                } else {
                    send(["type": "response", "requestId": requestID, "resultType": "error", "error": "no-client-found"])
                }
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
