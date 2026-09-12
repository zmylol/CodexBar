import CodexBarCore
import Foundation

@MainActor
func knowledgeReviewTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "knowledge vault discovery walks ancestors without scanning notes") {
            try withKnowledgeVault { root, vault in
                let nested = root.appendingPathComponent("阅读/收件箱")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                try expect(ObsidianVault.discover(cwd: nested.path) == vault, "nested workspace missed vault")
                try expect(ObsidianVault.discover(cwd: root.deletingLastPathComponent().path) == nil,
                           "parent workspace incorrectly scanned child vaults")
            }
        },
        CodexBarTestCase(name: "knowledge note paths reject traversal hidden files and escaping symlinks") {
            try withKnowledgeVault { root, vault in
                for path in ["../outside.md", ".obsidian/settings.md", ".trash/deleted.md", "file.txt", "https://example.com/note.md", "bad\nname.md"] {
                    try expect(vault.notePath(path, cwd: root.path) == nil, "unsafe note accepted: \(path)")
                }
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                    withDestinationURL: root.deletingLastPathComponent())
                try expect(vault.notePath("escape/outside.md", cwd: root.path) == nil, "symlink escaped vault")
                try expect(vault.notePath("笔记 & 问题 #1.md", cwd: root.path) == "笔记 & 问题 #1.md", "valid unicode note rejected")
            }
        },
        CodexBarTestCase(name: "knowledge Obsidian URL encodes exact note path without creating notes") {
            try withKnowledgeVault { root, vault in
                let relative = "主题/问题 #1 & 2?.md"
                let url = try require(vault.openURL(notePath: relative), "missing open URL")
                let parts = try require(URLComponents(url: url, resolvingAgainstBaseURL: false), "bad URL")
                try expect(parts.scheme == "obsidian" && parts.host == "open", "wrong action")
                try expect(parts.queryItems == [URLQueryItem(name: "path", value: root.appendingPathComponent(relative).path)],
                           "path encoding lost punctuation")
                try expect(vault.openURL(notePath: "../outside.md") == nil, "open escaped vault")
            }
        },
        CodexBarTestCase(name: "knowledge review deduplicates notes and ignores repeated revisions") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let changes = [knowledgeChange("a", path: "One.md", diff: "-a\n+b"),
                               knowledgeChange("b", path: "One.md", diff: "-b\n+c")]
                ledger.receive(changes, cwd: root.path)
                try expect(ledger.notes.count == 1 && ledger.pendingCount == 1, "counted operations instead of notes")
                let note = try require(ledger.notes.first, "missing note")
                try expect(note.diff == "-b\n+c", "latest recorded diff missing")
                ledger.toggleReview(noteID: note.id)
                ledger.receive(changes, cwd: root.path)
                try expect(ledger.pendingCount == 0, "same content reset review")
                ledger.receive([knowledgeChange("c", path: "One.md", diff: "-c\n+d", turn: "next")], cwd: root.path)
                try expect(ledger.pendingCount == 1, "next turn failed to reopen review")
            }
        },
        CodexBarTestCase(name: "knowledge review reopens corrected diff and retains unreviewed notes across turns") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                ledger.receive([knowledgeChange("a", path: "One.md", diff: "first")], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing note").id)
                ledger.receive([knowledgeChange("a", path: "One.md", diff: "corrected")], cwd: root.path)
                ledger.receive([knowledgeChange("b", path: "Two.md", diff: "new", turn: "next")], cwd: root.path)
                try expect(ledger.pendingCount == 2, "pending result was lost or changed diff stayed reviewed")
            }
        },
        CodexBarTestCase(name: "knowledge moves use destination and deleted notes remain reviewable") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                ledger.receive([knowledgeChange("a", path: "Inbox.md", diff: "new")], cwd: root.path)
                ledger.receive([knowledgeChange("b", path: "Inbox.md", diff: "", movePath: "主题/Inbox.md")], cwd: root.path)
                let note = try require(ledger.notes.first, "missing moved note")
                try expect(ledger.notes.count == 1 && note.path == "主题/Inbox.md" && note.previousPath == "Inbox.md" && note.kind == "move", "move duplicated or opened source")
                ledger.receive([knowledgeChange("c", path: "主题/Inbox.md", diff: "-gone", kind: "delete")], cwd: root.path)
                try expect(ledger.notes.first?.kind == "delete" && ledger.pendingCount == 1, "deleted note lost review")
            }
        },
        CodexBarTestCase(name: "knowledge review rejects failed edits and unrelated file paths") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                ledger.receive([knowledgeChange("a", path: "Good.md", diff: "", status: "failed"),
                                knowledgeChange("b", path: "../Other.md", diff: ""),
                                knowledgeChange("c", path: "App.swift", diff: "")], cwd: root.path)
                try expect(ledger.notes.isEmpty, "non-note or failed edit created pending review")
            }
        },
        CodexBarTestCase(name: "knowledge review receipts persist no paths or note contents") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let change = knowledgeChange("a", path: "Private.md", diff: "SECRET_NOTE_TEXT")
                ledger.receive([change], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing note").id)
                let receipts = ledger.reviewedVersions
                try expect(receipts.count == 1 && receipts.allSatisfy { $0.count == 64 }, "receipts not bounded fingerprints")
                var restored = KnowledgeReviewLedger(vault: vault, reviewedVersions: receipts)
                restored.receive([change], cwd: root.path)
                try expect(restored.pendingCount == 0, "review receipt did not survive restoration")
                try expect(!receipts.joined().contains("Private") && !receipts.joined().contains("SECRET"), "receipt exposed note content")
            }
        },
        CodexBarTestCase(name: "knowledge review keeps newest edit when older history is filled in") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let first = knowledgeChange("a", path: "One.md", diff: "first")
                let middle = knowledgeChange("b", path: "One.md", diff: "middle")
                let last = knowledgeChange("c", path: "One.md", diff: "last")
                ledger.receive([first, last], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing note").id)
                ledger.receive([first, middle, last], cwd: root.path)
                try expect(ledger.notes.first?.diff == "last" && ledger.pendingCount == 0, "old history replaced latest review")
            }
        },
        CodexBarTestCase(name: "knowledge review tracks changed versions even when large diffs are omitted") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                func change(_ fingerprint: String) -> CodexRecordedFileChange {
                    CodexRecordedFileChange(id: "a", turnID: "turn", itemID: "a", path: "Large.md",
                        kind: "update", movePath: nil, diff: nil, status: "completed", diffFingerprint: fingerprint)
                }
                ledger.receive([change("first")], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing note").id)
                ledger.receive([change("second")], cwd: root.path)
                try expect(ledger.pendingCount == 1, "omitted diff hid a changed version")
            }
        },
        CodexBarTestCase(name: "knowledge recent notes follow changes and promote edited notes without duplicates") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                try expect(ledger.recentNotes.isEmpty, "empty ledger has recent notes")
                ledger.receiveLatest([
                    knowledgeChange("first", path: "Middle.md", diff: "first", kind: "add"),
                    knowledgeChange("second", path: "Alpha.md", diff: "second", kind: "add"),
                    knowledgeChange("third", path: "Zulu.md", diff: "third", kind: "add")
                ], cwd: root.path)
                try expect(ledger.recentNotes.map(\.path) == ["Zulu.md", "Alpha.md", "Middle.md"],
                           "recent notes followed paths instead of change order")
                ledger.receiveLatest([knowledgeChange("edited", path: "Middle.md", diff: "revised")], cwd: root.path)
                try expect(ledger.recentNotes.map(\.path) == ["Middle.md", "Zulu.md", "Alpha.md"]
                           && ledger.recentNotes.first?.diff == "revised", "edited note was duplicated or not promoted")
                try expect(ledger.notes.map(\.path) == ["Alpha.md", "Middle.md", "Zulu.md"],
                           "recent ordering changed the review list's alphabetical order")
            }
        },
        CodexBarTestCase(name: "knowledge recent notes keep order across repeated delivery and review changes") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let older = knowledgeChange("older", path: "Alpha.md", diff: "older")
                let newer = knowledgeChange("newer", path: "Zulu.md", diff: "newer")
                ledger.receiveLatest([older, newer], cwd: root.path)
                let expected = ledger.recentNotes
                ledger.receiveLatest([older], cwd: root.path)
                ledger.receiveLatest([], cwd: root.path)
                try expect(ledger.recentNotes == expected, "repeated delivery promoted an unchanged note")
                let reviewed = try require(ledger.recentNotes.last, "missing older note")
                ledger.toggleReview(noteID: reviewed.id)
                try expect(ledger.recentNotes.map(\.path) == expected.map(\.path)
                           && ledger.recentNotes.last?.isReviewed == true, "reviewing reordered recent notes or left stale state")
                ledger.toggleReview(noteID: reviewed.id)
                try expect(ledger.recentNotes == expected, "undoing review changed recent notes")
            }
        },
        CodexBarTestCase(name: "knowledge recent notes retain only moved destinations after repeated path edits") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                ledger.receive([
                    knowledgeChange("original", path: "Inbox/Note.md", diff: "original"),
                    knowledgeChange("other", path: "Other.md", diff: "other"),
                    knowledgeChange("edited", path: "Inbox/Note.md", diff: "revised")
                ], cwd: root.path)
                try expect(ledger.recentNotes.map(\.path) == ["Inbox/Note.md", "Other.md"],
                           "recent notes used the first edit position or duplicated historical edits")
                ledger.receiveLatest([
                    knowledgeChange("moved", path: "Inbox/Note.md", diff: "revised", movePath: "Topics/Note.md")
                ], cwd: root.path)
                try expect(ledger.recentNotes.map(\.path) == ["Topics/Note.md", "Other.md"]
                           && ledger.recentNotes.first?.previousPath == "Inbox/Note.md", "move retained the source path or lost its latest position")
            }
        },
        CodexBarTestCase(name: "knowledge folder review continues receiving after hundreds of edits to one note") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                for revision in 0...(KnowledgeReviewLedger.maximumRecords + 16) {
                    ledger.receiveLatest([knowledgeChange("edit-\(revision)", path: "One.md", diff: "version \(revision)")], cwd: root.path)
                }
                try expect(ledger.notes.count == 1 && ledger.pendingCount == 1, "one note accumulated obsolete edit records")
                try expect(ledger.notes[0].diff == "version \(KnowledgeReviewLedger.maximumRecords + 16)",
                           "folder stopped accepting new edits at the history capacity")
                try expect(!ledger.isTruncated, "replaced versions consumed the note capacity")
            }
        },
        CodexBarTestCase(name: "knowledge folder review replaces moved paths and reopens only changed versions") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let original = knowledgeChange("first", path: "Inbox.md", diff: "first")
                ledger.receiveLatest([original], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing original note").id)
                ledger.receiveLatest([original], cwd: root.path)
                try expect(ledger.pendingCount == 0 && ledger.reviewedVersions.count == 1, "repeated version reset review")
                ledger.receiveLatest([knowledgeChange("moved", path: "Inbox.md", diff: "first", movePath: "Notes/Inbox.md")], cwd: root.path)
                try expect(ledger.notes.count == 1 && ledger.notes[0].path == "Notes/Inbox.md"
                           && ledger.notes[0].previousPath == "Inbox.md" && ledger.pendingCount == 1, "move retained an old path or its review")
                try expect(ledger.reviewedVersions.isEmpty, "obsolete reviewed version was retained after moving")
                ledger.toggleReview(noteID: ledger.notes[0].id)
                ledger.receiveLatest([knowledgeChange("edited", path: "Notes/Inbox.md", diff: "second")], cwd: root.path)
                try expect(ledger.notes.count == 1 && ledger.notes[0].kind == "update"
                           && ledger.notes[0].previousPath == nil && ledger.pendingCount == 1, "new version kept obsolete move metadata")
                try expect(ledger.reviewedVersions.isEmpty, "old review receipts accumulated across edits")
            }
        },
        CodexBarTestCase(name: "knowledge folder review evicts oldest notes and keeps the newest edit at capacity") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let oldest = knowledgeChange("oldest", path: "Oldest.md", diff: "oldest")
                ledger.receiveLatest([oldest], cwd: root.path)
                ledger.toggleReview(noteID: try require(ledger.notes.first, "missing oldest note").id)
                let additions = (1...KnowledgeReviewLedger.maximumRecords).map {
                    knowledgeChange("note-\($0)", path: "Note-\($0).md", diff: "version \($0)")
                }
                ledger.receiveLatest(additions, cwd: root.path)
                try expect(ledger.notes.count == KnowledgeReviewLedger.maximumRecords && ledger.isTruncated,
                           "note capacity was not bounded or disclosed")
                try expect(!ledger.notes.contains { $0.path == "Oldest.md" }
                           && ledger.notes.contains { $0.path == "Note-\(KnowledgeReviewLedger.maximumRecords).md" },
                           "capacity rejected newest notes instead of evicting oldest")
                try expect(ledger.reviewedVersions.isEmpty, "evicted note retained its review receipt")
                ledger.receiveLatest([knowledgeChange("latest", path: "Fresh.md", diff: "fresh")], cwd: root.path)
                try expect(ledger.notes.contains { $0.path == "Fresh.md" }
                           && !ledger.notes.contains { $0.path == "Note-1.md" }, "truncation permanently froze later changes")
            }
        },
        CodexBarTestCase(name: "knowledge folder review evicts by byte budget while retaining recent diffs") {
            try withKnowledgeVault { root, vault in
                var ledger = KnowledgeReviewLedger(vault: vault)
                let large = String(repeating: "x", count: KnowledgeReviewLedger.maximumBytes / 2)
                ledger.receiveLatest([knowledgeChange("first", path: "First.md", diff: large)], cwd: root.path)
                ledger.receiveLatest([knowledgeChange("second", path: "Second.md", diff: large)], cwd: root.path)
                try expect(ledger.isTruncated && ledger.notes.count == 1
                           && ledger.notes[0].path == "Second.md" && ledger.notes[0].diff == large,
                           "byte capacity retained oldest content or rejected the newest change")
                ledger.receiveLatest([knowledgeChange("third", path: "Third.md", diff: "latest")], cwd: root.path)
                try expect(ledger.notes.count == 2 && ledger.notes.contains { $0.path == "Third.md" },
                           "byte truncation blocked later small changes")
            }
        }
    ]
}

@MainActor
private func withKnowledgeVault(_ body: (URL, ObsidianVault) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonicalRoot = root.resolvingSymlinksInPath()
    let vault = try require(ObsidianVault.discover(cwd: canonicalRoot.path), "vault not discovered")
    try body(canonicalRoot, vault)
}

private func knowledgeChange(_ id: String, path: String, diff: String, kind: String = "update",
                             movePath: String? = nil, turn: String = "turn", status: String = "completed") -> CodexRecordedFileChange {
    CodexRecordedFileChange(id: "\(turn):\(id)", turnID: turn, itemID: id, path: path,
                            kind: kind, movePath: movePath, diff: diff, status: status)
}
