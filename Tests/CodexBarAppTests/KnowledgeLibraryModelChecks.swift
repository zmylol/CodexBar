import AppKit
import CodexBarCore
import Foundation

@main
@MainActor
struct KnowledgeLibraryModelChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote("old note\n", path: "Category/One.md", root: root)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let registry = root.appendingPathComponent("missing-registry.json")
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        precondition(model.review == nil, "The library should be reachable before a vault or task exists")
        await model.selectVault(root)
        precondition(model.review?.vault.rootPath == root.path && model.review?.notes.isEmpty == true,
                     "Selecting a vault should establish a baseline without pretending old notes are new: \(model.message ?? "no error")")
        try writeNote("new note\n", path: "Category/One.md", root: root)
        await model.refreshNow()
        guard let note = model.review?.notes.first else { fatalError("Folder changes were not recorded without a VS Code task") }
        precondition(note.kind == "update" && note.diff?.contains("new note") == true)
        await model.toggleReviewNow(note)
        precondition(model.review?.pendingCount == 0)
        let reviewedNotes = model.review?.notes
        await model.selectVault(root)
        precondition(model.review?.notes == reviewedNotes && model.review?.pendingCount == 0,
                     "Selecting the same vault discarded its existing review state")
        try writeNote("latest note\n", path: "Category/One.md", root: root)
        await model.refreshNow()
        await model.toggleReviewNow(note)
        precondition(model.review?.pendingCount == 1, "Stale review action confirmed an unseen file version")
        await model.selectVault(root.deletingLastPathComponent())
        precondition(model.review?.vault.rootPath == root.path && model.message != nil,
                     "Invalid selection discarded the active vault or hid the error")
        model.stop()
        try writeNote("after stop\n", path: "Category/One.md", root: root)
        try await Task.sleep(for: .milliseconds(900))
        precondition(model.review == nil, "Stopping retained private note contents or accepted delayed file events")
        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        await restored.restoreNow()
        precondition(restored.review?.vault.rootPath == root.path && restored.review?.notes.isEmpty == true,
                     "Restart should restore the selected folder and establish a fresh baseline")
        restored.stop()
        try await automaticSections()
        try await unseenUpdates()
        try await sectionBadges()
        try await rootFilesAreIgnored()
        print("PASS independent knowledge library: no VS Code dependency, folder baseline, diff/review, stale-action guard, invalid selection, stop and restoration")
    }

    private static func unseenUpdates() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-daily-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("Vault")
        let suite = "codexbar-library-daily-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        var currentDate = ISO8601DateFormatter().date(from: "2026-09-11T09:00:00+08:00")!
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: parent.appendingPathComponent("missing.json"),
                                          now: { currentDate })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try writeNote(articleText("Old", collected: "2026-09-10"), path: "A/Old.md", root: root)
        try writeNote(articleText("Morning", collected: "2026-09-11T09:00:00+08:00"), path: "A/Morning.md", root: root)
        await model.selectVault(root)
        precondition(model.todayArticles.map(\.title) == ["Morning"] && model.unseenChangeCount == 1,
                     "Initial scan must restore today's collected articles from their metadata")
        precondition(model.sections.map(\.id) == ["A", "Empty"], "An empty category must remain available")
        model.markUpdatesSeen(in: "A")
        let retainedArticles = model.todayArticles
        precondition(model.unseenChangeCount == 0 && model.todayArticles == retainedArticles)
        precondition(model.todayArticles.first?.summary == nil)
        let summary = "文章介绍如何让几个任务并行推进，通过明确交接条件和验证结果，减少来回切换项目的成本。"
        try writeNote(articleText("Morning", collected: "2026-09-11T09:00:00+08:00") + "\n## 摘要\n\n" + summary,
                      path: "A/Morning.md", root: root)
        // A collector may write the summary after the article metadata has already arrived.
        for _ in 0..<60 where model.todayArticles.first?.summary != summary {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(model.todayArticles.first?.summary == summary
                     && model.todayArticles.map(\.id) == retainedArticles.map(\.id)
                     && model.todayArticles.map(\.collectedAt) == retainedArticles.map(\.collectedAt)
                     && model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 0,
                     "A summary arriving through filesystem events must update the preview without notifying again")
        let revisedSummary = "文章说明怎样为并行任务设计清晰的交接条件，并用独立验证判断结果是否可用。"
        try writeNote(articleText("Morning", collected: "2026-09-11T09:00:00+08:00") + "\n## 摘要\n\n" + revisedSummary,
                      path: "A/Morning.md", root: root)
        await model.refreshNow()
        precondition(model.todayArticles.first?.summary == revisedSummary && model.unseenChangeCount == 0,
                     "Editing a seen article's summary must update its content without restoring the badge")
        try writeNote(articleText("Old revised", collected: "2026-09-10"), path: "A/Old.md", root: root)
        try writeNote(articleText("Morning revised", collected: "2026-09-11T09:00:00+08:00"), path: "A/Morning.md", root: root)
        try writeNote("---\ntype: index\ncollected: 2026-09-11\n---\n# Index", path: "A/00-Home.md", root: root)
        await model.refreshNow()
        precondition(model.todayArticles.map(\.title) == ["Morning revised"] && model.unseenChangeCount == 0,
                     "Editing an article must retain its collection date without producing a new-article notification")
        currentDate = ISO8601DateFormatter().date(from: "2026-09-11T09:40:00+08:00")!
        try writeNote(articleText("Later batch", collected: "2026-09-11T09:40:00+08:00"), path: "B/Later.md", root: root)
        // This must arrive through the real filesystem monitor, without manual refresh or opening the panel.
        for _ in 0..<60 where model.todayArticles.count != 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(model.todayArticles.map(\.title) == ["Later batch", "Morning revised"] && model.unseenChangeCount == 1,
                     "A later automation batch must append immediately to today's existing articles")
        await model.refreshNow()
        precondition(model.todayArticles.count == 2 && model.unseenChangeCount == 1, "Repeated scans duplicated articles")
        model.markUpdatesSeen(in: "B")
        try FileManager.default.moveItem(at: root.appendingPathComponent("A/Morning.md"),
                                        to: root.appendingPathComponent("B/Renamed.md"))
        await model.refreshNow()
        precondition(model.todayArticles.count == 2 && model.todayArticles.contains { $0.path == "B/Renamed.md" }
                     && model.unseenChangeCount == 0, "Moving an already seen article must not count as a new collection")
        try FileManager.default.removeItem(at: root.appendingPathComponent("B/Renamed.md"))
        await model.refreshNow()
        precondition(model.todayArticles.map(\.path) == ["B/Later.md"], "Deleted articles must leave the reading list")
        model.stop()
        precondition(model.todayArticles.isEmpty && model.unseenChangeCount == 0)
        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: parent.appendingPathComponent("missing.json"),
                                             now: { currentDate })
        defer { restored.stop() }
        await restored.restoreNow()
        precondition(restored.todayArticles.map(\.path) == ["B/Later.md"], "Restart discarded today's earlier automation batch")
        currentDate = ISO8601DateFormatter().date(from: "2026-09-12T00:00:01+08:00")!
        restored.refreshToday()
        precondition(restored.todayArticles.isEmpty && restored.unseenChangeCount == 0 && restored.sections.count == 3,
                     "The next Beijing calendar day must clear yesterday's articles but retain categories")
        try writeNote(articleText("Next day", collected: "2026-09-12"), path: "A/New.md", root: root)
        await restored.refreshNow()
        precondition(restored.todayArticles.map(\.title) == ["Next day"] && restored.unseenChangeCount == 1)
        print("PASS daily articles: metadata restoration, live summary updates without unread changes, persistent categories, staggered arrivals, edits excluded, moves, deletion, restart and Beijing day rollover")
    }

    private static func sectionBadges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-badges-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-badges-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: root.appendingPathComponent("missing.json"))
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        for path in ["A/One.md", "B/One.md", "B/Two.md", "AExtra/One.md"] {
            try writeNote(articleText(path), path: path, root: root)
        }
        await model.selectVault(root)
        precondition(model.unseenCount(in: "A") == 1 && model.unseenCount(in: "B") == 2
                     && model.unseenCount(in: "AExtra") == 1 && model.unseenChangeCount == 4)
        model.refreshToday()
        precondition(model.unseenChangeCount == 4, "Opening or projecting the list must not acknowledge any category")
        let retained = model.todayArticles
        model.markUpdatesSeen(in: "A")
        precondition(model.unseenCount(in: "A") == 0 && model.unseenCount(in: "B") == 2
                     && model.unseenCount(in: "AExtra") == 1 && model.unseenChangeCount == 3
                     && model.todayArticles == retained, "Selecting one category must clear only its badge and preserve articles")
        model.markUpdatesSeen(in: "A")
        model.markUpdatesSeen(in: "")
        precondition(model.unseenChangeCount == 3, "Repeated or invalid selection acknowledged another category")
        try writeNote(articleText("New arrival"), path: "A/Two.md", root: root)
        await model.refreshNow()
        precondition(model.unseenCount(in: "A") == 1 && model.unseenCount(in: "B") == 2,
                     "A later article must restore only its own category's badge")
        model.markUpdatesSeen(in: "B")
        precondition(model.unseenCount(in: "B") == 0 && model.unseenCount(in: "A") == 1
                     && model.todayArticles.count == 5, "Switching categories cleared another badge or removed articles")
        model.markUpdatesSeen(in: "A")
        precondition(model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 1)
        print("PASS per-library badges: independent counts, explicit selection only, repeat selection, prefix isolation, new arrivals and retained articles")
    }

    private static func articleText(_ title: String, collected: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return "---\ntype: article\ncollected: '\(collected ?? formatter.string(from: Date()))'\npublished: '2020-01-01'\n---\n# \(title)\n"
    }

    private static func automaticSections() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-sections-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("Obsidian Vault")
        let registry = parent.appendingPathComponent("obsidian.json")
        let suite = "codexbar-library-sections-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote("first", path: "Anthropic/Overview.md", root: root)
        try writeNote("nested", path: "Anthropic/Deep/Details.md", root: root)
        try writeNote("cookbook", path: "LLM Cookbook/Overview.md", root: root)
        try JSONSerialization.data(withJSONObject: ["vaults": ["registered": ["path": root.path, "open": true]]]).write(to: registry)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        defer { model.stop() }
        await model.restoreNow()
        precondition(model.review?.vault.rootPath == root.path && model.review?.notes.isEmpty == true,
                     "Registry discovery did not establish a fresh baseline at the registered total vault")
        precondition(model.sections == [
            KnowledgeFolderSection(relativePath: "Anthropic", name: "Anthropic", noteCount: 2),
            KnowledgeFolderSection(relativePath: "LLM Cookbook", name: "LLM Cookbook", noteCount: 1)
        ] && model.noteCount == 3, "Registered vault did not expose its two nested classifications")
        precondition(model.review(for: "Anthropic")?.notes.isEmpty == true
                     && model.pendingCount(in: "Anthropic") == 0 && model.pendingCount(in: "LLM Cookbook") == 0,
                     "Existing classified notes were reported as new changes")

        try writeNote("first revised", path: "Anthropic/Overview.md", root: root)
        try writeNote("cookbook revised", path: "LLM Cookbook/Overview.md", root: root)
        try writeNote("similar prefix", path: "AnthropicExtra/Overview.md", root: root)
        try writeNote("root note", path: "Root.md", root: root)
        await model.refreshNow()
        precondition(model.review(for: nil)?.notes.count == 3 && model.unseenChangeCount == 0 && model.noteCount == 4,
                     "Root files must remain ignored and ordinary edits must not create article notifications")
        precondition(model.review(for: "Anthropic")?.notes.map(\.path) == ["Anthropic/Overview.md"]
                     && model.pendingCount(in: "Anthropic") == 1
                     && model.pendingCount(in: "LLM Cookbook") == 1
                     && model.pendingCount(in: "AnthropicExtra") == 1,
                     "Classification filters leaked similarly prefixed folders or mixed pending counts")
        guard let firstNote = model.review(for: "Anthropic")?.notes.first else {
            fatalError("Classified note change is missing")
        }
        await model.toggleReviewNow(firstNote)
        precondition(model.pendingCount(in: "Anthropic") == 0 && model.pendingCount(in: "LLM Cookbook") == 1,
                     "Reviewing one classification changed another classification's pending state")
        let beforeSwitching = model.review?.notes
        for sectionID in ["Anthropic", "LLM Cookbook", "AnthropicExtra"] {
            precondition(model.review(for: sectionID) != nil, "A current classification has no review surface")
        }
        precondition(model.review?.notes == beforeSwitching && model.pendingCount(in: "Anthropic") == 0,
                     "Switching classifications rebuilt the baseline or discarded review state")
        try writeNote("first revised again", path: "Anthropic/Overview.md", root: root)
        await model.refreshNow()
        precondition(model.pendingCount(in: "Anthropic") == 1
                     && model.review(for: "Anthropic")?.notes.first?.diff?.contains("-first revised\n") == true,
                     "A later classified edit lost the pre-switch baseline or stayed reviewed")

        try FileManager.default.moveItem(at: root.appendingPathComponent("Anthropic/Overview.md"),
                                        to: root.appendingPathComponent("LLM Cookbook/Moved.md"))
        await model.refreshNow()
        precondition(model.review(for: "Anthropic")?.notes.first?.previousPath == "Anthropic/Overview.md"
                     && model.review(for: "LLM Cookbook")?.notes.contains(where: { $0.path == "LLM Cookbook/Moved.md" }) == true,
                     "A cross-classification move was missing from its source or destination")
        precondition(model.pendingCount(in: "Anthropic") == 1 && model.pendingCount(in: "LLM Cookbook") == 2,
                     "Cross-classification move counts ignored the previous path")

        try FileManager.default.removeItem(at: root.appendingPathComponent("AnthropicExtra"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("New Empty Section"), withIntermediateDirectories: true)
        await model.refreshNow()
        precondition(!model.sections.contains { $0.id == "AnthropicExtra" }
                     && model.sections.contains(KnowledgeFolderSection(relativePath: "New Empty Section", name: "New Empty Section", noteCount: 0)),
                     "Classification inventory did not follow newly created or deleted directories")
        precondition(model.review(for: "AnthropicExtra") == nil, "Removed classification remained selectable")
        precondition(model.review(for: "") == nil && model.pendingCount(in: "") == 0
                     && model.review?.notes.contains(where: { $0.path == "Root.md" }) == false,
                     "Root-level files created a synthetic classification or retained a review record")
        model.stop()
        precondition(model.sections.isEmpty && model.noteCount == 0 && model.review == nil,
                     "Stopping left the classified vault contents in the model")
        print("PASS registered knowledge library: automatic total vault, recursive classifications, isolated review, prefix boundaries, shared baseline, moves and live directory updates")
    }

    private static func rootFilesAreIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-folders-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-folders-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote("existing root note", path: "Root.md", root: root)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: root.appendingPathComponent("missing.json"))
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        await model.selectVault(root)
        precondition(model.review != nil && model.sections.isEmpty && model.noteCount == 0,
                     "A vault containing only root files should connect without inventing a classification")
        try writeNote("changed root note", path: "Root.md", root: root)
        try writeNote("new root note", path: "New.md", root: root)
        await model.refreshNow()
        precondition(model.sections.isEmpty && model.noteCount == 0 && model.review?.notes.isEmpty == true
                     && model.unseenChangeCount == 0,
                     "Root file updates created invisible notes or an update badge")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Root.md"))
        await model.refreshNow()
        precondition(model.review?.notes.isEmpty == true && model.unseenChangeCount == 0,
                     "Deleting an ignored root file created an update badge")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Category"), withIntermediateDirectories: true)
        await model.refreshNow()
        precondition(model.sections == [KnowledgeFolderSection(relativePath: "Category", name: "Category", noteCount: 0)]
                     && model.unseenChangeCount == 0, "An empty first-level folder was not recognized")
        try writeNote(articleText("nested note"), path: "Category/Nested/Note.md", root: root)
        await model.refreshNow()
        precondition(model.noteCount == 1 && model.unseenChangeCount == 1
                     && model.review(for: "Category")?.notes.map(\.path) == ["Category/Nested/Note.md"],
                     "Folder-only detection lost recursive note reading or new update notifications")
        print("PASS folder-only knowledge library: no root files or synthetic categories, no invisible badges, empty folders and recursive note updates")
    }

    private static func writeNote(_ text: String, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
