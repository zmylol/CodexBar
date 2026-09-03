import CodexBarCore
import Foundation

@MainActor
func taskRecoveryThrottleTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "polls App Server only while a task can be stuck active") {
            var throttle = TaskRecoveryThrottle(interval: 5)

            try expect(
                !throttle.shouldStart(
                    hasActiveTasks: false,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 100)
                ),
                "recovery started without an active task"
            )
            try expect(
                throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 100)
                ),
                "active task did not trigger recovery"
            )
            try expect(
                !throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 104.999)
                ),
                "recovery ignored its polling interval"
            )
            try expect(
                throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 105)
                ),
                "recovery did not resume after its polling interval"
            )
            throttle.didFinish(at: Date(timeIntervalSince1970: 110))
            try expect(
                !throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 114.999)
                ),
                "a slow recovery was followed by an immediate new query"
            )
            try expect(
                throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 115)
                ),
                "completion-based throttling never became eligible"
            )
        },
        CodexBarTestCase(name: "recovery throttle is single-flight and supports startup discovery") {
            var throttle = TaskRecoveryThrottle(interval: 5)

            try expect(
                !throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: true,
                    now: Date(timeIntervalSince1970: 100)
                ),
                "recovery started while another query was in flight"
            )
            try expect(
                throttle.shouldStart(
                    hasActiveTasks: false,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 100),
                    force: true
                ),
                "startup discovery required an existing active task"
            )
            throttle.reset()
            try expect(
                throttle.shouldStart(
                    hasActiveTasks: true,
                    isRecoveryInFlight: false,
                    now: Date(timeIntervalSince1970: 100)
                ),
                "reset did not clear the recovery interval"
            )
        }
    ]
}
