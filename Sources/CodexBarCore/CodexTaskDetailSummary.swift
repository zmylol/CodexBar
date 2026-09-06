import Foundation

/// Selects a focused task preview from observed status, plan, and recent activity.
public struct CodexTaskDetailSummary: Equatable, Sendable {
    public let focusLabel: String
    public let focusText: String
    public let focusDetail: String?
    public let contextLabel: String?
    public let contextText: String?
    public let nextStep: String?
    public let progressText: String?
    public let progressFraction: Double?
    public let recentActivities: [CodexTaskActivity]
    public let actionTitle: String

    public init(
        task: CodexTask,
        plan: CodexTaskPlan?,
        activities: [CodexTaskActivity]
    ) {
        let plan = plan.flatMap { $0.steps.isEmpty ? nil : $0 }
        let currentStep = plan?.currentStep?.title
        contextText = plan?.steps.last(where: { $0.status == .completed })?.title
        contextLabel = contextText == nil ? nil : "已做"
        focusLabel = "当前"

        if task.status != .ready, let plan {
            let start = plan.steps.firstIndex(where: { $0.status == .inProgress }).map { $0 + 1 } ?? 0
            let pending = plan.steps.dropFirst(start).first(where: { $0.status == .pending })?.title
            nextStep = pending?.trimmingCharacters(in: .whitespacesAndNewlines)
                == currentStep?.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : pending
        } else {
            nextStep = nil
        }

        var details: [String] = []
        switch task.status {
        case .needsAttention:
            focusText = "需要你处理当前请求。"
            if let currentStep {
                details.append("当前计划是「\(currentStep)」，请返回会话处理。")
            } else {
                details.append("请返回会话查看并处理请求。")
            }
            actionTitle = "去处理"
        case .running:
            actionTitle = "查看会话"
            if let currentStep {
                focusText = "正在进行「\(currentStep)」。"
            } else if plan?.isComplete == true {
                focusText = "计划步骤已完成，本轮仍在运行。"
            } else if !activities.isEmpty {
                focusText = "本轮正在运行。"
            } else {
                focusText = "本轮正在运行，尚未记录当前阶段。"
            }
        case .ready:
            focusText = "本轮已停止，可以查看会话。"
            actionTitle = "查看会话"
            if let currentStep {
                details.append("停止前记录的计划阶段是「\(currentStep)」。")
            }
        }
        progressText = plan.map { "已完成 \($0.completedStepCount)/\($0.totalStepCount) 步" }
        progressFraction = plan?.progressFraction

        let visibleText = [currentStep, contextText, nextStep].compactMap { $0 }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        recentActivities = activities.filter {
            !visibleText.contains($0.summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted {
            $0.occurredAt < $1.occurredAt
        }
        focusDetail = details.isEmpty ? nil : details.joined()
    }

    public var accessibilitySummary: String {
        var parts: [String] = []
        if let contextLabel, let contextText {
            parts.append("\(contextLabel)：\(contextText)")
        }
        parts.append("\(focusLabel)：\(focusText)")
        if let focusDetail { parts.append(focusDetail) }
        if !recentActivities.isEmpty {
            parts.append("最近动态：" + recentActivities.map(\.summary).joined(separator: "；"))
        }
        if let nextStep { parts.append("后续计划：\(nextStep)") }
        if let progressText { parts.append(progressText) }
        return parts.map { $0.hasSuffix("。") ? $0 : $0 + "。" }.joined()
    }
}
