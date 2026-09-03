import Foundation

public enum CodexTaskTimeFormatter {
    public static func text(for task: CodexTask, relativeTo now: Date) -> String {
        let referenceDate = task.status == .running ? task.startedAt : task.updatedAt
        let seconds = elapsedSeconds(from: referenceDate, to: now)

        switch task.status {
        case .running:
            return durationText(seconds: seconds)
        case .needsAttention, .ready:
            return ageText(seconds: seconds)
        }
    }

    public static func accessibilityText(for task: CodexTask, relativeTo now: Date) -> String {
        let referenceDate = task.status == .running ? task.startedAt : task.updatedAt
        let seconds = elapsedSeconds(from: referenceDate, to: now)

        switch task.status {
        case .running:
            return seconds < 60
                ? "已执行不到1分钟"
                : "已执行约\(coarseDurationText(seconds: seconds))"
        case .needsAttention:
            return seconds < 60
                ? "刚刚需要处理"
                : "\(coarseAgeText(seconds: seconds))需要处理"
        case .ready:
            return seconds < 60
                ? "刚刚变为可查看"
                : "\(coarseAgeText(seconds: seconds))变为可查看"
        }
    }

    private static func elapsedSeconds(from start: Date, to end: Date) -> Int {
        let interval = end.timeIntervalSince(start)
        guard interval.isFinite, interval > 0 else {
            return 0
        }
        return Int(min(interval.rounded(.down), Double(Int.max / 2)))
    }

    private static func durationText(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)秒"
        }
        if seconds < 3_600 {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return remainingSeconds == 0
                ? "\(minutes)分"
                : "\(minutes)分\(remainingSeconds)秒"
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            let remainingMinutes = (seconds % 3_600) / 60
            return remainingMinutes == 0
                ? "\(hours)小时"
                : "\(hours)小时\(remainingMinutes)分"
        }

        let days = seconds / 86_400
        let remainingHours = (seconds % 86_400) / 3_600
        return remainingHours == 0
            ? "\(days)天"
            : "\(days)天\(remainingHours)小时"
    }

    private static func ageText(seconds: Int) -> String {
        if seconds < 5 {
            return "刚刚"
        }
        if seconds < 60 {
            return "\(seconds)秒前"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)分钟前"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)小时前"
        }
        return "\(seconds / 86_400)天前"
    }

    private static func coarseDurationText(seconds: Int) -> String {
        if seconds < 60 {
            return "不到1分钟"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)分钟"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)小时"
        }
        return "\(seconds / 86_400)天"
    }

    private static func coarseAgeText(seconds: Int) -> String {
        if seconds < 3_600 {
            return "\(seconds / 60)分钟前"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)小时前"
        }
        return "\(seconds / 86_400)天前"
    }
}
