import Foundation
import CodexBarCore

@MainActor
func taskTimeFormatterTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "formats running time from task start") {
            let task = timeTask(
                status: .running,
                startedAt: 100,
                updatedAt: 115
            )

            try expect(
                CodexTaskTimeFormatter.text(
                    for: task,
                    relativeTo: Date(timeIntervalSince1970: 165)
                ) == "1分5秒",
                "running time did not use startedAt"
            )
        },
        CodexBarTestCase(name: "formats stopped and attention times as age") {
            let ready = timeTask(status: .ready, startedAt: 100, updatedAt: 160)
            let attention = timeTask(status: .needsAttention, startedAt: 100, updatedAt: 100)
            let now = Date(timeIntervalSince1970: 165)

            try expect(
                CodexTaskTimeFormatter.text(for: ready, relativeTo: now) == "5秒前",
                "ready time did not describe when Stop occurred"
            )
            try expect(
                CodexTaskTimeFormatter.text(for: attention, relativeTo: now) == "1分钟前",
                "attention time did not describe when permission was requested"
            )
        },
        CodexBarTestCase(name: "formats age boundaries and future timestamps") {
            let now = Date(timeIntervalSince1970: 10_000)

            try expect(
                CodexTaskTimeFormatter.text(
                    for: timeTask(status: .ready, startedAt: 9_999, updatedAt: 9_999),
                    relativeTo: now
                ) == "刚刚",
                "recent ready task was not shown as just now"
            )
            try expect(
                CodexTaskTimeFormatter.text(
                    for: timeTask(status: .ready, startedAt: 9_940, updatedAt: 9_940),
                    relativeTo: now
                ) == "1分钟前",
                "minute boundary is wrong"
            )
            try expect(
                CodexTaskTimeFormatter.text(
                    for: timeTask(status: .ready, startedAt: 6_400, updatedAt: 6_400),
                    relativeTo: now
                ) == "1小时前",
                "hour boundary is wrong"
            )
            try expect(
                CodexTaskTimeFormatter.text(
                    for: timeTask(status: .running, startedAt: 10_010, updatedAt: 10_010),
                    relativeTo: now
                ) == "0秒",
                "future running time was not clamped"
            )
            try expect(
                CodexTaskTimeFormatter.text(
                    for: timeTask(status: .ready, startedAt: 10_010, updatedAt: 10_010),
                    relativeTo: now
                ) == "刚刚",
                "future ready time was not clamped"
            )
        },
        CodexBarTestCase(name: "formats stable semantic accessibility time") {
            let now = Date(timeIntervalSince1970: 165)

            try expect(
                CodexTaskTimeFormatter.accessibilityText(
                    for: timeTask(status: .running, startedAt: 150, updatedAt: 150),
                    relativeTo: now
                ) == "已执行不到1分钟",
                "short running accessibility time is unnatural"
            )
            try expect(
                CodexTaskTimeFormatter.accessibilityText(
                    for: timeTask(status: .running, startedAt: 100, updatedAt: 115),
                    relativeTo: now
                ) == "已执行约1分钟",
                "running accessibility time was not minute based"
            )
            try expect(
                CodexTaskTimeFormatter.accessibilityText(
                    for: timeTask(status: .ready, startedAt: 100, updatedAt: 160),
                    relativeTo: now
                ) == "刚刚变为可查看",
                "ready accessibility time is ambiguous"
            )
            try expect(
                CodexTaskTimeFormatter.accessibilityText(
                    for: timeTask(status: .needsAttention, startedAt: 100, updatedAt: 100),
                    relativeTo: now
                ) == "1分钟前需要处理",
                "attention accessibility time is ambiguous"
            )
        }
    ]
}

private func timeTask(
    status: CodexTaskStatus,
    startedAt: TimeInterval,
    updatedAt: TimeInterval
) -> CodexTask {
    CodexTask(
        id: "session:turn",
        sessionID: "session",
        turnID: "turn",
        cwd: "/tmp/project",
        workspaceName: "project",
        title: "Test task",
        status: status,
        startedAt: Date(timeIntervalSince1970: startedAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt),
        isUnread: status != .running
    )
}
