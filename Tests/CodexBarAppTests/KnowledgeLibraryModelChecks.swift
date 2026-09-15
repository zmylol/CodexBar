import AppKit
import CodexBarCore
import Combine
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
        let regressions: [(String, @MainActor () async throws -> Void)] = [
            ("directory exclusions persist and stay within their vault", directoryExclusions),
            ("uncached article moves", uncachedArticleMoves),
            ("replacement root state", replacementRootState),
            ("article reading ranges", articleReadingRanges),
            ("persistent article reading history", persistentArticleReadingHistory),
            ("reading history notifications and retention", readingHistoryNotificationsAndRetention),
            ("historical acknowledgement at receipt capacity", historicalAcknowledgementAtReceiptCapacity),
            ("vault reading history isolation", vaultReadingHistoryIsolation),
            ("root replaced while stopped", rootReplacedWhileStopped)
        ]
        var failures: [String] = []
        for (name, check) in regressions {
            do { try await check() }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS independent knowledge library: no VS Code dependency, folder baseline, diff/review, stale-action guard, invalid selection, stop and restoration")
    }

    private static func directoryExclusions() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-exclusions-\(UUID())")
            .resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("First")
        let other = parent.appendingPathComponent("Second")
        let suite = "codexbar-exclusions-\(UUID())"
        let registry = parent.appendingPathComponent("missing.json")
        let date = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00+08:00")!
        for vault in [root, other] {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vault.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try writeNote(articleText("Project note", collected: "2026-09-13"), path: "Projects/Note.md", root: vault)
            try writeNote(articleText("News", collected: "2026-09-13"), path: "News/Article.md", root: vault)
        }
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { date })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        await model.selectVault(root)
        model.markUpdatesSeen(in: "News")
        await model.setSectionExcluded("Projects", excluded: true)
        try requireState(model.excludedDirectories == ["Projects"]
                         && model.sections.map(\.id) == ["Empty", "News"]
                         && model.todayArticles.map(\.path) == ["News/Article.md"]
                         && model.noteCount == 1 && model.unseenChangeCount == 0,
                         "Excluding a directory must drop its notes and articles while preserving empty categories and receipts")
        try requireState(FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects/Note.md").path),
                         "Excluding a directory changed the user's files")
        try writeNote(articleText("New excluded article", collected: "2026-09-13"), path: "Projects/New.md", root: root)
        await model.refreshNow()
        try requireState(model.noteCount == 1 && model.review?.notes.isEmpty == true,
                         "An excluded subtree continued to contribute scans or changes")
        model.stop()
        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { date })
        defer { restored.stop() }
        await restored.restoreNow()
        try requireState(restored.excludedDirectories == ["Projects"]
                         && restored.sections.map(\.id) == ["Empty", "News"]
                         && restored.unseenChangeCount == 0,
                         "Restart lost exclusions or reset unrelated article acknowledgements")
        await restored.selectVault(other)
        try requireState(restored.excludedDirectories.isEmpty && restored.sections.count == 3,
                         "An exclusion leaked to a different vault with the same directory name")
        await restored.selectVault(root)
        try requireState(restored.excludedDirectories == ["Projects"] && restored.noteCount == 1,
                         "Returning to a vault lost its saved exclusions")
        await restored.setSectionExcluded("../News", excluded: true)
        try requireState(restored.excludedDirectories == ["Projects"], "A path outside the category list became an exclusion")
        await restored.setSectionExcluded("Projects", excluded: false)
        try requireState(restored.excludedDirectories.isEmpty && restored.noteCount == 3
                         && restored.sections.map(\.id) == ["Empty", "News", "Projects"]
                         && restored.review?.notes.isEmpty == true && restored.unseenCount(in: "News") == 0,
                         "Restoring a directory failed to reindex it or invented note changes/reset unrelated receipts")
        for directory in ["Empty", "News", "Projects"] {
            await restored.setSectionExcluded(directory, excluded: true)
        }
        try requireState(restored.review != nil && restored.sections.isEmpty && restored.todayArticles.isEmpty
                         && restored.managedDirectoryNames == ["Empty", "News", "Projects"],
                         "Excluding everything removed the connected vault or the restore choices")
        await restored.setSectionExcluded("Empty", excluded: false)
        try requireState(restored.sections.map(\.id) == ["Empty"], "An empty excluded category could not be restored")
    }

    private static func uncachedArticleMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-uncached-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-uncached-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: root.appendingPathComponent("missing.json"))
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let content = String(repeating: "x", count: KnowledgeFolderTracker.maximumNoteBytes)
        for index in 0..<(KnowledgeFolderTracker.maximumContentBytes / KnowledgeFolderTracker.maximumNoteBytes) {
            try writeNote(content, path: "Archive/Note-\(index).md", root: root)
        }
        await model.selectVault(root)
        try writeNote(articleText("Uncached arrival"), path: "A/Article.md", root: root)
        await model.refreshNow()
        try requireState(model.todayArticles.map(\.path) == ["A/Article.md"] && model.review?.notes.isEmpty == true,
                         "The fixture did not index an article outside the full body cache")
        model.markUpdatesSeen(in: "A")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("A/Article.md"),
                                        to: root.appendingPathComponent("B/Renamed.md"))
        await model.refreshNow()
        try requireState(model.todayArticles.map(\.path) == ["B/Renamed.md"] && model.unseenChangeCount == 0,
                         "Moving a seen article outside the body cache incorrectly restored its unread badge")
        try FileManager.default.linkItem(at: root.appendingPathComponent("B/Renamed.md"),
                                        to: root.appendingPathComponent("B/Twin.md"))
        await model.refreshNow()
        model.markUpdatesSeen(in: "B")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("C"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("B/Renamed.md"),
                                        to: root.appendingPathComponent("C/Ambiguous.md"))
        await model.refreshNow()
        try requireState(model.unseenCount(in: "B") == 0 && model.unseenCount(in: "C") == 1,
                         "Ambiguous hard links incorrectly transferred a previous article's read state")
        print("PASS article read state: uncached rename preserves acknowledgement; ambiguous hard links do not inherit it")
    }

    private static func replacementRootState() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-replacement-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("Vault")
        let suite = "codexbar-library-replacement-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: parent.appendingPathComponent("missing.json"))
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try writeNote(articleText("Original article"), path: "A/Article.md", root: root)
        try writeNote("original baseline", path: "Legacy/Change.md", root: root)
        await model.selectVault(root)
        model.markUpdatesSeen(in: "A")
        try writeNote("original pending edit", path: "Legacy/Change.md", root: root)
        await model.refreshNow()
        guard let oldChange = model.review?.notes.first else {
            throw stateError("The fixture did not establish a pending review for the original root")
        }
        try requireState(model.review?.pendingCount == 1 && model.unseenChangeCount == 0,
                         "The fixture did not establish the original root's pending diff and read article")
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("OldVault"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote(articleText("Replacement article"), path: "A/Article.md", root: root)
        try writeNote("replacement baseline", path: "Legacy/Change.md", root: root)
        await model.refreshNow()
        try requireState(model.review?.notes.isEmpty == true && model.unseenChangeCount == 1
                         && model.todayArticles.map(\.title) == ["Replacement article"],
                         "Replacement root inherited old review records or same-path article read state (pending: \(model.review?.pendingCount ?? -1), unread: \(model.unseenChangeCount))")
        await model.toggleReviewNow(oldChange)
        try requireState(model.review?.notes.isEmpty == true && model.unseenChangeCount == 1,
                         "A delayed review action restored records or read state from the old root")
        model.markUpdatesSeen(in: "A")
        await model.refreshNow()
        try requireState(model.unseenChangeCount == 0, "An unchanged replacement root repeatedly reset read state")
        try writeNote("replacement pending edit", path: "Legacy/Change.md", root: root)
        await model.refreshNow()
        try requireState(model.review?.pendingCount == 1
                         && model.review?.notes.first?.diff?.contains("-replacement baseline") == true,
                         "The replacement root did not use its own baseline for subsequent reviews")
        print("PASS root replacement: old pending diffs and read state cleared; stale actions rejected; later edits use the new baseline")
    }

    private static func articleReadingRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-ranges-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-ranges-\(UUID().uuidString)"
        let now = ISO8601DateFormatter().date(from: "2026-09-13T00:00:01+08:00")!
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: root.appendingPathComponent("missing.json"),
                                          now: { now })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let articles = [
            ("Tomorrow", "2026-09-13T16:00:00Z"),
            ("Today late", "2026-09-13T15:59:59Z"),
            ("Today start", "2026-09-12T16:00:00Z"),
            ("Yesterday end", "2026-09-12T15:59:59Z"),
            ("Week start", "2026-09-06T16:00:00Z"),
            ("Too old", "2026-09-06T15:59:59Z")
        ]
        for (title, collected) in articles {
            try writeNote(articleText(title, collected: collected), path: "A/\(title).md", root: root)
        }
        await model.selectVault(root)
        try requireState(model.articleRange == .today
                         && model.visibleArticles.map(\.title) == ["Today late", "Today start"]
                         && model.todayArticles == model.visibleArticles
                         && model.unseenChangeCount == 2,
                         "The initial reading range did not use the current Shanghai calendar day or newest-first order")
        model.setArticleRange(.yesterday)
        try requireState(model.visibleArticles.map(\.title) == ["Yesterday end"]
                         && model.unseenCount(in: "A") == 1 && model.unseenChangeCount == 2,
                         "Switching to yesterday changed today's badge, acknowledged an article, or crossed the Shanghai day boundary")
        model.markUpdatesSeen(in: "A")
        try requireState(model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 2,
                         "Reading yesterday acknowledged today's articles in the same category")
        model.setArticleRange(.lastSevenDays)
        try requireState(model.visibleArticles.map(\.title) == ["Today late", "Today start", "Yesterday end", "Week start"]
                         && model.unseenCount(in: "A") == 3 && model.unseenChangeCount == 2,
                         "The seven-day range must include today and six previous calendar days, exclude tomorrow, and retain read state")
        model.setArticleRange(.today)
        try requireState(model.unseenCount(in: "A") == 2 && model.visibleArticles == model.todayArticles,
                         "Switching reading ranges implicitly acknowledged today's articles")
        model.setArticleRange(.lastSevenDays)
        model.markUpdatesSeen(in: "A")
        try requireState(model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 0
                         && model.visibleArticles.count == 4,
                         "Reading a category in the seven-day range must acknowledge its visible articles without removing them")
        print("PASS reading ranges: Shanghai day boundaries, seven calendar days, newest-first order, explicit acknowledgement and today's independent badge")
    }

    private static func persistentArticleReadingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-history-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-history-\(UUID().uuidString)"
        let registry = root.appendingPathComponent("missing.json")
        var currentDate = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00+08:00")!
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { currentDate })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote(articleText("Today", collected: "2026-09-13"), path: "A/Today.md", root: root)
        try writeNote(articleText("Yesterday", collected: "2026-09-12"), path: "A/Yesterday.md", root: root)
        try writeNote(articleText("Earlier", collected: "2026-09-07"), path: "B/Earlier.md", root: root)
        await model.selectVault(root)
        model.markUpdatesSeen(in: "A")
        model.setArticleRange(.yesterday)
        model.markUpdatesSeen(in: "A")
        model.setArticleRange(.lastSevenDays)
        model.markUpdatesSeen(in: "B")
        model.stop()

        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { currentDate })
        defer { restored.stop() }
        await restored.restoreNow()
        try requireState(restored.articleRange == .today && restored.visibleArticles.map(\.title) == ["Today"]
                         && restored.unseenChangeCount == 0 && restored.unseenCount(in: "A") == 0,
                         "Restart must open today while preserving today's acknowledged articles")
        restored.setArticleRange(.yesterday)
        try requireState(restored.visibleArticles.map(\.title) == ["Yesterday"] && restored.unseenCount(in: "A") == 0,
                         "Restart forgot articles acknowledged in yesterday's range")
        restored.setArticleRange(.lastSevenDays)
        try requireState(restored.visibleArticles.count == 3 && restored.unseenCount(in: "A") == 0
                         && restored.unseenCount(in: "B") == 0,
                         "Restart forgot articles acknowledged in the seven-day range")

        let summary = "A revised summary after the article was already read."
        try writeNote(articleText("Today revised", collected: "2026-09-13") + "\n## 摘要\n\n\(summary)\n\n## 正文\n\nRevised body.\n",
                      path: "A/Today.md", root: root)
        try writeNote(articleText("New arrival", collected: "2026-09-13T13:00:00+08:00"), path: "A/New.md", root: root)
        await restored.refreshNow()
        try requireState(restored.unseenCount(in: "A") == 1 && restored.unseenChangeCount == 1
                         && restored.visibleArticles.first(where: { $0.path == "A/Today.md" })?.summary == summary,
                         "A new article should be unread while edits to a previously read article update its preview without notifying again")
        restored.markUpdatesSeen(in: "A")
        try FileManager.default.moveItem(at: root.appendingPathComponent("A/Today.md"),
                                        to: root.appendingPathComponent("B/Moved.md"))
        await restored.refreshNow()
        try requireState(restored.unseenChangeCount == 0 && restored.unseenCount(in: "B") == 0,
                         "An observed move discarded a read article's acknowledgement")
        restored.stop()

        let afterMove = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { currentDate })
        defer { afterMove.stop() }
        await afterMove.restoreNow()
        try requireState(afterMove.todayArticles.contains { $0.path == "B/Moved.md" }
                         && afterMove.unseenChangeCount == 0,
                         "Restart lost the acknowledgement persisted after an observed article move")
        afterMove.setArticleRange(.lastSevenDays)
        currentDate = ISO8601DateFormatter().date(from: "2026-09-14T00:00:01+08:00")!
        afterMove.refreshToday()
        try requireState(afterMove.todayArticles.isEmpty && afterMove.unseenChangeCount == 0
                         && afterMove.visibleArticles.count == 3,
                         "Crossing midnight must update both today's projection and the selected seven-day range")
        afterMove.setArticleRange(.yesterday)
        try requireState(Set(afterMove.visibleArticles.map(\.path)) == ["A/New.md", "B/Moved.md"]
                         && afterMove.unseenCount(in: "A") == 0 && afterMove.unseenCount(in: "B") == 0,
                         "Yesterday's previously read articles became unread after midnight")
        print("PASS persistent reading history: all ranges survive restart, new arrivals remain unread, edits stay read, observed moves persist and midnight retains acknowledgement")
    }

    private static func readingHistoryNotificationsAndRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-receipts-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-receipts-\(UUID().uuidString)"
        var currentDate = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00+08:00")!
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: root.appendingPathComponent("missing.json"),
                                          now: { currentDate })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let title = "Private article title"
        let path = "A/PrivateArticle.md"
        let body = "Private article body"
        try writeNote(articleText("Today", collected: "2026-09-13"), path: "A/Today.md", root: root)
        try writeNote(articleText(title, collected: "2026-09-12"), path: path, root: root)
        await model.selectVault(root)
        model.setArticleRange(.yesterday)
        var notifications = 0
        let observation = model.objectWillChange.sink { notifications += 1 }
        defer { observation.cancel() }
        model.markUpdatesSeen(in: "A")
        try requireState(model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 1 && notifications > 0,
                         "Acknowledging yesterday must notify the UI even when today's unread count and visible article content stay unchanged")
        try writeNote(articleText(title, collected: "2026-09-12") + "\n\(body)\n", path: path, root: root)
        await model.refreshNow()
        try requireState(model.unseenCount(in: "A") == 0 && model.unseenChangeCount == 1,
                         "Editing the body with the original collection date must retain acknowledgement")
        try writeNote(articleText(title, collected: "2026-09-13") + "\n\(body)\n", path: path, root: root)
        await model.refreshNow()
        model.setArticleRange(.today)
        try requireState(model.unseenCount(in: "A") == 2 && model.unseenChangeCount == 2,
                         "A new collection date at the same article path must count as a new unread collection")
        model.markUpdatesSeen(in: "A")

        let defaults = UserDefaults(suiteName: suite)!
        let receiptKey = "codexbar.knowledgeArticleReceipts"
        guard let receipts = defaults.dictionary(forKey: receiptKey), receipts.count == 2 else {
            throw stateError("Acknowledging two articles did not persist two reading receipts")
        }
        try requireState(receipts.allSatisfy { key, value in
            key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                && (value as? NSNumber)?.doubleValue.isFinite == true
        }, "Reading receipts must contain only lowercase SHA-256 keys and finite numeric timestamps")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: receipts), as: UTF8.self)
        try requireState(![root.path, path, title, body].contains(where: { serialized.contains($0) }),
                         "Reading receipts persisted a plaintext vault path, article path, title or body")
        currentDate = ISO8601DateFormatter().date(from: "2026-09-19T23:59:59+08:00")!
        model.refreshToday()
        try requireState(defaults.dictionary(forKey: receiptKey)?.count == 2,
                         "Reading receipts were pruned before their seventh Shanghai calendar day ended")
        currentDate = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00+08:00")!
        model.refreshToday()
        try requireState(defaults.dictionary(forKey: receiptKey)?.isEmpty == true,
                         "Reading receipts older than the seven-day window were not pruned on day refresh")
        print("PASS reading receipts: yesterday badge publishes updates, collection dates identify new arrivals, persisted metadata is private and seven-day retention follows Shanghai midnight")
    }

    private static func historicalAcknowledgementAtReceiptCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-receipt-capacity-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let suite = "codexbar-library-receipt-capacity-\(UUID().uuidString)"
        let registry = root.appendingPathComponent("missing.json")
        let now = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00+08:00")!
        let receiptKey = "codexbar.knowledgeArticleReceipts"
        let capacity = 10_000
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Dictionary(uniqueKeysWithValues: (0..<capacity).map {
            (String(format: "%064x", $0), now.timeIntervalSince1970)
        }), forKey: receiptKey)
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { now })
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote(articleText("Yesterday in another vault", collected: "2026-09-12"), path: "A/Yesterday.md", root: root)
        await model.selectVault(root)
        model.setArticleRange(.yesterday)
        try requireState(model.unseenCount(in: "A") == 1, "The capacity fixture did not expose an unread historical article")
        model.markUpdatesSeen(in: "A")
        try requireState(model.unseenCount(in: "A") == 0,
                         "A full receipt store discarded the just-acknowledged historical article because newer collections occupied capacity")
        try requireState((defaults.dictionary(forKey: receiptKey)?.count ?? 0) <= capacity,
                         "Acknowledging a historical article exceeded the receipt capacity")
        model.stop()

        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry, now: { now })
        defer { restored.stop() }
        await restored.restoreNow()
        restored.setArticleRange(.yesterday)
        try requireState(restored.visibleArticles.map(\.path) == ["A/Yesterday.md"] && restored.unseenCount(in: "A") == 0,
                         "Restart forgot the historical article acknowledged while the receipt store was full")
        print("PASS receipt capacity: historical acknowledgement remains read immediately and after restart without exceeding the storage bound")
    }

    private static func vaultReadingHistoryIsolation() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-isolation-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let firstRoot = parent.appendingPathComponent("First")
        let secondRoot = parent.appendingPathComponent("Second")
        let suite = "codexbar-library-isolation-\(UUID().uuidString)"
        let registry = parent.appendingPathComponent("missing.json")
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        for root in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
            try writeNote(articleText("Same relative path"), path: "A/Article.md", root: root)
        }
        await model.selectVault(firstRoot)
        model.markUpdatesSeen(in: "A")
        await model.selectVault(secondRoot)
        try requireState(model.unseenChangeCount == 1, "A different vault inherited read state from an identical relative article path")
        model.markUpdatesSeen(in: "A")
        await model.selectVault(firstRoot)
        try requireState(model.unseenChangeCount == 0, "Switching back to a previously visited vault forgot its read state")
        model.stop()

        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        defer { restored.stop() }
        await restored.restoreNow()
        try requireState(restored.review?.vault.rootPath == firstRoot.path && restored.unseenChangeCount == 0,
                         "Restart did not restore the selected vault and its own reading history")
        await restored.selectVault(secondRoot)
        try requireState(restored.unseenChangeCount == 0, "Restart discarded reading history for the other previously visited vault")
        print("PASS vault history isolation: identical paths remain independent and revisiting either vault preserves acknowledgement across restart")
    }

    private static func rootReplacedWhileStopped() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-library-offline-replacement-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("Vault")
        let suite = "codexbar-library-offline-replacement-\(UUID().uuidString)"
        let registry = parent.appendingPathComponent("missing.json")
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: parent)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let content = articleText("Same article metadata")
        try writeNote(content, path: "A/Article.md", root: root)
        await model.selectVault(root)
        model.markUpdatesSeen(in: "A")
        model.stop()
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("OldVault"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try writeNote(content, path: "A/Article.md", root: root)

        let restored = KnowledgeLibraryModel(defaultsSuiteName: suite, registryURL: registry)
        defer { restored.stop() }
        await restored.restoreNow()
        try requireState(restored.todayArticles.map(\.path) == ["A/Article.md"] && restored.unseenChangeCount == 1,
                         "A vault replaced while the app was stopped inherited the old directory's persisted read state")
        print("PASS stopped root replacement: identical article paths and metadata do not inherit the replaced directory's acknowledgement")
    }

    private static func requireState(_ condition: Bool, _ message: String) throws {
        guard condition else { throw stateError(message) }
    }

    private static func stateError(_ message: String) -> NSError {
        NSError(domain: "KnowledgeLibraryModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
