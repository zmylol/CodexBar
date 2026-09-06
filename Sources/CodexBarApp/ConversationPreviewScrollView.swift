import AppKit
import SwiftUI

/// AppKit owns scrolling so incoming text never displaces a reader who has scrolled up.
struct ConversationPreviewScrollView<Content: View>: NSViewRepresentable {
    let itemIDs: [String]
    @Binding var isFollowingLatest: Bool
    var onApproachTop: () -> Void = {}
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isFollowingLatest: $isFollowingLatest)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PreviewScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalLineScroll = 28
        scrollView.verticalPageScroll = 28
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            content: AnyView(content()),
            itemIDs: itemIDs,
            binding: $isFollowingLatest,
            onApproachTop: onApproachTop
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: PreviewScrollView?
        private let hostingView = PreviewHostingView(rootView: AnyView(EmptyView()))
        private var content = AnyView(EmptyView())
        private var binding: Binding<Bool>
        private var itemIDs: [String] = []
        private var itemOffsets: [String: CGFloat] = [:]
        private var pendingHistoryAnchor: (id: String, y: CGFloat)?
        private var observer: NSObjectProtocol?
        private var followsLatest = true
        private var isAdjusting = false
        private var isLayoutScheduled = false
        private var needsContentUpdate = true
        private var lastWidth: CGFloat = 0
        private var lastObservedOffset: CGFloat = 0
        private var onApproachTop: () -> Void = {}
        private var isEarlierRequestScheduled = false

        init(isFollowingLatest: Binding<Bool>) {
            binding = isFollowingLatest
            followsLatest = isFollowingLatest.wrappedValue
        }

        fileprivate func attach(to scrollView: PreviewScrollView) {
            self.scrollView = scrollView
            hostingView.sizingOptions = [.intrinsicContentSize]
            hostingView.isFlipped = true
            hostingView.onContentSizeChanged = { [weak self] in self?.scheduleLayout() }
            scrollView.documentView = hostingView
            scrollView.onViewportChanged = { [weak self] in self?.scheduleLayout() }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didScroll() }
            }
        }

        func update(content: AnyView, itemIDs: [String], binding: Binding<Bool>, onApproachTop: @escaping () -> Void) {
            self.content = content
            self.binding = binding
            self.onApproachTop = onApproachTop
            followsLatest = binding.wrappedValue
            if !followsLatest, pendingHistoryAnchor == nil,
               let previousFirst = self.itemIDs.first,
               let previousFirstIndex = itemIDs.firstIndex(of: previousFirst), previousFirstIndex > 0,
               let previousY = itemOffsets[previousFirst] {
                pendingHistoryAnchor = (previousFirst, previousY)
            }
            self.itemIDs = itemIDs
            needsContentUpdate = true
            scheduleLayout()
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            hostingView.onContentSizeChanged = nil
            scrollView?.onViewportChanged = nil
            scrollView = nil
            onApproachTop = {}
        }

        private func scheduleLayout() {
            guard !isLayoutScheduled, !isAdjusting else { return }
            isLayoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLayoutScheduled = false
                self.layoutContent()
            }
        }

        private func layoutContent() {
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            let width = clipView.bounds.width
            guard width > 0 else { return }
            isAdjusting = true
            defer { isAdjusting = false }

            let oldOffset = clipView.bounds.origin.y
            if needsContentUpdate || lastWidth != width {
                needsContentUpdate = false
                lastWidth = width
                hostingView.rootView = AnyView(
                    content.frame(width: width, alignment: .topLeading)
                        .coordinateSpace(name: ConversationItemOffsetKey.coordinateSpace)
                        .onPreferenceChange(ConversationItemOffsetKey.self) { [weak self] offsets in
                            self?.itemOffsets = offsets
                            if self?.pendingHistoryAnchor != nil { self?.scheduleLayout() }
                        }
                )
            }
            hostingView.layoutSubtreeIfNeeded()
            let height = ceil(hostingView.fittingSize.height)
            if hostingView.frame.size != NSSize(width: width, height: height) {
                hostingView.setFrameSize(NSSize(width: width, height: height))
                // Read anchors after laying out at the new height; SwiftUI can compress
                // inter-item spacing while the document still has its previous frame.
                hostingView.layoutSubtreeIfNeeded()
            }

            let targetY: CGFloat
            if followsLatest {
                targetY = max(0, height - clipView.bounds.height)
                pendingHistoryAnchor = nil
            } else if let anchor = pendingHistoryAnchor,
                      let firstID = itemIDs.first, itemOffsets[firstID] != nil,
                      let newY = itemOffsets[anchor.id] {
                // Only movement above the old first item counts; simultaneous tail growth does not.
                targetY = oldOffset + newY - anchor.y
                pendingHistoryAnchor = nil
            } else {
                targetY = oldOffset
            }
            var bounds = clipView.bounds
            bounds.origin.y = targetY
            clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clipView)
            lastObservedOffset = clipView.bounds.minY
        }

        private func didScroll() {
            guard !isAdjusting, let scrollView else { return }
            let clipView = scrollView.contentView
            let offset = clipView.bounds.minY
            if offset < lastObservedOffset, offset <= 80, !isEarlierRequestScheduled {
                isEarlierRequestScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scrollView != nil else { return }
                    self.isEarlierRequestScheduled = false
                    self.onApproachTop()
                }
            }
            lastObservedOffset = offset
            let distanceFromBottom = hostingView.frame.height - clipView.bounds.maxY
            let shouldFollow = distanceFromBottom <= 12
            guard shouldFollow != followsLatest else { return }
            followsLatest = shouldFollow
            // Bounds notifications can arrive during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.followsLatest == shouldFollow else { return }
                if self.binding.wrappedValue != shouldFollow {
                    self.binding.wrappedValue = shouldFollow
                }
            }
        }
    }
}

extension View {
    func conversationPreviewItemAnchor(_ id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ConversationItemOffsetKey.self,
                    value: [id: geometry.frame(in: .named(ConversationItemOffsetKey.coordinateSpace)).minY]
                )
            }
        }
    }
}

private struct ConversationItemOffsetKey: PreferenceKey {
    static let coordinateSpace = "CodexConversationPreviewContent"
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private final class PreviewScrollView: NSScrollView {
    var onViewportChanged: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func tile() {
        let previousSize = contentView.bounds.size
        super.tile()
        if contentView.bounds.size != previousSize { onViewportChanged?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onViewportChanged?()
    }
}

private final class PreviewHostingView: NSHostingView<AnyView> {
    var onContentSizeChanged: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChanged?()
    }
}
