import CodexBarCore
import SwiftUI

/// A readable progress overview that grows with the task's observed context.
struct TaskDetailCard: View {
    let task: CodexTask
    let summary: CodexTaskDetailSummary
    let date: Date
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(task.workspaceName)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Label(task.status.label, systemImage: task.status.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(task.status.color)
            }

            Text(task.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(task.title)

            if let label = summary.contextLabel, let context = summary.contextText {
                contextRow(label: label, text: context)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.focusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(summary.focusText)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(summary.focusText)
                if let detail = summary.focusDetail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.recentActivities.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("最近动态 · 按发生顺序")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(summary.recentActivities) { activity in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: activity.kind.symbolName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(activity.kind == .agent ? Color.teal : .secondary)
                                    .frame(width: 16)
                                    .accessibilityHidden(true)
                                Text(activity.summary)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(task.status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(task.status.color)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }

            if let next = summary.nextStep {
                contextRow(label: "后续计划", text: next)
            }

            if let progress = summary.progressText {
                HStack(spacing: 8) {
                    Text(progress)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let fraction = summary.progressFraction {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(task.status.color)
                                    .frame(width: 64 * min(max(fraction, 0), 1))
                            }
                            .frame(width: 64, height: 4)
                            .accessibilityHidden(true)
                    }
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Text(CodexTaskTimeFormatter.accessibilityText(for: task, relativeTo: date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    Label(summary.actionTitle, systemImage: "arrow.up.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(task.status == .needsAttention ? task.status.color : .primary)
                .background(task.status.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
    }

    private func contextRow(label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
        }
        .accessibilityElement(children: .combine)
    }
}
