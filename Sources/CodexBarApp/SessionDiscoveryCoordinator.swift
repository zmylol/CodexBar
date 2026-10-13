import Foundation

/// Coalesces session creation signals into bounded metadata recovery attempts.
@MainActor
final class SessionDiscoveryCoordinator {
    private let recover: @MainActor () async -> Void
    private let delays: [Duration]
    private var generation: UUID?
    private var pending = false
    private var task: Task<Void, Never>?

    init(delays: [Duration] = [.milliseconds(250), .seconds(1)],
         recover: @escaping @MainActor () async -> Void) {
        self.recover = recover
        self.delays = Array(delays.prefix(2))
    }

    func start() {
        stop()
        generation = UUID()
    }

    func stop() {
        generation = nil
        pending = false
        task?.cancel()
        task = nil
    }

    func request() {
        guard let generation else { return }
        pending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { task = nil } }
            repeat {
                for delay in delays {
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard self.generation == generation, !Task.isCancelled else { return }
                    pending = false
                    await recover()
                    guard self.generation == generation, !Task.isCancelled else { return }
                }
            } while pending && !delays.isEmpty
        }
    }
}
