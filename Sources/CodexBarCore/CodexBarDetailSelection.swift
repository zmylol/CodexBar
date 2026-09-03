import CoreGraphics

public struct CodexBarDetailTarget: Equatable, Sendable {
    public let cwd: String
    public let rowMidY: CGFloat

    public init(cwd: String, rowMidY: CGFloat) {
        self.cwd = cwd
        self.rowMidY = rowMidY
    }
}

public struct CodexBarDetailSelection: Equatable, Sendable {
    public private(set) var hovered: CodexBarDetailTarget?
    public private(set) var focused: CodexBarDetailTarget?

    public var selected: CodexBarDetailTarget? {
        hovered ?? focused
    }

    public init() {}

    public mutating func updateHover(
        cwd: String,
        rowMidY: CGFloat,
        active: Bool
    ) {
        if active {
            hovered = CodexBarDetailTarget(cwd: cwd, rowMidY: rowMidY)
        } else if hovered?.cwd == cwd {
            hovered = nil
        }
    }

    public mutating func updateFocus(
        cwd: String,
        rowMidY: CGFloat,
        active: Bool
    ) {
        if active {
            focused = CodexBarDetailTarget(cwd: cwd, rowMidY: rowMidY)
        } else if focused?.cwd == cwd {
            focused = nil
        }
    }

    public mutating func clear() {
        hovered = nil
        focused = nil
    }
}
