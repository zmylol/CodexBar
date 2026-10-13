import CodexBarCore
import Combine
import Foundation

@MainActor
final class PanelSizePreferences: ObservableObject {
    private enum Key {
        static let width = "CodexBar.panel.width"
        static let height = "CodexBar.panel.height"
    }

    @Published private(set) var width: CGFloat
    @Published private(set) var height: CGFloat?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let savedWidth = (defaults.object(forKey: Key.width) as? NSNumber)?.doubleValue
        let savedHeight = (defaults.object(forKey: Key.height) as? NSNumber)?.doubleValue
        width = Self.boundedWidth(savedWidth.map { CGFloat($0) } ?? CodexBarPanelLayout.compactWidth)
        height = Self.boundedHeight(savedHeight.map { CGFloat($0) })
    }

    func setWidth(_ value: CGFloat) {
        width = Self.boundedWidth(value)
        persist()
    }

    func setHeight(_ value: CGFloat?) {
        height = Self.boundedHeight(value)
        persist()
    }

    func reset() {
        width = CodexBarPanelLayout.compactWidth
        height = nil
        persist()
    }

    private func persist() {
        defaults.set(Double(width), forKey: Key.width)
        if let height {
            defaults.set(Double(height), forKey: Key.height)
        } else {
            defaults.removeObject(forKey: Key.height)
        }
        onChange?()
    }

    private static func boundedWidth(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return CodexBarPanelLayout.compactWidth }
        return min(max(value, CodexBarPanelLayout.compactWidth), CodexBarPanelLayout.maximumWidth)
    }

    private static func boundedHeight(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, CodexBarPanelLayout.minimumHeight), CodexBarPanelLayout.maximumHeight)
    }
}
