import CoreGraphics

public struct CodexBarDetailTarget: Equatable, Sendable {
    public let rowID: String
    public let rowMidY: CGFloat

    public init(rowID: String, rowMidY: CGFloat) {
        self.rowID = rowID
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
        rowID: String,
        rowMidY: CGFloat,
        active: Bool
    ) {
        if active {
            hovered = CodexBarDetailTarget(rowID: rowID, rowMidY: rowMidY)
        } else if hovered?.rowID == rowID {
            hovered = nil
        }
    }

    public mutating func updateFocus(
        rowID: String,
        rowMidY: CGFloat,
        active: Bool
    ) {
        if active {
            focused = CodexBarDetailTarget(rowID: rowID, rowMidY: rowMidY)
        } else if focused?.rowID == rowID {
            focused = nil
        }
    }

    public mutating func clear() {
        hovered = nil
        focused = nil
    }

    public mutating func updatePosition(rowID: String, rowMidY: CGFloat) {
        let target = CodexBarDetailTarget(rowID: rowID, rowMidY: rowMidY)
        if hovered?.rowID == rowID { hovered = target }
        if focused?.rowID == rowID { focused = target }
    }
}
