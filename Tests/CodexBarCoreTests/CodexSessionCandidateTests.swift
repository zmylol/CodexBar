import CodexBarCore
import Darwin
import Foundation

@MainActor
func codexSessionCandidateTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "session candidate reads only exact VS Code session metadata") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            try fixture.write(try fixture.metadata(source: "vscode") + Data([10, 0xFF, 0, 0xFE]))
            try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .candidate(
                CodexSessionCandidate(sessionID: "candidate-session", cwd: fixture.cwd)
            ), "Valid first-line metadata was rejected or later bytes were parsed")
        },
        CodexBarTestCase(name: "session candidate waits for empty or incomplete first lines") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            let reader = CodexSessionCandidateReader()
            try fixture.write(Data())
            try expect(reader.read(at: fixture.rollout) == .pending, "Empty creation cannot be excluded yet")
            try fixture.write(Data("{\"type\":\"session_meta\"".utf8))
            try expect(reader.read(at: fixture.rollout) == .pending, "Partial writes cannot be excluded yet")
            let complete = try fixture.metadata(source: "vscode")
            try fixture.write(complete)
            try expect(reader.read(at: fixture.rollout) == .pending, "Missing line terminator is still pending")
            try fixture.write(complete + Data([10]))
            try expect(reader.read(at: fixture.rollout) == .candidate(
                CodexSessionCandidate(sessionID: "candidate-session", cwd: fixture.cwd)
            ), "Completed metadata remained pending")
        },
        CodexBarTestCase(name: "session candidate excludes CLI subagents and originator-only guesses") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            for source: Any in ["cli", "exec", "VSCode", "vscode ", NSNull(), ["subagent": "review"]] {
                try fixture.write(try fixture.metadata(source: source) + Data([10]))
                try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .ignored,
                           "Non-exact source was treated as a VS Code session")
            }
            try fixture.write(try JSONSerialization.data(withJSONObject: [
                "type": "session_meta", "payload": [
                    "id": "candidate-session", "cwd": fixture.root.path, "originator": "codex_vscode"
                ]
            ]) + Data([10]))
            try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .ignored,
                       "Originator was used to guess missing source")
        },
        CodexBarTestCase(name: "session candidate rejects malformed metadata and invalid identities") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            let invalidMetadata: [Data] = [
                Data("not json\n".utf8), Data("{}\n".utf8),
                try fixture.metadata(source: "vscode", type: "event_msg") + Data([10]),
                try fixture.metadata(source: "vscode", id: " ") + Data([10]),
                try fixture.metadata(source: "vscode", id: String(repeating: "x", count: 513)) + Data([10]),
                try fixture.metadata(source: "vscode", cwd: "relative/path") + Data([10]),
                try fixture.metadata(source: "vscode", cwd: "/") + Data([10])
            ]
            for data in invalidMetadata {
                try fixture.write(data)
                try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .ignored,
                           "Complete invalid metadata was retained as a candidate")
            }
        },
        CodexBarTestCase(name: "session candidate first line has a strict 64 KiB read budget") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            let metadata = try fixture.metadata(source: "vscode")
            try fixture.write(metadata + Data(repeating: 32, count: 65_535 - metadata.count) + Data([10]))
            try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .candidate(
                CodexSessionCandidate(sessionID: "candidate-session", cwd: fixture.cwd)
            ), "First line at the byte budget was rejected")
            try fixture.write(metadata + Data(repeating: 32, count: 65_536 - metadata.count) + Data([10]))
            try expect(CodexSessionCandidateReader().read(at: fixture.rollout) == .ignored,
                       "Reader crossed its first-line byte budget")
        },
        CodexBarTestCase(name: "session candidate never follows symlinks or opens nonregular content") {
            let fixture = try SessionCandidateFixture()
            defer { fixture.remove() }
            try fixture.write(try fixture.metadata(source: "vscode") + Data([10]))
            let alias = fixture.root.appendingPathComponent("alias.jsonl")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.rollout)
            try expect(CodexSessionCandidateReader().read(at: alias) == .ignored, "Rollout symlink was followed")
            let directoryAlias = fixture.root.appendingPathComponent("directory-alias")
            try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: fixture.root)
            try expect(CodexSessionCandidateReader().read(at: directoryAlias.appendingPathComponent("rollout.jsonl")) == .ignored,
                       "Ancestor symlink was followed")
            try expect(CodexSessionCandidateReader().read(at: fixture.root) == .ignored, "Directory was treated as metadata")
            let fifo = fixture.root.appendingPathComponent("fifo.jsonl")
            try expect(mkfifo(fifo.path, 0o600) == 0, "Unable to create FIFO fixture")
            try expect(CodexSessionCandidateReader().read(at: fifo) == .ignored, "FIFO was read or blocked")
        }
    ]
}

private struct SessionCandidateFixture {
    let root: URL
    var rollout: URL { root.appendingPathComponent("rollout.jsonl") }
    var cwd: String { root.resolvingSymlinksInPath().path }

    init() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("session-candidate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
    }

    func metadata(source: Any, id: String = "candidate-session", cwd: String? = nil, type: String = "session_meta") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": type, "payload": ["id": id, "cwd": cwd ?? root.path, "source": source, "originator": "codex_vscode"]
        ])
    }

    func write(_ data: Data) throws { try data.write(to: rollout) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
