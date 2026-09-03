import Darwin
import Foundation
import Security

/// Finds the Codex executable shipped with the newest installed official VS Code extension.
public enum CodexExecutableLocator {
    public static func visualStudioCodeExtensionExecutable(
        extensionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        visualStudioCodeExtensionExecutable(
            extensionsDirectory: extensionsDirectory,
            fileManager: fileManager,
            signatureValidator: OfficialCodexExecutableValidator.validate
        )
    }

    package static func visualStudioCodeExtensionExecutable(
        extensionsDirectory: URL,
        fileManager: FileManager = .default,
        signatureValidator: (URL) -> Bool
    ) -> URL? {
        guard let extensionURLs = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        #if arch(arm64)
        let executableSubpath = "bin/macos-aarch64/codex"
        #elseif arch(x86_64)
        let executableSubpath = "bin/macos-x86_64/codex"
        #else
        return nil
        #endif

        let installedExtensions = extensionURLs
            .filter { url in
                guard url.lastPathComponent.hasPrefix("openai.chatgpt-") else {
                    return false
                }
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ) else {
                    return false
                }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: [.caseInsensitive, .numeric]
                ) == .orderedDescending
            }

        for extensionURL in installedExtensions {
            let candidate = extensionURL.appendingPathComponent(executableSubpath)
            let architectureDirectory = candidate.deletingLastPathComponent()
            let binDirectory = architectureDirectory.deletingLastPathComponent()
            let resolvedExtensionPath = extensionURL.resolvingSymlinksInPath().path
            let resolvedCandidatePath = candidate.resolvingSymlinksInPath().path
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  safeDirectory(binDirectory),
                  safeDirectory(architectureDirectory),
                  resolvedCandidatePath.hasPrefix(resolvedExtensionPath + "/"),
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  signatureValidator(candidate)
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func safeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

/// Locates and verifies the installed official VS Code Codex off the main actor.
public actor InstalledVSCodeCodexThreadSnapshotSource: CodexThreadSnapshotLoading {
    public init() {}

    public func loadSnapshots(
        matching windows: [VSCodeWindowDescriptor]
    ) async throws -> [CodexThreadSnapshot] {
        try Task.checkCancellation()
        guard let executableURL = CodexExecutableLocator
            .visualStudioCodeExtensionExecutable()
        else {
            throw CodexAppServerSnapshotError.executableUnavailable
        }
        try Task.checkCancellation()
        return try await CodexAppServerThreadSnapshotSource(
            executableURL: executableURL
        ).loadSnapshots(matching: windows)
    }

    public func loadSnapshots(
        matchingActiveTasks tasks: [CodexTask]
    ) async throws -> [CodexThreadSnapshot] {
        try Task.checkCancellation()
        guard let executableURL = CodexExecutableLocator
            .visualStudioCodeExtensionExecutable()
        else {
            throw CodexAppServerSnapshotError.executableUnavailable
        }
        try Task.checkCancellation()
        return try await CodexAppServerThreadSnapshotSource(
            executableURL: executableURL
        ).loadSnapshots(matchingActiveTasks: tasks)
    }
}

/// Reads only the small persisted metadata needed to reconstruct menu-bar rows.
/// Full turns and transcript items are deliberately never requested.
public actor CodexAppServerThreadSnapshotSource: CodexThreadSnapshotLoading {
    private static let threadPageSize = 100
    private static let maximumThreads = 500
    private static let maximumWindows = 128
    private static let maximumSessionTimeout: TimeInterval = 60

    private let executableURL: URL
    private let sessionTimeout: TimeInterval
    private let executableValidator: @Sendable (URL) -> Bool

    public init(
        executableURL: URL,
        sessionTimeout: TimeInterval = 8
    ) {
        self.executableURL = executableURL
        self.sessionTimeout = sessionTimeout
        self.executableValidator = OfficialCodexExecutableValidator.validate
    }

    package init(
        executableURL: URL,
        sessionTimeout: TimeInterval = 8,
        executableValidator: @escaping @Sendable (URL) -> Bool
    ) {
        self.executableURL = executableURL
        self.sessionTimeout = sessionTimeout
        self.executableValidator = executableValidator
    }

    public func loadSnapshots(
        matching windows: [VSCodeWindowDescriptor]
    ) async throws -> [CodexThreadSnapshot] {
        try loadSnapshotsSynchronously(matching: windows)
    }

    public func loadSnapshots(
        matchingActiveTasks tasks: [CodexTask]
    ) async throws -> [CodexThreadSnapshot] {
        try loadSnapshotsSynchronously(matchingActiveTasks: tasks)
    }

    private func loadSnapshotsSynchronously(
        matching windows: [VSCodeWindowDescriptor]
    ) throws -> [CodexThreadSnapshot] {
        guard !windows.isEmpty else {
            return []
        }
        guard sessionTimeout.isFinite,
              sessionTimeout > 0,
              sessionTimeout <= Self.maximumSessionTimeout,
              windows.count <= Self.maximumWindows,
              Set(windows.map(\.id)).count == windows.count,
              windows.allSatisfy({ $0.title.utf8.count <= 4_096 })
        else {
            throw CodexAppServerSnapshotError.invalidInput
        }
        try validateExecutable()

        let session = try CodexAppServerRPCSession(
            executableURL: executableURL,
            timeout: sessionTimeout
        )
        defer { session.abortIfNeeded() }
        try session.initialize()

        let threads = try loadThreads(
            session: session,
            sourceKinds: [.vscode]
        )
        let matcher = VSCodeWindowMatcher()
        var latestByCWD: [String: AppServerThread] = [:]
        for thread in threads {
            guard case let .matched(window) = matcher.match(
                cwd: thread.cwd,
                windows: windows
            ) else {
                continue
            }
            let matched = thread.withWindowID(window.id)
            if let current = latestByCWD[matched.cwd],
               !matched.isNewer(than: current) {
                continue
            }
            latestByCWD[matched.cwd] = matched
        }

        var threadsByWindowID: [Int: [AppServerThread]] = [:]
        for thread in latestByCWD.values {
            guard let windowID = thread.windowID else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            threadsByWindowID[windowID, default: []].append(thread)
        }

        // A title containing the same final path component cannot distinguish two cwd values.
        let selectedThreads = threadsByWindowID.values.compactMap { candidates in
            candidates.count == 1 ? candidates[0] : nil
        }
        guard selectedThreads.count <= Self.maximumWindows else {
            throw CodexAppServerSnapshotError.responseLimitExceeded
        }

        let snapshots = try loadLatestSnapshots(
            for: selectedThreads,
            session: session
        )

        try session.finish()
        return sortedSnapshots(snapshots)
    }

    private func loadSnapshotsSynchronously(
        matchingActiveTasks tasks: [CodexTask]
    ) throws -> [CodexThreadSnapshot] {
        guard !tasks.isEmpty else {
            return []
        }
        guard sessionTimeout.isFinite,
              sessionTimeout > 0,
              sessionTimeout <= Self.maximumSessionTimeout,
              tasks.count <= Self.maximumWindows,
              Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy(Self.validActiveTask)
        else {
            throw CodexAppServerSnapshotError.invalidInput
        }
        try validateExecutable()

        let session = try CodexAppServerRPCSession(
            executableURL: executableURL,
            timeout: sessionTimeout
        )
        defer { session.abortIfNeeded() }
        try session.initialize()

        var snapshots: [CodexThreadSnapshot] = []
        snapshots.reserveCapacity(tasks.count)
        for task in tasks {
            let threadResult: [String: Any]
            do {
                threadResult = try session.request(
                    method: "thread/read",
                    params: [
                        "threadId": task.sessionID,
                        "includeTurns": false
                    ]
                )
            } catch CodexAppServerSnapshotError.requestRejected(let code)
                where code == -32_600 {
                continue
            }
            let thread = try parseThreadRead(threadResult)
            guard thread.id == task.sessionID,
                  thread.cwd == task.cwd else {
                continue
            }
            let snapshot: CodexThreadSnapshot?
            do {
                snapshot = try loadLatestSnapshot(
                    for: thread,
                    session: session,
                    fallbackStartedAt: min(task.startedAt, thread.updatedAt)
                )
            } catch CodexAppServerSnapshotError.requestRejected(let code)
                where code == -32_600 {
                continue
            }
            guard let snapshot, snapshot.turnID == task.turnID else {
                continue
            }
            snapshots.append(snapshot)
        }

        try session.finish()
        return sortedSnapshots(snapshots)
    }

    private static func validActiveTask(_ task: CodexTask) -> Bool {
        task.id == "\(task.sessionID):\(task.turnID)"
            && !task.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.sessionID.utf8.count <= 512
            && !task.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.turnID.utf8.count <= 512
            && PathNormalizer.normalize(task.cwd) == task.cwd
            && task.startedAt.timeIntervalSince1970.isFinite
            && task.updatedAt.timeIntervalSince1970.isFinite
            && task.startedAt.timeIntervalSince1970 >= 0
            && task.startedAt <= task.updatedAt
            && task.updatedAt <= Date().addingTimeInterval(7 * 24 * 60 * 60)
    }

    private func loadThreads(
        session: CodexAppServerRPCSession,
        sourceKinds: [CodexThreadSource]
    ) throws -> [AppServerThread] {
        var threads: [AppServerThread] = []
        var cursor: String?
        var seenCursors = Set<String>()

        repeat {
            var params: [String: Any] = [
                "sourceKinds": sourceKinds.map(\.rawValue),
                "useStateDbOnly": true,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "limit": Self.threadPageSize
            ]
            if let cursor {
                params["cursor"] = cursor
            }

            let result = try session.request(method: "thread/list", params: params)
            let page = try parseThreadPage(result)
            guard threads.count + page.threads.count <= Self.maximumThreads else {
                throw CodexAppServerSnapshotError.responseLimitExceeded
            }
            guard page.threads.allSatisfy({ sourceKinds.contains($0.source) }) else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            threads.append(contentsOf: page.threads)

            cursor = page.nextCursor
            if let cursor {
                guard threads.count < Self.maximumThreads,
                      seenCursors.insert(cursor).inserted,
                      !page.threads.isEmpty
                else {
                    throw CodexAppServerSnapshotError.responseLimitExceeded
                }
            }
        } while cursor != nil

        return threads
    }

    private func loadLatestSnapshots(
        for threads: [AppServerThread],
        session: CodexAppServerRPCSession
    ) throws -> [CodexThreadSnapshot] {
        var snapshots: [CodexThreadSnapshot] = []
        snapshots.reserveCapacity(threads.count)
        for thread in threads {
            guard let snapshot = try loadLatestSnapshot(for: thread, session: session) else {
                continue
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private func loadLatestSnapshot(
        for thread: AppServerThread,
        session: CodexAppServerRPCSession,
        fallbackStartedAt: Date? = nil
    ) throws -> CodexThreadSnapshot? {
        let result = try session.request(
            method: "thread/turns/list",
            params: [
                "threadId": thread.id,
                "limit": 1,
                "sortDirection": "desc",
                "itemsView": "notLoaded"
            ]
        )
        guard let turn = try parseLatestTurn(
            result,
            fallbackStartedAt: fallbackStartedAt
        ),
              turn.startedAt <= thread.updatedAt else {
            return nil
        }
        return CodexThreadSnapshot(
            sessionID: thread.id,
            turnID: turn.id,
            cwd: thread.cwd,
            title: thread.title,
            source: thread.source,
            status: turn.status,
            startedAt: turn.startedAt,
            updatedAt: thread.updatedAt
        )
    }

    private func sortedSnapshots(
        _ snapshots: [CodexThreadSnapshot]
    ) -> [CodexThreadSnapshot] {
        snapshots.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.sessionID > $1.sessionID
        }
    }

    private func validateExecutable() throws {
        guard executableURL.isFileURL,
              (executableURL.path as NSString).isAbsolutePath,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              let values = try? executableURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              executableValidator(executableURL)
        else {
            throw CodexAppServerSnapshotError.executableUnavailable
        }
    }

    private func parseThreadPage(_ result: [String: Any]) throws -> ThreadPage {
        guard let rawThreads = result["data"] as? [Any],
              rawThreads.count <= Self.threadPageSize
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }

        let threads = try rawThreads.map { rawValue -> AppServerThread in
            guard let value = rawValue as? [String: Any] else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            return try parseThread(value)
        }

        let nextCursor: String?
        switch result["nextCursor"] {
        case nil, is NSNull:
            nextCursor = nil
        case let value as String where !value.isEmpty && value.utf8.count <= 4_096:
            nextCursor = value
        default:
            throw CodexAppServerSnapshotError.protocolViolation
        }
        return ThreadPage(threads: threads, nextCursor: nextCursor)
    }

    private func parseThreadRead(_ result: [String: Any]) throws -> AppServerThread {
        guard let rawThread = result["thread"] as? [String: Any],
              let turns = rawThread["turns"] as? [Any],
              turns.isEmpty
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        return try parseThread(rawThread)
    }

    private func parseThread(_ value: [String: Any]) throws -> AppServerThread {
        let id = try validatedIdentifier(value["id"])
        _ = try validatedIdentifier(value["sessionId"])
        if let rawTurns = value["turns"] {
            guard let turns = rawTurns as? [Any], turns.isEmpty else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
        }
        guard let rawSource = value["source"] as? String,
              let source = CodexThreadSource(rawValue: rawSource),
              let rawCWD = value["cwd"] as? String,
              rawCWD.utf8.count <= 4_096,
              let cwd = PathNormalizer.normalize(rawCWD),
              let rawPreview = value["preview"] as? String,
              rawPreview.utf8.count <= 64 * 1_024
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }

        let rawName: String?
        switch value["name"] {
        case nil, is NSNull:
            rawName = nil
        case let name as String where name.utf8.count <= 64 * 1_024:
            rawName = name
        default:
            throw CodexAppServerSnapshotError.protocolViolation
        }

        let createdAt = try date(from: value["createdAt"])
        let updatedAt = try date(from: value["updatedAt"])
        guard createdAt <= updatedAt,
              updatedAt <= Date().addingTimeInterval(7 * 24 * 60 * 60)
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        let workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
        let title = PromptSanitizer.sanitize(rawName, maxLength: 80)
            ?? PromptSanitizer.sanitize(rawPreview, maxLength: 80)
            ?? PromptSanitizer.sanitizeDisplayText(workspaceName, maxLength: 80)
            ?? "Codex task"

        return AppServerThread(
            id: id,
            cwd: cwd,
            title: title,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt,
            windowID: nil
        )
    }

    private func parseLatestTurn(
        _ result: [String: Any],
        fallbackStartedAt: Date? = nil
    ) throws -> AppServerTurn? {
        guard let rawTurns = result["data"] as? [Any], rawTurns.count <= 1 else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        guard let rawTurn = rawTurns.first else {
            return nil
        }
        guard let value = rawTurn as? [String: Any] else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        let id = try validatedIdentifier(value["id"])
        guard let rawStatus = value["status"] as? String,
              let status = CodexThreadTurnStatus(rawValue: rawStatus),
              let rawItems = value["items"] as? [Any],
              rawItems.isEmpty
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        if let itemsView = value["itemsView"], !(itemsView is NSNull),
           itemsView as? String != "notLoaded" {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        let startedAt: Date
        if let rawStartedAt = value["startedAt"], !(rawStartedAt is NSNull) {
            startedAt = try date(from: rawStartedAt)
        } else if let fallbackStartedAt,
                  fallbackStartedAt.timeIntervalSince1970.isFinite,
                  fallbackStartedAt.timeIntervalSince1970 >= 0 {
            startedAt = fallbackStartedAt
        } else {
            return nil
        }
        if let completedAt = value["completedAt"], !(completedAt is NSNull) {
            _ = try date(from: completedAt)
        }
        return AppServerTurn(id: id, status: status, startedAt: startedAt)
    }

    private func validatedIdentifier(_ value: Any?) throws -> String {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 512
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        return value
    }

    private func date(from value: Any?) throws -> Date {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        let seconds = number.doubleValue
        guard seconds.isFinite,
              seconds.rounded(.towardZero) == seconds,
              seconds >= 0,
              seconds <= 253_402_300_799
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private enum OfficialCodexExecutableValidator {
    private static let openAITeamIdentifier = "2DC432GLL2"

    static func validate(_ executableURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            return false
        }

        let requirementText = "identifier \"codex\" and anchor apple generic "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"\(openAITeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement
        else {
            return false
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement
        ) == errSecSuccess
    }
}

private enum CodexAppServerSnapshotError: Error {
    case executableUnavailable
    case invalidInput
    case processFailure
    case protocolViolation
    case requestRejected(Int)
    case responseLimitExceeded
    case timedOut
}

private struct ThreadPage {
    let threads: [AppServerThread]
    let nextCursor: String?
}

private struct AppServerThread {
    let id: String
    let cwd: String
    let title: String
    let source: CodexThreadSource
    let createdAt: Date
    let updatedAt: Date
    let windowID: Int?

    func withWindowID(_ windowID: Int) -> AppServerThread {
        AppServerThread(
            id: id,
            cwd: cwd,
            title: title,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt,
            windowID: windowID
        )
    }

    func isNewer(than other: AppServerThread) -> Bool {
        if updatedAt != other.updatedAt {
            return updatedAt > other.updatedAt
        }
        if createdAt != other.createdAt {
            return createdAt > other.createdAt
        }
        return id > other.id
    }
}

private struct AppServerTurn {
    let id: String
    let status: CodexThreadTurnStatus
    let startedAt: Date
}

private final class CodexAppServerRPCSession {
    private static let maximumResponseBytes = 16 * 1_024 * 1_024
    private static let maximumLineBytes = 4 * 1_024 * 1_024
    private static let maximumMessages = 2_048

    private let process: Process
    private let input: FileHandle
    private let reader: BoundedJSONLineReader
    private let deadline: AppServerDeadline
    private var nextRequestID = 0
    private var issuedRequestIDs = Set<Int>()
    private var receivedRequestIDs = Set<Int>()
    private var pendingResponses: [Int: RPCResponsePayload] = [:]
    private var messageCount = 0
    private var isFinished = false

    init(executableURL: URL, timeout: TimeInterval) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let deadline = AppServerDeadline(timeout: timeout)
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.deadline = deadline
        self.reader = BoundedJSONLineReader(
            handle: outputPipe.fileHandleForReading,
            maximumLineBytes: Self.maximumLineBytes,
            maximumTotalBytes: Self.maximumResponseBytes,
            deadline: deadline
        )
        do {
            try process.run()
        } catch {
            throw CodexAppServerSnapshotError.processFailure
        }
    }

    func initialize() throws {
        let requestID = try sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codexbar",
                    "title": "CodexBar",
                    "version": "1"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        )
        _ = try result(for: requestID)
        try writeJSONObject(["method": "initialized"])
    }

    @discardableResult
    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let requestID = try sendRequest(method: method, params: params)
        return try result(for: requestID)
    }

    func sendRequest(method: String, params: [String: Any]) throws -> Int {
        guard !isFinished else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        nextRequestID += 1
        let requestID = nextRequestID
        issuedRequestIDs.insert(requestID)
        try writeJSONObject([
            "id": requestID,
            "method": method,
            "params": params
        ])
        return requestID
    }

    func result(for requestID: Int) throws -> [String: Any] {
        guard issuedRequestIDs.contains(requestID),
              !receivedRequestIDs.contains(requestID)
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        if let payload = pendingResponses.removeValue(forKey: requestID) {
            receivedRequestIDs.insert(requestID)
            return try result(from: payload)
        }

        while let response = try readResponse() {
            guard issuedRequestIDs.contains(response.id),
                  !receivedRequestIDs.contains(response.id),
                  pendingResponses[response.id] == nil
            else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            if response.id == requestID {
                receivedRequestIDs.insert(requestID)
                return try result(from: response.payload)
            }
            pendingResponses[response.id] = response.payload
        }
        throw CodexAppServerSnapshotError.processFailure
    }

    func finish() throws {
        guard !isFinished,
              receivedRequestIDs == issuedRequestIDs,
              pendingResponses.isEmpty
        else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        try input.close()
        while let response = try readResponse() {
            _ = response
            throw CodexAppServerSnapshotError.protocolViolation
        }
        try waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CodexAppServerSnapshotError.processFailure
        }
        isFinished = true
    }

    func abortIfNeeded() {
        guard !isFinished else {
            return
        }
        isFinished = true
        try? input.close()
        reader.close()
        if process.isRunning {
            process.terminate()
        }
        guard waitUntilExit(for: 0.25) else {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            _ = waitUntilExit(for: 0.25)
            return
        }
        process.waitUntilExit()
    }

    private func writeJSONObject(_ value: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CodexAppServerSnapshotError.protocolViolation
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            throw CodexAppServerSnapshotError.processFailure
        }
    }

    private func result(from payload: RPCResponsePayload) throws -> [String: Any] {
        switch payload {
        case let .result(result):
            return result
        case let .rejected(code):
            throw CodexAppServerSnapshotError.requestRejected(code)
        }
    }

    private func readResponse() throws -> RPCResponse? {
        while let line = try reader.nextLine() {
            messageCount += 1
            guard messageCount <= Self.maximumMessages,
                  !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: line),
                  let object = value as? [String: Any]
            else {
                throw CodexAppServerSnapshotError.protocolViolation
            }

            if object["id"] == nil {
                guard let method = object["method"] as? String,
                      !method.isEmpty,
                      method.utf8.count <= 512
                else {
                    throw CodexAppServerSnapshotError.protocolViolation
                }
                continue
            }
            guard let idNumber = object["id"] as? NSNumber,
                  CFGetTypeID(idNumber) != CFBooleanGetTypeID(),
                  idNumber.doubleValue.rounded(.towardZero) == idNumber.doubleValue,
                  idNumber.doubleValue >= 1,
                  idNumber.doubleValue <= Double(Int.max)
            else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            let payload: RPCResponsePayload
            if let result = object["result"] as? [String: Any],
               object["error"] == nil || object["error"] is NSNull {
                payload = .result(result)
            } else if let error = object["error"] as? [String: Any],
                      object["result"] == nil || object["result"] is NSNull,
                      let code = error["code"] as? NSNumber,
                      CFGetTypeID(code) != CFBooleanGetTypeID(),
                      code.doubleValue.isFinite,
                      code.doubleValue.rounded(.towardZero) == code.doubleValue,
                      code.doubleValue >= Double(Int32.min),
                      code.doubleValue <= Double(Int32.max),
                      let message = error["message"] as? String,
                      message.utf8.count <= 64 * 1_024 {
                payload = .rejected(code.intValue)
            } else {
                throw CodexAppServerSnapshotError.protocolViolation
            }
            return RPCResponse(id: idNumber.intValue, payload: payload)
        }
        return nil
    }

    private func waitUntilExit() throws {
        while process.isRunning {
            guard !deadline.isExpired else {
                throw CodexAppServerSnapshotError.timedOut
            }
            usleep(10_000)
        }
        process.waitUntilExit()
    }

    private func waitUntilExit(for timeout: TimeInterval) -> Bool {
        let end = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < end {
            usleep(10_000)
        }
        return !process.isRunning
    }
}

private struct RPCResponse {
    let id: Int
    let payload: RPCResponsePayload
}

private enum RPCResponsePayload {
    case result([String: Any])
    case rejected(Int)
}

private struct AppServerDeadline {
    private let endUptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        endUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
    }

    var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= endUptimeNanoseconds
    }

    func pollTimeoutMilliseconds(maximum: Int32? = nil) throws -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < endUptimeNanoseconds else {
            throw CodexAppServerSnapshotError.timedOut
        }
        let remainingNanoseconds = endUptimeNanoseconds - now
        let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        let bounded = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
        if let maximum {
            return min(bounded, maximum)
        }
        return bounded
    }
}

private final class BoundedJSONLineReader {
    private let handle: FileHandle
    private let maximumLineBytes: Int
    private let maximumTotalBytes: Int
    private let deadline: AppServerDeadline
    private var buffer = Data()
    private var totalBytes = 0
    private var reachedEOF = false

    init(
        handle: FileHandle,
        maximumLineBytes: Int,
        maximumTotalBytes: Int,
        deadline: AppServerDeadline
    ) {
        self.handle = handle
        self.maximumLineBytes = maximumLineBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.deadline = deadline
    }

    func nextLine() throws -> Data? {
        while true {
            if currentTaskIsCancelled() {
                throw CancellationError()
            }
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                guard line.count <= maximumLineBytes else {
                    throw CodexAppServerSnapshotError.responseLimitExceeded
                }
                return line
            }
            guard buffer.count <= maximumLineBytes else {
                throw CodexAppServerSnapshotError.responseLimitExceeded
            }
            if reachedEOF {
                guard !buffer.isEmpty else {
                    return nil
                }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return line
            }

            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            var pollResult: Int32
            repeat {
                pollResult = Darwin.poll(
                    &descriptor,
                    1,
                    try deadline.pollTimeoutMilliseconds(maximum: 100)
                )
            } while pollResult < 0 && errno == EINTR
            if pollResult == 0 {
                if deadline.isExpired {
                    throw CodexAppServerSnapshotError.timedOut
                }
                continue
            }
            guard pollResult > 0 else {
                throw CodexAppServerSnapshotError.processFailure
            }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                throw CodexAppServerSnapshotError.processFailure
            }

            // Unlike read(upToCount:), availableData returns as soon as any
            // bytes are ready, which is required for an interactive stdio RPC.
            let chunk = handle.availableData
            if chunk.isEmpty {
                reachedEOF = true
                continue
            }
            totalBytes += chunk.count
            guard totalBytes <= maximumTotalBytes else {
                throw CodexAppServerSnapshotError.responseLimitExceeded
            }
            buffer.append(chunk)
        }
    }

    func close() {
        try? handle.close()
    }

    private func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
    }
}
