import CodexBarCore
import Foundation

@MainActor
func taskDetailSummaryTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "detail prioritizes attention over a running plan") {
            let summary = detailSummary(status: .needsAttention, steps: [
                ("检查实现", .completed), ("修复状态", .inProgress), ("验证", .pending)
            ], activity: "读取 TaskStore.swift")

            try expect(summary.focusText == "需要你处理当前请求。", "attention was hidden by the plan")
            try expect(summary.contextLabel == "已做", "completed context has the wrong label")
            try expect(summary.contextText == "检查实现", "attention lost explicitly completed progress")
            try expect(summary.focusDetail?.contains("当前计划是「修复状态」") == true, "attention lost the relevant plan context")
            try expect(summary.nextStep == "验证", "attention erased the deferred plan")
            try expect(summary.actionTitle == "去处理", "attention did not offer a relevant action")
            try expect(!summary.accessibilitySummary.contains("审批"), "attention invented an approval reason")
        },
        CodexBarTestCase(name: "detail shows current phase and the following pending step") {
            let summary = detailSummary(status: .running, steps: [
                ("之前未执行的步骤", .pending), ("修复状态", .inProgress), ("验证", .pending)
            ], activity: "修改 TaskStore.swift")

            try expect(summary.focusLabel == "当前", "current phase has the wrong label")
            try expect(summary.focusText == "正在进行「修复状态」。", "current phase was not narrated")
            try expect(summary.nextStep == "验证", "next step came from before the current phase")
            try expect(summary.recentActivities.map(\.summary) == ["修改 TaskStore.swift"], "recent action was lost")
            try expect(summary.recentActivities.first?.kind == .command, "observed action icon was lost")
            try expect(summary.focusDetail == nil, "observed action was repeated in the focus description")
        },
        CodexBarTestCase(name: "detail progress counts completed steps rather than current ordinal") {
            let summary = detailSummary(status: .running, steps: [
                ("待处理", .pending), ("已处理", .completed), ("当前", .inProgress), ("后续", .pending)
            ])

            try expect(summary.progressText == "已完成 1/4 步", "progress used current step number")
            try expect(summary.progressFraction == 0.25, "progress fraction did not count completions")
        },
        CodexBarTestCase(name: "detail does not call a completed plan a completed task") {
            let summary = detailSummary(status: .running, steps: [("检查", .completed)])

            try expect(summary.focusText == "计划步骤已完成，本轮仍在运行。", "completed plan lost its scoped meaning")
            try expect(!summary.accessibilitySummary.contains("任务已完成"), "plan completion became task success")
            try expect(summary.nextStep == nil, "completed plan invented a next step")
            try expect(summary.progressFraction == 1, "completed plan had incorrect progress")
        },
        CodexBarTestCase(name: "detail leaves pending steps as future plans without claiming execution") {
            for steps: [(String, CodexTaskPlanStepStatus)] in [
                [("验证", .pending)], [("检查", .completed), ("验证", .pending)]
            ] {
                let summary = detailSummary(status: .running, steps: steps)
                try expect(summary.focusText == "本轮正在运行，尚未记录当前阶段。", "pending step was presented as active")
                try expect(summary.focusLabel == "当前", "pending plan has the wrong label")
                try expect(summary.nextStep == "验证", "pending plan was omitted")
                try expect(!summary.accessibilitySummary.contains("尚未开始"), "partial progress was misrepresented")
            }
        },
        CodexBarTestCase(name: "detail uses an unconfirmed tool event only as a recent action") {
            let summary = detailSummary(status: .running, activity: "运行测试")

            try expect(summary.focusLabel == "当前", "current status has the wrong label")
            try expect(summary.focusText == "本轮正在运行。", "tool event was presented as ongoing execution")
            try expect(summary.recentActivities.map(\.summary) == ["运行测试"], "observed tool event was lost")
            try expect(summary.focusDetail == nil, "observed tool event became a current phase description")
            try expect(summary.accessibilitySummary.contains("最近动态：运行测试"), "tool event was not framed as an observation")
            try expect(summary.progressText == nil && summary.progressFraction == nil, "missing plan invented progress")
            try expect(!summary.accessibilitySummary.contains("通过"), "a tool start became a successful result")
            try expect(!summary.accessibilitySummary.contains("正在运行测试"), "a tool start became current execution")
            try expect(summary.contextText == nil, "a tool start became completed progress")
        },
        CodexBarTestCase(name: "detail handles absent and empty plans without invented phases") {
            for steps: [(String, CodexTaskPlanStepStatus)]? in [nil, []] {
                let summary = detailSummary(status: .running, steps: steps)
                try expect(summary.focusText == "本轮正在运行，尚未记录当前阶段。", "missing activity invented a phase")
                try expect(summary.contextText == nil && summary.nextStep == nil, "missing data invented context")
                try expect(summary.progressText == nil && summary.progressFraction == nil, "empty plan invented progress")
            }
        },
        CodexBarTestCase(name: "detail removes recent actions that duplicate visible plan content") {
            let steps: [(String, CodexTaskPlanStepStatus)] = [
                ("定位原因", .completed), ("修复状态", .inProgress), ("验证", .pending)
            ]
            for (status, activity): (CodexTaskStatus, String) in [
                (.running, "修复状态"), (.needsAttention, "修复状态"),
                (.running, " 验证 "), (.needsAttention, "定位原因"), (.ready, "定位原因")
            ] {
                let summary = detailSummary(status: status, steps: steps, activity: activity)
                try expect(summary.recentActivities.isEmpty, "recent action duplicated focused content")
            }
        },
        CodexBarTestCase(name: "detail does not repeat its focused phase as a future step") {
            let summary = detailSummary(status: .running, steps: [
                ("验证", .inProgress), (" 验证 ", .pending)
            ])
            try expect(summary.nextStep == nil, "future step repeated the focused phase")
        },
        CodexBarTestCase(name: "attention without a plan retains observed activity without inventing a reason") {
            let summary = detailSummary(status: .needsAttention, activity: "执行命令")
            try expect(summary.focusText == "需要你处理当前请求。", "activity displaced required attention")
            try expect(summary.contextText == nil, "missing plan invented a phase")
            try expect(summary.recentActivities.map(\.summary) == ["执行命令"], "attention lost its last observed activity")
            try expect(summary.focusDetail?.contains("返回会话") == true, "attention omitted its handling entry")
            try expect(summary.nextStep == nil, "attention promised future work")
        },
        CodexBarTestCase(name: "stopped detail retains last known progress without task success or future steps") {
            let summary = detailSummary(status: .ready, steps: [
                ("检查", .completed), ("修复状态", .inProgress), ("验证", .pending)
            ], activity: "修改 TaskStore.swift")

            try expect(summary.focusText == "本轮已停止，可以查看会话。", "stopped task was presented as successful")
            try expect(summary.contextLabel == "已做" && summary.contextText == "检查", "explicitly completed progress was lost")
            try expect(summary.focusDetail?.contains("停止前记录的计划阶段是「修复状态」。") == true, "last phase was lost")
            try expect(summary.nextStep == nil, "stopped task promised future work")
            try expect(summary.actionTitle == "查看会话", "stopped task action implied ongoing work")
            try expect(summary.progressText == "已完成 1/3 步", "stopped task fabricated plan completion")
        },
        CodexBarTestCase(name: "stopped detail uses only observed context and avoids repeated actions") {
            let completed = detailSummary(status: .ready, steps: [
                ("检查", .completed), ("验证", .pending)
            ])
            try expect(completed.contextText == "检查", "pending work was treated as last progress")
            let recent = detailSummary(status: .ready, steps: [("验证", .pending)], activity: "读取文件")
            try expect(recent.contextText == nil, "observed activity became completed progress")
            try expect(recent.recentActivities.map(\.summary) == ["读取文件"], "last action was lost")
            try expect(recent.focusDetail == nil, "last action was repeated")
            let empty = detailSummary(status: .ready)
            try expect(empty.contextText == nil, "missing stopped context was invented")
            try expect(empty.focusText == "本轮已停止，可以查看会话。", "missing data changed stopped status")
        },
        CodexBarTestCase(name: "attention and resumption preserve completed current and future plan context") {
            let steps: [(String, CodexTaskPlanStepStatus)] = [
                ("定位原因", .completed), ("检查实现", .completed),
                ("修复状态", .inProgress), ("验证", .pending)
            ]
            let summaries = [CodexTaskStatus.running, .needsAttention, .running].map {
                detailSummary(status: $0, steps: steps, activity: "读取 TaskStore.swift")
            }
            for summary in summaries {
                try expect(summary.contextLabel == "已做" && summary.contextText == "检查实现", "status change erased completed work")
                try expect(summary.nextStep == "验证", "status change erased the future plan")
                try expect(summary.accessibilitySummary.contains("修复状态"), "status change erased current plan context")
                let narration = summary.accessibilitySummary
                let done = narration.range(of: "已做：")!.lowerBound
                let current = narration.range(of: "当前：")!.lowerBound
                let recent = narration.range(of: "最近动态：")!.lowerBound
                let next = narration.range(of: "后续计划：")!.lowerBound
                try expect(done < current && current < recent && recent < next, "narration did not follow done current recent next order")
            }
            try expect(summaries[0] == summaries[2], "resuming changed the observed plan narrative")
        },
        CodexBarTestCase(name: "detail keeps recent events in chronological order with their full content") {
            let longText = "读取状态同步相关文件，核对会话、轮次和窗口之间的关联信息。\n"
                + String(repeating: "保留完整的动态说明，方便理解当前检查的上下文。", count: 8)
            let events = [
                detailActivity("third", .test, "运行状态恢复测试", 3),
                detailActivity("first", .read, longText, 1),
                detailActivity("second", .edit, "修改窗口状态处理", 2)
            ]
            let summary = detailSummary(status: .running, activities: events)

            try expect(summary.recentActivities.map(\.id) == ["first", "second", "third"], "recent events were not chronological")
            try expect(summary.recentActivities.map(\.kind) == [.read, .edit, .test], "recent event icons were lost")
            try expect(summary.recentActivities.first?.summary == longText, "long or multiline event content was truncated")
            try expect(summary.accessibilitySummary.contains(longText), "accessibility omitted full event content")
            let narration = summary.accessibilitySummary
            try expect(narration.range(of: longText)!.lowerBound < narration.range(of: "修改窗口状态处理")!.lowerBound, "accessibility reordered recent events")
            try expect(summary.contextText == nil, "observed events were presented as completed work")
        },
        CodexBarTestCase(name: "appending an event retains earlier visible context and accumulates recent activity") {
            let first = detailActivity("first", .read, "读取状态同步实现", 1)
            let second = detailActivity("second", .edit, "修改窗口通知处理", 2)
            let third = detailActivity("third", .test, "运行回归测试", 3)
            let steps: [(String, CodexTaskPlanStepStatus)] = [
                ("定位原因", .completed), ("修复状态", .inProgress), ("验证", .pending)
            ]
            let before = detailSummary(status: .running, steps: steps, activities: [first, second])
            let after = detailSummary(status: .running, steps: steps, activities: [first, second, third])

            try expect(after.recentActivities == before.recentActivities + [third], "new event replaced existing recent context")
            try expect(after.focusText == before.focusText && after.contextText == before.contextText, "new event displaced plan context")
            try expect(after.nextStep == before.nextStep, "new event erased the next planned step")
            try expect(!after.accessibilitySummary.contains("测试通过"), "test observation was presented as a passing result")
        }
    ]
}

private func detailSummary(
    status: CodexTaskStatus,
    steps: [(String, CodexTaskPlanStepStatus)]? = nil,
    activity: String? = nil,
    activities: [CodexTaskActivity] = []
) -> CodexTaskDetailSummary {
    let date = Date(timeIntervalSince1970: 1_000)
    let task = CodexTask(
        id: "task", sessionID: "session", turnID: "turn", cwd: "/project",
        workspaceName: "project", title: "修复状态同步", status: status,
        startedAt: date, updatedAt: date, isUnread: false
    )
    let plan = steps.map {
        CodexTaskPlan(steps: $0.enumerated().map {
            CodexTaskPlanStep(id: $0.offset, title: $0.element.0, status: $0.element.1)
        }, updatedAt: date)
    }
    let latestActivity = activity.map {
        CodexTaskActivity(id: "activity", kind: .command, summary: $0, occurredAt: date)
    }
    return CodexTaskDetailSummary(task: task, plan: plan, activities: activities + [latestActivity].compactMap { $0 })
}

private func detailActivity(
    _ id: String,
    _ kind: CodexTaskActivityKind,
    _ summary: String,
    _ time: TimeInterval
) -> CodexTaskActivity {
    CodexTaskActivity(id: id, kind: kind, summary: summary, occurredAt: Date(timeIntervalSince1970: time))
}
