import CodexBarCore
import SwiftUI

struct PanelSizeSettingsView: View {
    private enum HeightMode: String, CaseIterable {
        case compact = "紧凑（最多显示 5 项）"
        case custom = "自定义高度（滚动）"
        case expanded = "自动展开"
    }

    @ObservedObject var preferences: PanelSizePreferences
    @ObservedObject var model: CodexBarAppModel
    let currentHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("主悬浮条大小")
                .font(.headline)
            dimensionSlider(
                "宽度",
                value: Binding(get: { preferences.width }, set: { preferences.setWidth($0) }),
                range: CodexBarPanelLayout.compactWidth...CodexBarPanelLayout.maximumWidth
            )
            Picker("高度模式", selection: heightMode) {
                ForEach(HeightMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            dimensionSlider(
                "高度",
                value: Binding(
                    get: { preferences.height ?? min(max(currentHeight, CodexBarPanelLayout.minimumHeight), CodexBarPanelLayout.maximumHeight) },
                    set: { preferences.setHeight($0) }
                ),
                range: CodexBarPanelLayout.minimumHeight...CodexBarPanelLayout.maximumHeight
            )
            .disabled(heightMode.wrappedValue != .custom)
            Text(heightMode.wrappedValue == .custom
                 ? "超出高度的项目可滚动查看。尺寸会自动保存，并限制在屏幕可见范围内。"
                 : "高度随项目数量调整。选择“自定义高度（滚动）”后可手动调节。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("恢复默认") {
                    preferences.reset()
                    model.setPanelDisplayMode(.scrolling)
                }
                Spacer()
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onExitCommand(perform: onClose)
    }

    private var heightMode: Binding<HeightMode> {
        Binding(
            get: {
                if model.panelDisplayMode == .expanded { return .expanded }
                return preferences.height == nil ? .compact : .custom
            },
            set: { mode in
                switch mode {
                case .compact:
                    preferences.setHeight(nil)
                    model.setPanelDisplayMode(.scrolling)
                case .custom:
                    preferences.setHeight(preferences.height ?? currentHeight)
                    model.setPanelDisplayMode(.scrolling)
                case .expanded:
                    model.setPanelDisplayMode(.expanded)
                }
            }
        )
    }

    private func dimensionSlider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue)) 点")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue)) 点")
        }
    }
}
