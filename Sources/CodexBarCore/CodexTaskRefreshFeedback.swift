public enum CodexTaskRefreshOutcome: Equatable, Sendable {
    case completed(currentWorkspaceCount: Int, changedCount: Int)
    case noOpenWindows
    case failed
    case persistenceFailed
}

public enum CodexTaskRefreshFeedback {
    public static func message(
        for outcome: CodexTaskRefreshOutcome,
        reportCompletion: Bool
    ) -> String? {
        guard reportCompletion else {
            return nil
        }

        switch outcome {
        case let .completed(currentWorkspaceCount, changedCount):
            if changedCount == 0 {
                return "刷新完成，没有变化。当前列表共 \(currentWorkspaceCount) 个工作区。"
            }
            return "刷新完成，更新 \(changedCount) 个任务。当前列表共 \(currentWorkspaceCount) 个工作区。"
        case .noOpenWindows:
            return "刷新完成，未发现已打开的 VS Code 窗口。"
        case .failed:
            return "刷新失败，无法读取已打开的 VS Code Codex 任务。"
        case .persistenceFailed:
            return "刷新失败，检测到任务变化，但无法保存结果。"
        }
    }
}
