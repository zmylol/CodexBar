import Darwin
import Foundation
import CodexBarCore

@MainActor
func knowledgeFolderTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "knowledge folder publishes collected articles in its first baseline") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("""
                ---
                type: article
                source: https://example.com/agent-memory
                published: '2020-01-01'
                collected: '2026-09-11'
                title: Original English title
                ---
                # 把 Agent 会话变成可追溯记忆
                ## 摘要
                文章介绍如何记录 Agent 的执行过程，让团队能够回溯决策并复用会话中的经验。
                """, at: "Hugging Face/2020-01-01 - filename.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            let article = try require(snapshot.articles.first, "baseline did not expose collected article metadata")
            try expect(snapshot.changes.isEmpty && snapshot.articles.count == 1, "article inventory changed baseline semantics")
            try expect(article.title == "把 Agent 会话变成可追溯记忆"
                       && article.path == "Hugging Face/2020-01-01 - filename.md" && article.id == article.path,
                       "article title or current-path identity was incorrect")
            try expect(article.collectedAt == knowledgeCollectionDate(2026, 9, 11),
                       "published date or filesystem timestamp replaced the collection date")
            try expect(article.summary == "文章介绍如何记录 Agent 的执行过程，让团队能够回溯决策并复用会话中的经验。",
                       "first capture did not expose the article's own summary")
        },
        CodexBarTestCase(name: "knowledge folder leaves missing or empty article summaries absent") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let bodies = [
                "介绍正文，不应作为摘要。\n[返回首页](../index.md)",
                "## 摘要\n\n## 正文\n这里不是摘要。",
                "## 摘要\n<!-- 待补充 -->\n![封面](cover.png)\n\n## 正文\n正文",
                "```markdown\n## 摘要\n这是代码示例。\n```\n正文",
                "<!--\n## 摘要\n这是注释。\n-->\n正文"
            ]
            for (index, body) in bodies.enumerated() {
                try writeFolderNote(collectedArticle("无摘要 \(index)", on: "2026-09-11") + "\n" + body,
                                    at: "Notes/Empty-\(index).md", root: root)
            }
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.articles.count == bodies.count && snapshot.articles.allSatisfy { $0.summary == nil },
                       "missing summaries fell back to unrelated text, code, comments, or image labels")
        },
        CodexBarTestCase(name: "knowledge folder summarizes only the first paragraph of the named summary section") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let bodies: [(String, String, String)] = [
                ("Wrapped", "## 摘要\n\n第一行说明文章主题，\n第二行交代实践方法。\n\n第二段不应加入。", "第一行说明文章主题， 第二行交代实践方法。"),
                ("Boundary", "## 中文摘要\n这是文章摘要。\n### 实现细节\n这里不是摘要。", "这是文章摘要。"),
                ("English", "### sUmMaRy ###\nA practical guide to agent memory.\n## Details\nNot the summary.", "A practical guide to agent memory.")
            ]
            for (name, body, _) in bodies {
                try writeFolderNote(collectedArticle(name, on: "2026-09-11") + "\n" + body,
                                    at: "Notes/\(name).md", root: root)
            }
            let snapshot = try await folderTracker(root).capture()
            for (name, _, expected) in bodies {
                try expect(snapshot.articles.first { $0.title == name }?.summary == expected,
                           "summary wrapping or section boundary failed for \(name)")
            }
        },
        CodexBarTestCase(name: "knowledge folder preserves a wrapped summary paragraph with CRLF line endings") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let content = collectedArticle("跨平台摘要", on: "2026-09-11")
                + "\n## 摘要\n\n第一行概括文章主题，\n第二行说明核心结论。\n\n第二段不应加入。"
            try writeFolderNote(content.replacingOccurrences(of: "\n", with: "\r\n"),
                                at: "Notes/Windows.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.articles.first?.summary == "第一行概括文章主题， 第二行说明核心结论。",
                       "CRLF split a wrapped paragraph into separate paragraphs")
        },
        CodexBarTestCase(name: "knowledge folder ignores comments and fenced examples when locating article summaries") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let body = """
                ```markdown
                ## 摘要
                错误的示例。
                ```
                <!--
                ## 摘要
                错误的注释。
                -->
                ## 摘要
                <!-- 待整理的注释 -->
                ~~~markdown
                不应显示的示例内容。
                ~~~
                ![示意图](diagram.png)
                真正的摘要<!-- 内联注释 -->说明文章如何组织 Agent 的记忆。
                <!-- 另一个注释 -->
                同时保留后续回溯所需的上下文。
                """
            try writeFolderNote(collectedArticle("摘要定位", on: "2026-09-11") + "\n" + body,
                                at: "Notes/Summary.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.articles.first?.summary == "真正的摘要说明文章如何组织 Agent 的记忆。 同时保留后续回溯所需的上下文。",
                       "comments or fenced content leaked into the summary")
        },
        CodexBarTestCase(name: "knowledge folder displays article summaries as readable inline text") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let summary = "通过 **结构化记忆**、_任务回放_ 和 `agent_state`，使用 [示例项目](https://example.com/demo) 解释方法。"
            try writeFolderNote(collectedArticle("可读摘要", on: "2026-09-11") + "\n## 摘要\n" + summary,
                                at: "Notes/Inline.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.articles.first?.summary == "通过 结构化记忆、任务回放 和 agent_state，使用 示例项目 解释方法。",
                       "summary exposed Markdown markers or link destinations, or damaged code identifiers")
        },
        CodexBarTestCase(name: "knowledge folder caches article summaries and propagates later summary edits") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let prefix = collectedArticle("持续更新", on: "2026-09-11") + "\n## 摘要\n"
            try writeFolderNote(prefix + "介绍第一版方法。", at: "Notes/Updated.md", root: root)
            let tracker = folderTracker(root)
            let first = try await tracker.capture()
            let cached = try await tracker.capture()
            try expect(first.articles.first?.summary == "介绍第一版方法。" && cached.articles == first.articles
                       && cached.changes.isEmpty, "unchanged cached notes lost their summaries")
            let revised = String(repeating: "补充一段足够完整的说明，解释文章的方法和结论。", count: 12)
            try writeFolderNote(prefix + revised, at: "Notes/Updated.md", root: root)
            let edited = try await tracker.capture()
            try expect(edited.articles.first?.summary == revised, "edited summary was stale or silently truncated")
            try expect(edited.articles.first?.id == first.articles.first?.id
                       && edited.articles.first?.collectedAt == first.articles.first?.collectedAt,
                       "summary edit changed article identity or collection date")
        },
        CodexBarTestCase(name: "knowledge folder accumulates staggered article arrivals while preserving collection dates") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote(collectedArticle("旧文章", on: "2026-09-10"), at: "Anthropic/Old.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try writeFolderNote(collectedArticle("早间文章", on: "2026-09-11T09:40:00+08:00"),
                                at: "Hugging Face/Morning.md", root: root)
            let morning = try await tracker.capture()
            try expect(morning.articles.count == 2, "first scheduled arrival was not added to inventory")
            try writeFolderNote(collectedArticle("晚间文章", on: "2026-09-11T20:30:00+08:00"),
                                at: "Anthropic/Evening.md", root: root)
            try writeFolderNote(collectedArticle("旧文章修订", on: "2026-09-10") + "\n正文更新", at: "Anthropic/Old.md", root: root)
            let evening = try await tracker.capture()
            let today = evening.articles.filter {
                KnowledgeArticle.collectionCalendar.isDate($0.collectedAt, inSameDayAs: knowledgeCollectionDate(2026, 9, 11))
            }
            try expect(Set(today.map(\.title)) == ["早间文章", "晚间文章"], "later automation replaced the earlier batch or included an old edit")
            try expect(evening.articles.first { $0.path == "Anthropic/Old.md" }?.collectedAt == knowledgeCollectionDate(2026, 9, 10),
                       "editing an old article made its collection date today")
            let repeated = try await tracker.capture()
            try expect(repeated.articles == evening.articles && repeated.changes.isEmpty,
                       "unchanged cached notes lost metadata or repeated change events")
        },
        CodexBarTestCase(name: "knowledge folder article inventory follows moves and removes deleted articles") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote(collectedArticle("移动文章", on: "2026-09-11"), at: "Anthropic/Before.md", root: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Hugging Face"), withIntermediateDirectories: true)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root.appendingPathComponent("Anthropic/Before.md"),
                                            to: root.appendingPathComponent("Hugging Face/After.md"))
            let moved = try await tracker.capture()
            try expect(moved.articles.map(\.path) == ["Hugging Face/After.md"], "move left an article in its old knowledge library")
            try expect(moved.articles.first?.collectedAt == knowledgeCollectionDate(2026, 9, 11)
                       && moved.changes.first?.movePath == "Hugging Face/After.md", "move changed collection time or legacy change semantics")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Hugging Face/After.md"))
            let removed = try await tracker.capture()
            try expect(removed.articles.isEmpty && removed.changes.first?.kind == "delete", "deleted article remained in the inventory")
        },
        CodexBarTestCase(name: "knowledge folder indexes new articles and their later changes when body cache is full") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try fillFolderBodyCache(root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            let path = "Today/Article.md"
            let content = collectedArticle("今日新增", on: "2026-09-11") + "\n## 摘要\n第一版摘要。"
            try writeFolderNote(content, at: path, root: root)
            let added = try await tracker.capture()
            try expect(added.articles.first?.title == "今日新增" && added.articles.first?.summary == "第一版摘要。",
                       "full body cache hid a newly collected article or its summary")
            try expect(added.changes.isEmpty && !added.warnings.isEmpty,
                       "uncached article invented a body diff or lost its body-cache warning")
            let repeated = try await tracker.capture()
            try expect(repeated.articles == added.articles && repeated.changes.isEmpty && !repeated.warnings.isEmpty,
                       "unchanged uncached article repeated events, disappeared, or lost its cache warning")
            try writeFolderNote(content.replacingOccurrences(of: "第一版摘要", with: "第二版摘要"), at: path, root: root)
            let updated = try await tracker.capture()
            try expect(updated.articles.first?.summary == "第二版摘要。" && updated.changes.isEmpty,
                       "uncached article kept a stale summary or invented a body diff")
            try FileManager.default.moveItem(at: root.appendingPathComponent(path),
                                            to: root.appendingPathComponent("Today/Renamed.md"))
            let moved = try await tracker.capture()
            try expect(moved.articles.map(\.path) == ["Today/Renamed.md"] && moved.changes.isEmpty,
                       "uncached article rename left stale metadata or invented a body diff")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Today/Renamed.md"))
            let deleted = try await tracker.capture()
            try expect(deleted.articles.isEmpty && deleted.changes.isEmpty,
                       "uncached article deletion remained in the article index or invented a body diff")
        },
        CodexBarTestCase(name: "knowledge folder refreshes growing articles beyond the body budget and restores deferred diffs") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "Today/Article.md"
            let original = collectedArticle("原始标题", on: "2026-09-11")
            try fillFolderBodyCache(root, reserving: original.utf8.count)
            try writeFolderNote(original, at: path, root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            let revised = collectedArticle("更新标题", on: "2026-09-11") + "\n## 摘要\n增长后的正文仍应更新文章索引。"
            try writeFolderNote(revised, at: path, root: root)
            let grown = try await tracker.capture()
            try expect(grown.articles.first?.title == "更新标题" && grown.articles.first?.summary == "增长后的正文仍应更新文章索引。"
                       && grown.changes.isEmpty && !grown.warnings.isEmpty,
                       "body budget preserved stale article metadata or silently exceeded its limit")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Archive/Note-0.md"))
            let recovered = try await tracker.capture()
            try expect(recovered.articles == grown.articles
                       && recovered.changes.first { $0.path == path }?.diff?.contains("-# 原始标题") == true
                       && recovered.changes.first { $0.path == path }?.diff?.contains("+# 更新标题") == true,
                       "freed cache budget lost the last cached version of the deferred article edit")
            let repeated = try await tracker.capture()
            try expect(repeated.changes.isEmpty, "a recovered body cache repeated the same deferred edit")
            try writeFolderNote(revised + "\n正文补充。", at: path, root: root)
            let edited = try await tracker.capture()
            try expect(edited.changes.count == 1 && edited.changes.first?.diff?.contains("+正文补充。") == true,
                       "freed cache budget did not restore later full diff previews")
        },
        CodexBarTestCase(name: "knowledge folder bounds retained article titles and summaries independently of body content") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let title = String(repeating: "长标题", count: 1_000)
            let summary = String(repeating: "文章摘要内容。", count: 1_000)
            try writeFolderNote(collectedArticle(title, on: "2026-09-11") + "\n## 摘要\n" + summary,
                                at: "Notes/Long.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            let article = try require(snapshot.articles.first, "long metadata hid an otherwise valid article")
            try expect(article.title.utf8.count <= 1_024 && article.title.hasPrefix("长标题") && article.title.hasSuffix("…"),
                       "article index retained an unbounded title or damaged its Unicode text")
            try expect((article.summary?.utf8.count ?? 0) <= 4 * 1_024
                       && article.summary?.hasPrefix("文章摘要内容。") == true && article.summary?.hasSuffix("…") == true,
                       "article index retained an unbounded summary or did not indicate truncation")
        },
        CodexBarTestCase(name: "knowledge folder excludes templates indexes and invalid collection metadata") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let invalid = [
                "---\ntype: article\ncollected: ''\n---\n# 模板",
                "---\ntype: index\ncollected: '2026-09-11'\n---\n# 首页",
                "---\ntype: article\npublished: '2026-09-11'\n---\n# 只有发表日",
                "# 无属性\ncollected: 2026-09-11",
                "---\nproperties:\n  type: article\n  collected: '2026-09-11'\n---\n# 嵌套属性",
                "---\ntype: article\ncollected: '2026-09-11'\n# 未结束属性"
            ] + ["2026-02-30", "2025-02-29", "2026-9-11", "2026-09-11junk", "tomorrow", "2026-09-11T09:00:00",
                 "2026-02-30T09:00:00Z", "2026-09-11T25:00:00Z", "2026-09-11T09:60:00Z"].map {
                collectedArticle("无效日期", on: $0)
            }
            for (index, content) in invalid.enumerated() {
                try writeFolderNote(content, at: "Notes/Invalid-\(index).md", root: root)
            }
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.articles.isEmpty && snapshot.noteCount == invalid.count,
                       "nonarticles or malformed dates entered articles, or existing note inventory changed")
        },
        CodexBarTestCase(name: "knowledge folder collection dates respect explicit zones and Beijing day boundaries") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            for (path, date) in [
                ("DateOnly", "2026-09-11"),
                ("BeforeMidnight", "2026-09-10T15:59:59Z"),
                ("AtMidnight", "2026-09-10T16:00:00Z"),
                ("Fractional", "2026-09-10T16:00:00.125Z"),
                ("ExplicitOffset", "2026-09-10T09:00:00-07:00"),
                ("LeapDay", "2024-02-29")
            ] {
                try writeFolderNote(collectedArticle(path, on: date), at: "Notes/\(path).md", root: root)
            }
            let snapshot = try await folderTracker(root).capture()
            let byTitle = Dictionary(uniqueKeysWithValues: snapshot.articles.map { ($0.title, $0.collectedAt) })
            let midnight = knowledgeCollectionDate(2026, 9, 11)
            try expect(byTitle["DateOnly"] == midnight && byTitle["AtMidnight"] == midnight
                       && byTitle["ExplicitOffset"] == midnight, "collection dates used the machine timezone instead of Beijing")
            try expect(byTitle["BeforeMidnight"] == midnight.addingTimeInterval(-1)
                       && byTitle["Fractional"] == midnight.addingTimeInterval(0.125), "ISO collection timestamps lost timezone or precision")
            try expect(byTitle["LeapDay"] == knowledgeCollectionDate(2024, 2, 29), "valid leap day was rejected")
        },
        CodexBarTestCase(name: "knowledge folder article titles use frontmatter then filename without a heading") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("---\ntype: 'article'\ncollected: \"2026-09-11\"\ntitle: '标题：保留冒号'\n---\n正文",
                                at: "Notes/Original.md", root: root)
            try writeFolderNote("---\ntype: article\ncollected: 2026-09-11\n---\n正文", at: "Notes/回退标题.md", root: root)
            let snapshot = try await folderTracker(root).capture()
            try expect(Set(snapshot.articles.map(\.title)) == ["标题：保留冒号", "回退标题"], "article title fallback exposed a path or filename extension")
        },
        CodexBarTestCase(name: "knowledge folder starts with a baseline and emits only later note changes") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("before\n", at: "Nested/Note.md", root: root)
            let tracker = folderTracker(root)
            let baseline = try await tracker.capture()
            try expect(baseline.noteCount == 1 && baseline.changes.isEmpty, "existing notes became pending changes")
            try writeFolderNote("after\n", at: "Nested/Note.md", root: root)
            try writeFolderNote("new\n", at: "Nested/New.md", root: root)
            let changed = try await tracker.capture()
            try expect(changed.noteCount == 2 && changed.warnings.isEmpty, "note count or scan warnings incorrect")
            try expect(changed.changes.map(\.path) == ["Nested/New.md", "Nested/Note.md"], "nested edits not stable and relative")
            try expect(changed.changes.map(\.kind) == ["add", "update"], "wrong edit kinds")
            try expect(changed.changes[1].diff?.contains("-before") == true
                       && changed.changes[1].diff?.contains("+after") == true, "changed text missing from diff")
            try expect(changed.changes.allSatisfy { $0.status == "completed" && $0.diffFingerprint != nil }, "successful content versions missing")
            let repeated = try await tracker.capture()
            try expect(repeated.changes.isEmpty, "unchanged capture repeated events")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Nested/New.md"))
            let deleted = try await tracker.capture()
            try expect(deleted.changes.count == 1 && deleted.changes[0].kind == "delete"
                       && deleted.changes[0].diff?.contains("-new") == true, "deleted note was not captured")
        },
        CodexBarTestCase(name: "knowledge folder records a rename and changes review identity for each new edit") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("same\n", at: "Notes/Old.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root.appendingPathComponent("Notes/Old.md"), to: root.appendingPathComponent("Notes/New.md"))
            let moved = try await tracker.capture()
            try expect(moved.changes.count == 1 && moved.changes[0].path == "Notes/Old.md"
                       && moved.changes[0].movePath == "Notes/New.md", "inode-preserving rename became unrelated edits")
            try writeFolderNote("version two\n", at: "Notes/New.md", root: root)
            let edited = try await tracker.capture()
            try writeFolderNote("same\n", at: "Notes/New.md", root: root)
            let reverted = try await tracker.capture()
            try expect(edited.changes.count == 1 && reverted.changes.count == 1
                       && edited.changes[0].id != reverted.changes[0].id, "later content versions share a review identity")
        },
        CodexBarTestCase(name: "knowledge folder detects equal-length edits with restored modification times") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let note = root.appendingPathComponent("Notes/Note.md")
            try writeFolderNote("before", at: "Notes/Note.md", root: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: note.path)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try writeFolderNote("after!", at: "Notes/Note.md", root: root)
            try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: note.path)
            let snapshot = try await tracker.capture()
            try expect(snapshot.changes.count == 1, "content edit was hidden by identical size and modification time")
        },
        CodexBarTestCase(name: "knowledge folder excludes hidden data symlink notes and symlink directories") {
            let root = try knowledgeFolderFixture()
            let outside = try knowledgeFolderFixture()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            try writeFolderNote("visible", at: "Notes/Note.md", root: root)
            for path in [".obsidian/private.md", ".trash/deleted.md", "Notes/.hidden.md", "Notes/image.png"] {
                try writeFolderNote("excluded", at: path, root: root)
            }
            try writeFolderNote("outside", at: "Private.md", root: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Notes/Linked.md"),
                withDestinationURL: outside.appendingPathComponent("Private.md"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LinkedFolder"), withDestinationURL: outside)
            let snapshot = try await folderTracker(root).capture()
            try expect(snapshot.noteCount == 1 && snapshot.changes.isEmpty, "hidden or external notes entered the baseline")
        },
        CodexBarTestCase(name: "knowledge folder rejects missing and symlink roots without inventing deletions") {
            let root = try knowledgeFolderFixture()
            let movedRoot = root.appendingPathExtension("moved")
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: movedRoot)
            }
            try writeFolderNote("retained", at: "Notes/Note.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root, to: movedRoot)
            var rejected = false
            do { _ = try await tracker.capture() } catch { rejected = true }
            try expect(rejected, "missing root was treated as an empty vault")
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: movedRoot)
            rejected = false
            do { _ = try await tracker.capture() } catch { rejected = true }
            try expect(rejected, "root symlink was followed")
            try FileManager.default.removeItem(at: root)
            try FileManager.default.moveItem(at: movedRoot, to: root)
            let recovered = try await tracker.capture()
            try expect(recovered.noteCount == 1 && recovered.changes.isEmpty, "failed capture damaged the baseline")
        },
        CodexBarTestCase(name: "knowledge folder rebaselines a replaced root without reporting deleted notes") {
            let root = try knowledgeFolderFixture()
            let movedRoot = root.appendingPathExtension("moved")
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: movedRoot)
            }
            try writeFolderNote(collectedArticle("原目录文章", on: "2026-09-11"), at: "Original/Note.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let replaced = try await tracker.capture()
            try expect(replaced.noteCount == 0 && replaced.changes.isEmpty
                       && replaced.articles.isEmpty && replaced.sections.isEmpty,
                       "replacement root inherited old articles, sections, or reported their deletion")
            try expect(replaced.warnings.contains { $0.contains("文件夹已替换") },
                       "root identity change silently reset the baseline")
            try writeFolderNote(collectedArticle("新目录文章", on: "2026-09-11"), at: "New/Note.md", root: root)
            let added = try await tracker.capture()
            try expect(added.changes.count == 1 && added.changes.first?.kind == "add"
                       && added.articles.first?.title == "新目录文章" && added.warnings.isEmpty,
                       "replacement root failed to track later changes or repeated its replacement warning")
        },
        CodexBarTestCase(name: "knowledge folder preserves the original root baseline when a replacement scan fails") {
            let root = try knowledgeFolderFixture()
            let movedRoot = root.appendingPathExtension("moved")
            let unreadable = root.appendingPathComponent("Unreadable")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: movedRoot)
            }
            let original = collectedArticle("原目录文章", on: "2026-09-11")
            try writeFolderNote(original, at: "Original/Note.md", root: root)
            let tracker = folderTracker(root)
            let baseline = try await tracker.capture()
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            var rejected = false
            do { _ = try await tracker.capture() } catch { rejected = true }
            try expect(rejected, "unreadable replacement root was accepted as a new baseline")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
            try FileManager.default.removeItem(at: root)
            try FileManager.default.moveItem(at: movedRoot, to: root)
            try writeFolderNote(original + "\n原目录的新内容。", at: "Original/Note.md", root: root)
            let recovered = try await tracker.capture()
            try expect(recovered.changes.count == 1 && recovered.changes.first?.kind == "update"
                       && recovered.changes.first?.diff?.contains("+原目录的新内容。") == true
                       && recovered.articles == baseline.articles && recovered.warnings.isEmpty,
                       "failed replacement scan discarded or relabeled the original baseline")
        },
        CodexBarTestCase(name: "knowledge folder reports oversized notes without false deletion and recovers later") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("before", at: "Notes/Note.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try writeFolderNote(String(repeating: "x", count: KnowledgeFolderTracker.maximumNoteBytes + 1), at: "Notes/Note.md", root: root)
            let oversized = try await tracker.capture()
            try expect(!oversized.warnings.isEmpty && oversized.changes.isEmpty, "oversized note was read or removed")
            try writeFolderNote("after", at: "Notes/Note.md", root: root)
            let recovered = try await tracker.capture()
            try expect(recovered.changes.count == 1 && recovered.changes[0].kind == "update"
                       && recovered.changes[0].diff?.contains("-before") == true, "size-limit recovery lost previous content")
        },
        CodexBarTestCase(name: "knowledge folder retains its baseline when a nested directory becomes unreadable") {
            let root = try knowledgeFolderFixture()
            let nested = root.appendingPathComponent("Nested")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
                try? FileManager.default.removeItem(at: root)
            }
            try writeFolderNote("before", at: "Nested/Note.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: nested.path)
            var rejected = false
            do { _ = try await tracker.capture() } catch { rejected = true }
            try expect(rejected, "unreadable directory was treated as empty")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
            try writeFolderNote("after", at: "Nested/Note.md", root: root)
            let recovered = try await tracker.capture()
            try expect(recovered.changes.count == 1 && recovered.changes[0].diff?.contains("-before") == true,
                       "permissions failure destroyed the retained baseline")
        },
        CodexBarTestCase(name: "knowledge folder bounds enumeration and does not delete notes after a partial scan") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("retained", at: "Notes/Before.md", root: root)
            try writeFolderNote("nested", at: "Existing/Note.md", root: root)
            let tracker = folderTracker(root)
            let baseline = try await tracker.capture()
            try FileManager.default.removeItem(at: root.appendingPathComponent("Notes/Before.md"))
            for index in 0...KnowledgeFolderTracker.maximumNotes {
                try Data().write(to: root.appendingPathComponent("Notes/Note-\(index).md"))
            }
            let partial = try await tracker.capture()
            try expect(partial.noteCount <= KnowledgeFolderTracker.maximumNotes && !partial.warnings.isEmpty,
                       "enumeration limit was not surfaced")
            try expect(!partial.changes.contains { $0.kind == "delete" }, "partial inventory invented a deletion")
            for section in baseline.sections {
                try expect(partial.sections.contains(section), "partial inventory removed or altered previous section metadata")
            }
        },
        CodexBarTestCase(name: "knowledge folder sections include empty first-level directories and recursive note counts") {
            let root = try knowledgeFolderFixture()
            let outside = try knowledgeFolderFixture()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            try writeFolderNote("one", at: "Projects/One.md", root: root)
            try writeFolderNote("two", at: "Projects/Nested/Two.md", root: root)
            try writeFolderNote("root", at: "Root.md", root: root)
            try writeFolderNote("hidden", at: ".private/Hidden.md", root: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: outside)
            let tracker = folderTracker(root)
            let initial = try await tracker.capture()
            try expect(initial.sections == [
                KnowledgeFolderSection(relativePath: "Empty", name: "Empty", noteCount: 0),
                KnowledgeFolderSection(relativePath: "Projects", name: "Projects", noteCount: 2)
            ], "first-level sections omitted empty directories or counted hidden/symlink folders")
            try expect(initial.noteCount == 2 && initial.sections.map(\.id) == ["Empty", "Projects"],
                       "root notes entered the count or section IDs do not match first-level folders")
            try FileManager.default.moveItem(at: root.appendingPathComponent("Projects/Nested/Two.md"),
                                            to: root.appendingPathComponent("Empty/Two.md"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("Root.md"))
            try FileManager.default.moveItem(at: root.appendingPathComponent("Empty"), to: root.appendingPathComponent("Archive"))
            let updated = try await tracker.capture()
            try expect(updated.sections == [
                KnowledgeFolderSection(relativePath: "Archive", name: "Archive", noteCount: 1),
                KnowledgeFolderSection(relativePath: "Projects", name: "Projects", noteCount: 1)
            ], "sections did not follow directory renames or recalculate recursive counts")
        },
        CodexBarTestCase(name: "knowledge folder has no sections or notes without visible first-level directories") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let tracker = folderTracker(root)
            let empty = try await tracker.capture()
            try expect(empty.sections.isEmpty && empty.noteCount == 0 && empty.changes.isEmpty,
                       "empty vault invented a root section")
            try writeFolderNote("root note", at: "Root.md", root: root)
            let withNote = try await tracker.capture()
            try expect(withNote.sections.isEmpty && withNote.noteCount == 0 && withNote.changes.isEmpty,
                       "root-only vault tracked a root note")
        },
        CodexBarTestCase(name: "knowledge folder ignores root note additions edits and deletions while tracking nested notes") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("root before", at: "Root.md", root: root)
            try writeFolderNote("nested before", at: "Notes/Deep/Note.md", root: root)
            let tracker = folderTracker(root)
            let baseline = try await tracker.capture()
            try expect(baseline.noteCount == 1 && baseline.changes.isEmpty, "root note entered the initial baseline")
            try writeFolderNote("root after", at: "Root.md", root: root)
            try writeFolderNote("new root", at: "New.md", root: root)
            try writeFolderNote("nested after", at: "Notes/Deep/Note.md", root: root)
            let updated = try await tracker.capture()
            try expect(updated.noteCount == 1 && updated.changes.count == 1
                       && updated.changes[0].path == "Notes/Deep/Note.md"
                       && updated.changes[0].kind == "update", "root changes entered updates or nested edit was missed")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Root.md"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("New.md"))
            let deleted = try await tracker.capture()
            try expect(deleted.noteCount == 1 && deleted.changes.isEmpty, "root note deletion became a tracked change")
        },
        CodexBarTestCase(name: "knowledge folder treats moves across the root boundary as entering or leaving tracking") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("moved note", at: "Root.md", root: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root.appendingPathComponent("Root.md"),
                                            to: root.appendingPathComponent("Notes/Note.md"))
            let movedIn = try await tracker.capture()
            try expect(movedIn.noteCount == 1 && movedIn.changes.count == 1
                       && movedIn.changes[0].path == "Notes/Note.md" && movedIn.changes[0].kind == "add"
                       && movedIn.changes[0].movePath == nil, "moving a root note into a folder did not add a tracked note")
            try FileManager.default.moveItem(at: root.appendingPathComponent("Notes/Note.md"),
                                            to: root.appendingPathComponent("Root.md"))
            let movedOut = try await tracker.capture()
            try expect(movedOut.noteCount == 0 && movedOut.changes.count == 1
                       && movedOut.changes[0].path == "Notes/Note.md" && movedOut.changes[0].kind == "delete"
                       && movedOut.changes[0].movePath == nil, "moving a note to the root did not remove it from tracking")
            try expect(movedOut.sections == [KnowledgeFolderSection(relativePath: "Notes", name: "Notes", noteCount: 0)],
                       "moving the last note out removed its empty folder section")
        },
        CodexBarTestCase(name: "knowledge folder does not infer renames from ambiguous hard links") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("linked", at: "Notes/One.md", root: root)
            try FileManager.default.linkItem(at: root.appendingPathComponent("Notes/One.md"), to: root.appendingPathComponent("Notes/Two.md"))
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try FileManager.default.moveItem(at: root.appendingPathComponent("Notes/One.md"), to: root.appendingPathComponent("Notes/Three.md"))
            let snapshot = try await tracker.capture()
            try expect(snapshot.changes.count == 2 && snapshot.changes.allSatisfy { $0.movePath == nil },
                       "ambiguous inode was reported as a certain rename")
        },
        CodexBarTestCase(name: "knowledge folder bounds large line diffs while keeping content fingerprints") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote(String(repeating: "old\n", count: 8_000), at: "Notes/Note.md", root: root)
            let tracker = folderTracker(root)
            _ = try await tracker.capture()
            try writeFolderNote(String(repeating: "new\n", count: 8_000), at: "Notes/Note.md", root: root)
            let snapshot = try await tracker.capture()
            let change = try require(snapshot.changes.first, "large change missing")
            try expect((change.diff?.utf8.count ?? 0) <= KnowledgeFolderTracker.maximumDiffBytes,
                       "diff exceeded its output bound")
            try expect(change.diff?.contains("+new") == true && change.diffFingerprint?.count == 64,
                       "bounded diff lost changed text or content fingerprint")
        },
        CodexBarTestCase(name: "knowledge folder monitor observes nested writes and stops pending callbacks") {
            let root = try knowledgeFolderFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFolderNote("before", at: "Nested/Deep/Note.md", root: root)
            let monitor = KnowledgeFolderMonitor()
            let changes = FolderMonitorChanges()
            try monitor.start(root: root) { changes.count += 1 }
            defer { monitor.stop() }
            try await Task.sleep(for: .milliseconds(400))
            let baseline = changes.count
            try writeFolderNote("after", at: "Nested/Deep/Note.md", root: root)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while changes.count <= baseline && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try expect(changes.count > baseline, "recursive filesystem write did not reach the monitor")
            monitor.stop()
            let stopped = changes.count
            try writeFolderNote("later", at: "Nested/Deep/Note.md", root: root)
            try await Task.sleep(for: .milliseconds(500))
            try expect(changes.count == stopped, "stopped monitor delivered a callback")
            let newChanges = FolderMonitorChanges()
            try monitor.start(root: root) { newChanges.count += 1 }
            try writeFolderNote("pending", at: "Nested/Deep/Note.md", root: root)
            monitor.stop()
            try await Task.sleep(for: .milliseconds(500))
            try expect(newChanges.count == 0, "stop did not cancel pending delivery after restart")
        }
    ]
}

private func knowledgeFolderFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarKnowledgeFolder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    return root
}

private func folderTracker(_ root: URL) -> KnowledgeFolderTracker {
    KnowledgeFolderTracker(vault: ObsidianVault(rootPath: root.path, name: root.lastPathComponent))
}

private func writeFolderNote(_ text: String, at path: String, root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func fillFolderBodyCache(_ root: URL, reserving reservedBytes: Int = 0) throws {
    let fullNoteCount = KnowledgeFolderTracker.maximumContentBytes / KnowledgeFolderTracker.maximumNoteBytes
    let fullContent = String(repeating: "x", count: KnowledgeFolderTracker.maximumNoteBytes)
    for index in 0..<fullNoteCount {
        let content = index == fullNoteCount - 1 ? String(fullContent.dropLast(reservedBytes)) : fullContent
        try writeFolderNote(content, at: "Archive/Note-\(index).md", root: root)
    }
}

private func collectedArticle(_ title: String, on date: String) -> String {
    "---\ntype: article\ncollected: '\(date)'\n---\n# \(title)"
}

private func knowledgeCollectionDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@MainActor
private final class FolderMonitorChanges {
    var count = 0
}
