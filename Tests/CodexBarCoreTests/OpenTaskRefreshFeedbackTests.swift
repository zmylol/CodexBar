import CodexBarCore

@MainActor
func openTaskRefreshFeedbackTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "manual refresh describes every terminal outcome") {
            try expect(
                CodexTaskRefreshFeedback.message(
                    for: .completed(currentWorkspaceCount: 5, changedCount: 0),
                    reportCompletion: true
                ) == "刷新完成，没有变化。当前列表共 5 个工作区。",
                "an unchanged manual refresh has no useful feedback"
            )
            try expect(
                CodexTaskRefreshFeedback.message(
                    for: .completed(currentWorkspaceCount: 6, changedCount: 2),
                    reportCompletion: true
                ) == "刷新完成，更新 2 个任务。当前列表共 6 个工作区。",
                "a changed manual refresh does not summarize its result"
            )
            try expect(
                CodexTaskRefreshFeedback.message(
                    for: .noOpenWindows,
                    reportCompletion: true
                ) == "刷新完成，未发现已打开的 VS Code 窗口。",
                "a manual refresh with no windows has no feedback"
            )
            try expect(
                CodexTaskRefreshFeedback.message(
                    for: .failed,
                    reportCompletion: true
                ) == "刷新失败，无法读取已打开的 VS Code Codex 任务。",
                "a failed manual refresh has no feedback"
            )
            try expect(
                CodexTaskRefreshFeedback.message(
                    for: .persistenceFailed,
                    reportCompletion: true
                ) == "刷新失败，检测到任务变化，但无法保存结果。",
                "a persistence failure has no manual refresh feedback"
            )
        },
        CodexBarTestCase(name: "automatic recovery never shows manual refresh feedback") {
            let outcomes: [CodexTaskRefreshOutcome] = [
                .completed(currentWorkspaceCount: 5, changedCount: 0),
                .completed(currentWorkspaceCount: 6, changedCount: 2),
                .noOpenWindows,
                .failed,
                .persistenceFailed
            ]

            for outcome in outcomes {
                try expect(
                    CodexTaskRefreshFeedback.message(
                        for: outcome,
                        reportCompletion: false
                    ) == nil,
                    "automatic startup recovery produced a manual refresh notice"
                )
            }
        }
    ]
}
