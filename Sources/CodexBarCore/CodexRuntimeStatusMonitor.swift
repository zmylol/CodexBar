import Darwin
import Foundation
import Network

/// Follows known local Codex threads. Frames are delivered transiently and never persisted.
@MainActor
public final class CodexRuntimeStatusMonitor {
    private struct Envelope: Decodable, Sendable {
        struct Parameters: Decodable, Sendable {
            let conversationId: String?
            let hostId: String?
            let clientId: String?
            let status: String?
        }
        struct Result: Decodable, Sendable { let clientId: String? }
        let type: String
        let method: String?
        let version: Int?
        let requestId: String?
        let sourceClientId: String?
        let targetClientIds: [String]?
        let resultType: String?
        let handledByClientId: String?
        let params: Parameters?
        let result: Result?

        private enum CodingKeys: String, CodingKey {
            case type, method, version, requestId, sourceClientId, targetClientIds
            case resultType, handledByClientId, params, result
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            method = try values.decodeIfPresent(String.self, forKey: .method)
            version = try values.decodeIfPresent(Int.self, forKey: .version)
            requestId = try values.decodeIfPresent(String.self, forKey: .requestId)
            sourceClientId = try values.decodeIfPresent(String.self, forKey: .sourceClientId)
            targetClientIds = try values.decodeIfPresent([String].self, forKey: .targetClientIds)
            resultType = try values.decodeIfPresent(String.self, forKey: .resultType)
            handledByClientId = try values.decodeIfPresent(String.self, forKey: .handledByClientId)
            // Other router clients have unrelated payload schemas; do not decode their fields.
            params = method == "thread-stream-state-changed" || method == "client-status-changed"
                ? try values.decodeIfPresent(Parameters.self, forKey: .params) : nil
            result = type == "response" && method == "initialize"
                ? try values.decodeIfPresent(Result.self, forKey: .result) : nil
        }
    }

    private struct PendingRequest {
        let sessionID: String?
        let timeout: Task<Void, Never>
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static let maximumFrameBytes = 64 * 1024 * 1024
    private static let maximumPendingRequests = 32
    private let codexHome: URL
    private let legacyDirectory: URL?
    private let queue = DispatchQueue(label: "CodexBar.RuntimeStatus")
    private var watches: [String: RuntimeDirectoryWatch] = [:]
    private var sessions: Set<String> = []
    private var owners: [String: String] = [:]
    private var attemptedSessions: Set<String> = []
    private var incompatibleSessions: Set<String> = []
    private var pending: [String: PendingRequest] = [:]
    private var connection: NWConnection?
    private var connectionID: UUID?
    private var connectedSocket: (path: String, identity: FileIdentity)?
    private var clientID: String?
    private var buffer = Data()
    private var running = false
    private var onChange: (@MainActor @Sendable (Data) -> Void)?
    private var onUnavailable: (@MainActor @Sendable (Set<String>) -> Void)?

    public init(codexHome: URL? = nil, legacyDirectory: URL? = nil) {
        self.codexHome = codexHome ?? URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        )
        // Explicit homes (including tests) must not accidentally connect to the user's router.
        self.legacyDirectory = legacyDirectory ?? (codexHome == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("codex-ipc") : nil)
    }

    public func start(
        onChange: @escaping @MainActor @Sendable (Data) -> Void,
        onUnavailable: @escaping @MainActor @Sendable (Set<String>) -> Void = { _ in }
    ) {
        stop()
        running = true
        self.onChange = onChange
        self.onUnavailable = onUnavailable
        refresh()
    }

    public func setSessions(_ sessions: Set<String>) {
        let removed = self.sessions.subtracting(sessions)
        for sessionID in removed {
            if let owner = owners.removeValue(forKey: sessionID) {
                sendFollowing(sessionID, owner: owner, following: false)
            }
        }
        for (requestID, request) in pending where request.sessionID.map(removed.contains) == true {
            request.timeout.cancel()
            pending.removeValue(forKey: requestID)
        }
        attemptedSessions.subtract(removed)
        incompatibleSessions.subtract(removed)
        self.sessions = sessions
        if !removed.isEmpty { onUnavailable?(removed) }
        guard running else { return }
        if sessions.isEmpty {
            disconnect()
        } else if connection == nil {
            refresh()
        } else {
            discoverMissingSessions()
        }
    }

    /// Called by explicit refresh, Hook activity, or window events; never by a repeating timer.
    public func refresh() {
        guard running else { return }
        refreshDirectoryWatches()
        if let connectedSocket,
           secureSocket(at: connectedSocket.path) != connectedSocket.identity {
            disconnect()
        }
        attemptedSessions.removeAll()
        incompatibleSessions.removeAll()
        if connection == nil {
            connectToExistingSocket()
        } else if clientID != nil {
            for (sessionID, owner) in owners {
                sendFollowing(sessionID, owner: owner, following: true)
            }
            discoverMissingSessions()
        }
    }

    /// Retries unavailable owners after a Hook or window event without re-copying known threads.
    public func retryDiscovery() {
        guard running else { return }
        refreshDirectoryWatches()
        if let connectedSocket,
           secureSocket(at: connectedSocket.path) != connectedSocket.identity {
            disconnect()
        }
        attemptedSessions.removeAll()
        if connection == nil { connectToExistingSocket() }
        else { discoverMissingSessions() }
    }

    public func requestSnapshot(sessionID: String) {
        guard running, sessions.contains(sessionID) else { return }
        if let owner = owners[sessionID] {
            sendFollowing(sessionID, owner: owner, following: true)
        } else {
            attemptedSessions.remove(sessionID)
            if connection == nil { refresh() } else { discoverMissingSessions() }
        }
    }

    public func stop() {
        for (sessionID, owner) in owners {
            sendFollowing(sessionID, owner: owner, following: false)
        }
        running = false
        disconnect()
        watches.removeAll()
        onChange = nil
        onUnavailable = nil
    }

    deinit {
        connection?.cancel()
        for request in pending.values { request.timeout.cancel() }
    }

    private func disconnect() {
        let unavailable = Set(owners.keys)
        connectionID = nil
        connection?.cancel()
        connection = nil
        connectedSocket = nil
        clientID = nil
        buffer.removeAll(keepingCapacity: false)
        owners.removeAll()
        attemptedSessions.removeAll()
        incompatibleSessions.removeAll()
        for request in pending.values { request.timeout.cancel() }
        pending.removeAll()
        if !unavailable.isEmpty { onUnavailable?(unavailable) }
    }

    private var socketPaths: [String] {
        var paths = [codexHome.appendingPathComponent("ipc/ipc.sock").path]
        if let legacyDirectory {
            paths.append(legacyDirectory.appendingPathComponent("ipc-\(getuid()).sock").path)
        }
        return paths
    }

    private func secureSocket(at path: String) -> FileIdentity? {
        var directory = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o022 == 0 else { return nil }
        var socket = stat()
        guard lstat(path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
              socket.st_uid == getuid(), socket.st_mode & 0o077 == 0 else { return nil }
        return FileIdentity(device: socket.st_dev, inode: socket.st_ino)
    }

    private func connectToExistingSocket() {
        guard running, !sessions.isEmpty, connection == nil else { return }
        guard let endpoint = socketPaths.compactMap({ path in
            secureSocket(at: path).map { (path, $0) }
        }).first else { return }
        let connectionID = UUID()
        let connection = NWConnection(to: .unix(path: endpoint.0), using: .tcp)
        self.connectionID = connectionID
        self.connection = connection
        connectedSocket = endpoint
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID else { return }
                switch state {
                case .ready:
                    guard self.secureSocket(at: endpoint.0) == endpoint.1 else {
                        self.disconnect()
                        return
                    }
                    self.sendRequest(method: "initialize", version: 0, sessionID: nil,
                                     params: ["clientType": "codexbar"])
                    self.receive(connectionID: connectionID)
                case .failed, .cancelled, .waiting:
                    self.disconnect()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(connectionID: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID else { return }
                if let data { await self.consume(data, connectionID: connectionID) }
                guard self.connectionID == connectionID else { return }
                if complete || error != nil { self.disconnect() }
                else { self.receive(connectionID: connectionID) }
            }
        }
    }

    private func consume(_ data: Data, connectionID: UUID) async {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard length > 0, length <= Self.maximumFrameBytes else { disconnect(); return }
            guard buffer.count >= length + 4 else { return }
            let frame = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            let envelope = await Task.detached(priority: .utility) {
                try? JSONDecoder().decode(Envelope.self, from: frame)
            }.value
            guard self.connectionID == connectionID else { return }
            guard let envelope else { disconnect(); return }
            handle(envelope, frame: frame)
            if connection == nil { return }
        }
    }

    private func handle(_ envelope: Envelope, frame: Data) {
        if envelope.type == "client-discovery-request", let requestID = envelope.requestId {
            send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        if envelope.type == "response", let requestID = envelope.requestId,
           let request = pending.removeValue(forKey: requestID) {
            request.timeout.cancel()
            if let sessionID = request.sessionID {
                if envelope.resultType == "success", envelope.method == "thread-owner-discovery",
                   sessions.contains(sessionID), let owner = envelope.handledByClientId,
                   !owner.isEmpty, owner != clientID {
                    owners[sessionID] = owner
                    sendFollowing(sessionID, owner: owner, following: true)
                }
                discoverMissingSessions()
            } else if envelope.resultType == "success", envelope.method == "initialize",
                      let clientID = envelope.result?.clientId, !clientID.isEmpty {
                self.clientID = clientID
                discoverMissingSessions()
            } else {
                disconnect()
            }
            return
        }
        guard envelope.type == "broadcast",
              envelope.targetClientIds == nil || clientID.map({ envelope.targetClientIds?.contains($0) == true }) == true else { return }
        if envelope.method == "client-status-changed", (envelope.version ?? 0) == 0,
           let peerID = envelope.params?.clientId, peerID != clientID {
            if envelope.params?.status == "disconnected" {
                let unavailable = Set(owners.filter { $0.value == peerID }.keys)
                for sessionID in unavailable { owners.removeValue(forKey: sessionID) }
                if !unavailable.isEmpty { onUnavailable?(unavailable) }
            }
            if envelope.params?.status == "connected" || envelope.params?.status == "disconnected" {
                attemptedSessions.removeAll()
                incompatibleSessions.removeAll()
                discoverMissingSessions()
            }
            return
        }
        guard envelope.method == "thread-stream-state-changed",
              envelope.params?.hostId == "local", let sessionID = envelope.params?.conversationId,
              sessions.contains(sessionID), let owner = owners[sessionID], envelope.sourceClientId == owner else { return }
        guard envelope.version == 11 else {
            // Stop trusting this stream until explicit refresh or a peer lifecycle change.
            sendFollowing(sessionID, owner: owner, following: false)
            owners.removeValue(forKey: sessionID)
            incompatibleSessions.insert(sessionID)
            onUnavailable?([sessionID])
            return
        }
        onChange?(frame)
    }

    private func discoverMissingSessions() {
        guard running, clientID != nil else { return }
        let discovering = Set(pending.values.compactMap(\.sessionID))
        for sessionID in sessions.sorted() where owners[sessionID] == nil
            && !attemptedSessions.contains(sessionID) && !incompatibleSessions.contains(sessionID)
            && !discovering.contains(sessionID) {
            guard pending.count < Self.maximumPendingRequests else { break }
            attemptedSessions.insert(sessionID)
            sendRequest(method: "thread-owner-discovery", version: 1, sessionID: sessionID,
                        params: ["hostId": "local", "conversationId": sessionID])
        }
    }

    private func sendRequest(method: String, version: Int, sessionID: String?, params: [String: String]) {
        guard let connectionID else { return }
        let requestID = UUID().uuidString
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.connectionID == connectionID,
                  let request = self.pending.removeValue(forKey: requestID) else { return }
            if request.sessionID == nil { self.disconnect() }
            else { self.discoverMissingSessions() }
        }
        pending[requestID] = PendingRequest(sessionID: sessionID, timeout: timeout)
        send(["type": "request", "requestId": requestID, "sourceClientId": clientID ?? "initializing-client",
              "version": version, "method": method, "params": params, "timeoutMs": 5000])
    }

    private func sendFollowing(_ sessionID: String, owner: String, following: Bool) {
        guard let clientID else { return }
        send(["type": "broadcast", "sourceClientId": clientID, "targetClientIds": [owner],
              "method": "thread-stream-following-changed", "version": 1,
              "params": ["hostId": "local", "conversationId": sessionID, "following": following]])
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let connectionID, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID else { return }
                self.disconnect()
            }
        })
    }

    private func refreshDirectoryWatches() {
        var directories = [codexHome.deletingLastPathComponent(), codexHome, codexHome.appendingPathComponent("ipc")]
        if let legacyDirectory { directories += [legacyDirectory.deletingLastPathComponent(), legacyDirectory] }
        for directory in directories {
            let path = directory.path
            let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
            guard descriptor >= 0 else { watches.removeValue(forKey: path); continue }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                watches.removeValue(forKey: path)
                continue
            }
            if let watch = watches[path], watch.device == status.st_dev, watch.inode == status.st_ino {
                close(descriptor)
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            let watch = RuntimeDirectoryWatch(source: source, device: status.st_dev, inode: status.st_ino)
            let watchID = watch.id
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.watches[path]?.id == watchID else { return }
                    self.refreshDirectoryWatches()
                    if let socket = self.connectedSocket, self.secureSocket(at: socket.path) != socket.identity {
                        self.disconnect()
                    }
                    if self.connection == nil { self.connectToExistingSocket() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            watches[path] = watch
            source.activate()
        }
    }
}

private final class RuntimeDirectoryWatch: @unchecked Sendable {
    let id = UUID()
    let source: any DispatchSourceFileSystemObject
    let device: dev_t
    let inode: ino_t

    init(source: any DispatchSourceFileSystemObject, device: dev_t, inode: ino_t) {
        self.source = source
        self.device = device
        self.inode = inode
    }

    deinit { source.cancel() }
}
