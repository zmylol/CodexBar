import Foundation

public struct TaskRecoveryThrottle: Sendable {
    private let interval: TimeInterval
    private var nextEligibleAt: Date?

    public init(interval: TimeInterval) {
        self.interval = max(0, interval)
    }

    public mutating func shouldStart(
        hasActiveTasks: Bool,
        isRecoveryInFlight: Bool,
        now: Date,
        force: Bool = false
    ) -> Bool {
        guard !isRecoveryInFlight,
              force || hasActiveTasks
        else {
            return false
        }
        if !force, let nextEligibleAt, now < nextEligibleAt {
            return false
        }
        nextEligibleAt = now.addingTimeInterval(interval)
        return true
    }

    public mutating func didFinish(at now: Date) {
        let completionEligibility = now.addingTimeInterval(interval)
        nextEligibleAt = max(nextEligibleAt ?? completionEligibility, completionEligibility)
    }

    public mutating func reset() {
        nextEligibleAt = nil
    }
}
