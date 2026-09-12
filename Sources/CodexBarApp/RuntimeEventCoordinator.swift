import CodexBarCore
import Foundation

enum RuntimeStatusEvent {
    case frame(Data, UUID?)
    case unavailable([String: CodexRuntimeUnavailableReason])
    case reconcile
}

/// Orders live projections and Hook reconciliation independently of window and UI lifetimes.
@MainActor
final class RuntimeEventCoordinator {
    var onUpdates: (([CodexRuntimeStatusUpdate]) async -> Void)?
    var onFrame: ((Data, String?, UUID?) async -> Void)?
    var onUnavailable: (([String: CodexRuntimeUnavailableReason]) async -> Void)?
    var onSnapshotNeeded: ((String) -> Void)?
    var onOverflow: (() -> Void)?

    private let maximumPendingBytes: Int
    private let maximumPendingEvents: Int
    private var events: [RuntimeStatusEvent] = []
    private var pendingBytes = 0
    private var states: [String: CodexRuntimeStatusUpdate] = [:]
    private var projection = RuntimeStatusProjectionWorker()
    private var processingTask: Task<Void, Never>?
    private var processingID: UUID?
    private var isStarted = false

    init(maximumPendingBytes: Int = 64 * 1_024 * 1_024, maximumPendingEvents: Int = 128) {
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingEvents = maximumPendingEvents
    }

    func start() { stop(); isStarted = true }

    func stop() {
        isStarted = false
        reset()
    }

    func enqueue(_ event: RuntimeStatusEvent) {
        guard isStarted else { return }
        if case .reconcile = event,
           events.contains(where: { if case .reconcile = $0 { return true }; return false }) { return }
        let bytes: Int
        if case .frame(let data, _) = event { bytes = data.count } else { bytes = 0 }
        guard bytes <= maximumPendingBytes - pendingBytes, events.count < maximumPendingEvents else {
            reset()
            onOverflow?()
            return
        }
        events.append(event)
        pendingBytes += bytes
        guard processingTask == nil else { return }
        let id = UUID()
        processingID = id
        let worker = projection
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if processingID == id { processingID = nil; processingTask = nil }
            }
            while !events.isEmpty {
                let event = events.removeFirst()
                switch event {
                case .frame(let data, let previewGeneration):
                    pendingBytes -= data.count
                    let result = await worker.consume(data)
                    guard isCurrent(id) else { return }
                    if let session = result.invalidatedSessionID { states.removeValue(forKey: session) }
                    if let session = result.resnapshotSessionID {
                        states.removeValue(forKey: session)
                        onSnapshotNeeded?(session)
                    }
                    if let update = result.update {
                        states[update.sessionID] = update
                        // Publish task status before waiting for content and filesystem work.
                        await onUpdates?([update])
                        guard isCurrent(id) else { return }
                    }
                    await onFrame?(data, result.sessionID, previewGeneration)
                case .unavailable(let reasons):
                    for session in reasons.keys { states.removeValue(forKey: session) }
                    await worker.reset(sessions: Set(reasons.keys))
                    guard isCurrent(id) else { return }
                    await onUnavailable?(reasons)
                case .reconcile:
                    if !states.isEmpty { await onUpdates?(Array(states.values)) }
                }
                guard isCurrent(id) else { return }
            }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        isStarted && !Task.isCancelled && processingID == id
    }

    private func reset() {
        processingTask?.cancel()
        processingTask = nil
        processingID = nil
        events.removeAll()
        pendingBytes = 0
        states.removeAll()
        projection = RuntimeStatusProjectionWorker()
    }
}

private actor RuntimeStatusProjectionWorker {
    private var reducer = CodexRuntimeStatusReducer()
    func consume(_ data: Data) -> CodexRuntimeStatusResult { reducer.consume(data) }
    func reset(sessions: Set<String>) {
        for session in sessions { reducer.reset(sessionID: session) }
    }
}
