import AppKit
import CodexBarCore
import SwiftUI

@MainActor final class KnowledgeLibraryModel: ObservableObject {
    @Published var review: KnowledgeVaultReview?
    @Published var isLoading = false
    @Published var message: String?
    @Published var sections: [KnowledgeFolderSection] = []
    @Published var noteCount = 0
    @Published var todayArticles: [KnowledgeArticle] = []
    @Published var yesterdayArticles: [KnowledgeArticle] = []
    @Published var earlierArticles: [KnowledgeArticle] = []
    @Published private(set) var articleRange: KnowledgeArticleRange = .today
    @Published private var seenArticleIDs: Set<String> = []
    var isChoosingVault = false
    var chooseCount = 0
    var refreshCount = 0
    var markedSections: [String] = []
    var openedArticles: [KnowledgeArticle] = []

    func chooseVault() { chooseCount += 1 }
    func refresh() { refreshCount += 1 }
    func openArticle(_ article: KnowledgeArticle) { openedArticles.append(article) }
    func setArticleRange(_ range: KnowledgeArticleRange) { articleRange = range }

    var visibleArticles: [KnowledgeArticle] {
        switch articleRange {
        case .today: todayArticles
        case .yesterday: yesterdayArticles
        case .lastSevenDays: todayArticles + yesterdayArticles + earlierArticles
        }
    }

    func unseenCount(in sectionID: String) -> Int {
        visibleArticles.filter { $0.path.hasPrefix(sectionID + "/") && !seenArticleIDs.contains($0.id) }.count
    }

    func markUpdatesSeen(in sectionID: String) {
        markedSections.append(sectionID)
        seenArticleIDs.formUnion(visibleArticles.filter { $0.path.hasPrefix(sectionID + "/") }.map(\.id))
    }
}

@main struct KnowledgeLibraryViewChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL knowledge library view line \(line): \(message)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor static func elements(_ identifier: String, in parent: Any) -> [AnyObject] {
        let accessible = parent as AnyObject
        var matches: [AnyObject] = accessible.accessibilityIdentifier?() == identifier ? [accessible] : []
        for child in accessible.accessibilityChildren?() ?? [] {
            matches += elements(identifier, in: child)
        }
        return matches
    }

    @MainActor static func element(_ identifier: String, in parent: Any) -> AnyObject? {
        elements(identifier, in: parent).first
    }

    @MainActor static func press(_ identifier: String, in view: NSView) {
        guard let control = element(identifier, in: view) else { fatalError("Missing control: \(identifier)") }
        check(control.accessibilityPerformPress?() == true, "Control did not accept press: \(identifier)")
        settle()
    }

    @MainActor static func capture(_ host: NSView, path: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Could not capture fixture") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode fixture") }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { fatalError("Could not save fixture: \(error)") }
    }

    @MainActor static func value(of element: AnyObject?) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityValue() as? String
    }

    @MainActor static func checkSelected(_ id: String, _ selected: Bool, in host: NSView) {
        check(value(of: element("knowledge-library-row-\(id)", in: host)) == (selected ? "已选中" : "未选中"),
              "Expected category \(id) selection to be \(selected)")
    }

    @MainActor static func unreadBadge(_ id: String, in host: NSView) -> Bool {
        guard let row = element("knowledge-library-row-\(id)", in: host),
              let label = row.accessibilityLabel?() else { return false }
        return label.contains("篇未查看")
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        // Materialize SwiftUI's accessibility tree without changing system accessibility settings.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let model = KnowledgeLibraryModel()
        var dismissed = false
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 520), styleMask: .titled, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: KnowledgeLibraryView(model: model, onChooseVault: model.chooseVault,
                                                               onHoverChanged: { _ in },
                                                               onClose: { dismissed = true }))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle()
        capture(host, path: "/tmp/codexbar-library-empty.png")
        check(abs(host.frame.width - 600) < 1 && abs(host.frame.height - 520) < 1, "Two-column panel must fit 600×520")
        let hasAccessibilityTree = !(host.accessibilityChildren() ?? []).isEmpty
        if hasAccessibilityTree {
            press("knowledge-library-choose", in: host)
            check(model.chooseCount == 1, "An unselected library must offer a folder chooser without any task")
        }
        let vault = ObsidianVault(rootPath: "/fixture/vault", name: "示例知识库")
        model.review = KnowledgeVaultReview(vault: vault, notes: [], isLoading: false, message: nil)
        settle()
        if hasAccessibilityTree {
            check(element("knowledge-library-empty-sections", in: host) != nil,
                  "A connected vault without categories must show the empty categories state")
        }
        model.sections = [
            KnowledgeFolderSection(relativePath: "Anthropic", name: "Anthropic", noteCount: 251),
            KnowledgeFolderSection(relativePath: "Hugging Face", name: "Hugging Face", noteCount: 232),
            KnowledgeFolderSection(relativePath: "LangChain", name: "LangChain", noteCount: 18),
            KnowledgeFolderSection(relativePath: "Simon Willison", name: "Simon Willison", noteCount: 21),
        ]
        let first = KnowledgeArticle(path: "Anthropic/claude-skills.md", title: "Claude Skills 实践", collectedAt: Date())
        let second = KnowledgeArticle(path: "Hugging Face/daily-reading-workflow.md",
                                      title: "把 Agent 会话变成每天都能复用的阅读与实验工作流", collectedAt: Date(),
                                      summary: "文章介绍如何把零散的 Agent 会话整理成可以持续复用的知识：保留任务背景、关键决策和验证结果，再通过每日阅读与小型实验检查这些经验是否适用于新的项目。这样既能找回推理过程，也能减少重复尝试。")
        let third = KnowledgeArticle(path: "Hugging Face/attention-budget.md", title: "注意力预算", collectedAt: Date())
        let yesterday = KnowledgeArticle(path: "Hugging Face/yesterday.md", title: "昨天尚未阅读的文章",
                                         collectedAt: Date().addingTimeInterval(-86_400))
        let earlier = KnowledgeArticle(path: "Anthropic/earlier.md", title: "本周值得补读的文章",
                                       collectedAt: Date().addingTimeInterval(-172_800))
        model.todayArticles = [first, second, third]
        model.yesterdayArticles = [yesterday]
        model.earlierArticles = [earlier]
        settle()
        if hasAccessibilityTree {
            for range in KnowledgeArticleRange.allCases {
                check(element("knowledge-library-range-\(range.rawValue)", in: host) != nil,
                      "Each reading range must have an accessible control: \(range.rawValue)")
            }
            check(model.articleRange == .today, "The library must initially show today's articles")
            check(model.markedSections.isEmpty, "Initial presentation must not acknowledge any library")
            check(element("knowledge-library-select-section", in: host) != nil,
                  "Initial detail must ask the user to select a library")
            check(element("knowledge-library-sections", in: host) != nil &&
                  element("knowledge-library-article-list", in: host) == nil,
                  "Initial sidebar must contain libraries without showing all article lists")
            for section in model.sections {
                checkSelected(section.id, false, in: host)
            }
            check(unreadBadge("Anthropic", in: host) && unreadBadge("Hugging Face", in: host),
                  "Each unread library must show its own badge")
            check(!unreadBadge("LangChain", in: host),
                  "Zero unread articles must not show a badge")
            press("knowledge-library-row-Hugging Face", in: host)
            checkSelected("Hugging Face", true, in: host)
            checkSelected("Anthropic", false, in: host)
            check(model.markedSections == ["Hugging Face"], "Selecting a library must acknowledge only that library")
            check(!unreadBadge("Hugging Face", in: host) && unreadBadge("Anthropic", in: host),
                  "Selecting one library must remove only its badge")
            check(element("knowledge-note-\(first.id)", in: host) == nil,
                  "The detail must not show articles from another library")
            for article in [second, third] {
                guard let row = element("knowledge-note-\(article.id)", in: host) else {
                    fatalError("Missing article row: \(article.id)")
                }
                check(row.accessibilityLabel?() == article.title, "Article rows must expose the collected title")
                check((value(of: row) ?? "") == (article.summary ?? ""),
                      "Article rows must expose their full summary without changing the title label")
                press("knowledge-note-\(article.id)", in: host)
            }
            check(model.openedArticles.map(\.id) == [second.id, third.id], "Clicking a title must open its article")
        }
        capture(host, path: "/tmp/codexbar-library-light.png")
        host.appearance = NSAppearance(named: .darkAqua)
        settle()
        capture(host, path: "/tmp/codexbar-library-dark.png")
        host.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 320, height: 520))
        settle()
        capture(host, path: "/tmp/codexbar-library-narrow.png")
        check(abs(host.frame.width - 320) < 1 && abs(host.frame.height - 520) < 1,
              "Narrow-screen layout must stay within 320×520")
        if hasAccessibilityTree {
            let screenFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
            for range in KnowledgeArticleRange.allCases {
                guard let control = element("knowledge-library-range-\(range.rawValue)", in: host),
                      let frame = control.accessibilityFrame?() else {
                    fatalError("Missing narrow reading range control: \(range.rawValue)")
                }
                check(frame.width > 0 && screenFrame.contains(frame),
                      "Every reading range control must stay inside the 320-point panel")
            }
        }
        window.setContentSize(NSSize(width: 600, height: 520))
        let incoming = KnowledgeArticle(path: "Hugging Face/arrived-later.md", title: "稍后自动获取的文章", collectedAt: Date())
        model.todayArticles.append(incoming)
        settle()
        if hasAccessibilityTree {
            checkSelected("Hugging Face", true, in: host)
            check(model.markedSections == ["Hugging Face"], "Arrival must not automatically acknowledge the selected library")
            check(unreadBadge("Hugging Face", in: host) &&
                  element("knowledge-note-\(incoming.id)", in: host) != nil,
                  "A newly arrived article must appear in the selected detail and restore its badge")
            press("knowledge-library-refresh", in: host)
            check(model.refreshCount == 1 && model.markedSections == ["Hugging Face"],
                  "Refreshing must preserve the selected library's unread badge")
            window.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            settle()
            checkSelected("Hugging Face", true, in: host)
            check(unreadBadge("Hugging Face", in: host),
                  "Reopening must preserve selection without acknowledging unread articles")
            press("knowledge-library-row-Hugging Face", in: host)
            check(model.markedSections == ["Hugging Face", "Hugging Face"],
                  "Clicking the selected library again must acknowledge newly arrived articles")
            check(!unreadBadge("Hugging Face", in: host) &&
                  element("knowledge-note-\(incoming.id)", in: host) != nil,
                  "Acknowledging articles must remove the badge but retain article titles")
            let marksBeforeRangeChange = model.markedSections
            let responderBeforeRangeChange = window.firstResponder
            press("knowledge-library-range-yesterday", in: host)
            check(model.articleRange == .yesterday, "Yesterday's control must select yesterday's articles")
            checkSelected("Hugging Face", true, in: host)
            check(model.markedSections == marksBeforeRangeChange && unreadBadge("Hugging Face", in: host),
                  "Changing the reading range must retain the category without acknowledging its articles")
            check(window.firstResponder === responderBeforeRangeChange,
                  "Changing the reading range must not assign keyboard focus")
            check(element("knowledge-note-\(yesterday.id)", in: host) != nil &&
                  element("knowledge-note-\(second.id)", in: host) == nil,
                  "Yesterday's detail must replace today's article rows")
            check(element("knowledge-library-article-list", in: host)?.accessibilityLabel?() == "Hugging Face昨日新增文章",
                  "The article list must announce the selected reading range")
            capture(host, path: "/tmp/codexbar-library-yesterday.png")
            press("knowledge-library-row-Hugging Face", in: host)
            check(!unreadBadge("Hugging Face", in: host), "Selecting yesterday's category must acknowledge its visible articles")
            let marksBeforeWeek = model.markedSections
            press("knowledge-library-range-lastSevenDays", in: host)
            check(model.articleRange == .lastSevenDays && model.markedSections == marksBeforeWeek,
                  "The seven-day control must change the range without marking articles seen")
            checkSelected("Hugging Face", true, in: host)
            check(element("knowledge-note-\(yesterday.id)", in: host) != nil &&
                  element("knowledge-note-\(second.id)", in: host) != nil,
                  "The seven-day detail must include both today's and yesterday's articles")
            check(!unreadBadge("Hugging Face", in: host) && unreadBadge("Anthropic", in: host),
                  "Acknowledged articles must remain acknowledged across reading ranges")
            capture(host, path: "/tmp/codexbar-library-week.png")
            press("knowledge-library-range-today", in: host)
            press("knowledge-library-row-LangChain", in: host)
            check(element("knowledge-library-empty-LangChain", in: host) != nil,
                  "A selected empty library must show today's empty state")
            check(element("knowledge-note-\(second.id)", in: host) == nil,
                  "Switching libraries must replace the detail list")
            press("knowledge-library-range-yesterday", in: host)
            check(element("knowledge-library-empty-LangChain", in: host)?.accessibilityLabel?() == "昨日暂无新增",
                  "An empty category must announce yesterday when yesterday is selected")
            press("knowledge-library-range-today", in: host)
        }
        capture(host, path: "/tmp/codexbar-library-no-updates.png")
        let replacement = ObsidianVault(rootPath: "/fixture/replaced-vault", name: "新的总目录")
        model.review = KnowledgeVaultReview(vault: replacement, notes: [], isLoading: false, message: nil)
        settle()
        if hasAccessibilityTree {
            check(element("knowledge-library-select-section", in: host) != nil,
                  "Changing the root must clear the selected category")
            for section in model.sections { checkSelected(section.id, false, in: host) }
            press("knowledge-library-row-Anthropic", in: host)
        }
        model.sections.removeAll { $0.id == "Anthropic" }
        settle()
        if hasAccessibilityTree {
            check(element("knowledge-library-row-Anthropic", in: host) == nil &&
                  element("knowledge-library-select-section", in: host) != nil,
                  "Removing the selected library must remove its row and clear the detail")
            press("knowledge-library-change-vault", in: host)
            check(model.chooseCount == 2, "The selected vault must still offer a directory chooser")
            press("knowledge-library-close", in: host)
            check(dismissed, "Close must dismiss the library")
        }
        model.sections += (1...40).map {
            KnowledgeFolderSection(relativePath: "分类\($0)", name: "分类 \($0)", noteCount: $0)
        }
        settle()
        capture(host, path: "/tmp/codexbar-library-many.png")
        check(abs(host.frame.height - 520) < 1, "Many libraries must scroll without growing the panel")
        window.orderOut(nil)
        window.contentView = nil
        print("PASS knowledge library native rendering: 600×520 light/dark, first use, empty detail, many categories, and 320×520 narrow fixtures")
        print(hasAccessibilityTree ? "PASS knowledge library native actions: reading ranges, retained category and focus, range-scoped badges, selection-only acknowledgement, incremental arrival, reopen retention, root reset, category removal, open titles, choose, refresh, close" : "SKIP knowledge library actions: no SwiftUI AX tree in this graphical session")
    }
}
