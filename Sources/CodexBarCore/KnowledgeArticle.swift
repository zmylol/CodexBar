import Foundation

public struct KnowledgeArticle: Identifiable, Equatable, Sendable {
    public let path: String
    public let title: String
    public let collectedAt: Date
    public let summary: String?
    public var id: String { path }

    public static var collectionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    public init(path: String, title: String, collectedAt: Date, summary: String? = nil) {
        self.path = path
        self.title = title
        self.collectedAt = collectedAt
        self.summary = summary
    }

    /// Reads the automation's article metadata; filesystem and publication dates are unrelated to collection.
    init?(path: String, content: String) {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff} \t")) == "---",
              let end = lines.indices.dropFirst().first(where: {
                  let line = lines[$0].trimmingCharacters(in: .whitespaces)
                  return line == "---" || line == "..."
              }) else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard ["type", "collected", "title"].contains(key) else { continue }
            guard fields[key] == nil else { return nil }
            fields[key] = Self.scalar(String(line[line.index(after: colon)...]))
        }
        guard fields["type"] == "article", let collected = fields["collected"],
              let date = Self.collectionDate(collected) else { return nil }
        let heading = lines[(end + 1)...].lazy.compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("# ") || text.hasPrefix("#\t") else { return nil }
            let title = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }.first
        let metadataTitle = fields["title"].flatMap { $0.isEmpty ? nil : $0 }
        let filename = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        self.init(path: path, title: heading ?? metadataTitle ?? filename, collectedAt: date,
                  summary: Self.summary(in: lines[(end + 1)...]))
    }

    /// Uses the article's own summary rather than guessing from navigation or introductory text.
    private static func summary(in lines: ArraySlice<String>) -> String? {
        var inSummary = false
        var inComment = false
        var fence: (marker: Character, length: Int)?
        var paragraph: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                let run = trimmed.prefix { $0 == activeFence.marker }.count
                if run >= activeFence.length && trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            let wasInComment = inComment
            let text = removingComments(from: line, inComment: &inComment).trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if !paragraph.isEmpty && trimmed.isEmpty && !wasInComment { break }
                continue
            }
            if let marker = text.first, marker == "`" || marker == "~" {
                let run = text.prefix { $0 == marker }.count
                if run >= 3 {
                    if !paragraph.isEmpty { break }
                    fence = (marker, run)
                    continue
                }
            }
            let hashes = text.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), text.dropFirst(hashes).first?.isWhitespace == true {
                if inSummary { break }
                let heading = text.dropFirst(hashes)
                    .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "#"))).lowercased()
                inSummary = ["摘要", "中文摘要", "summary"].contains(heading)
                continue
            }
            guard inSummary else { continue }
            let readable = inlineText(text)
            if !readable.isEmpty { paragraph.append(readable) }
        }
        return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
    }

    private static func removingComments(from line: String, inComment: inout Bool) -> String {
        var remaining = line[...]
        var result = ""
        while !remaining.isEmpty {
            if inComment {
                guard let end = remaining.range(of: "-->") else { break }
                remaining = remaining[end.upperBound...]
                inComment = false
            } else if let start = remaining.range(of: "<!--") {
                result += remaining[..<start.lowerBound]
                remaining = remaining[start.upperBound...]
                inComment = true
            } else {
                result += remaining
                break
            }
        }
        return result
    }

    private static func inlineText(_ text: String) -> String {
        let replacements = [
            (#"!\[[^\]]*\]\([^\n)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^\n)]*\)"#, "$1"),
            (#"`+([^`]+)`+"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<!\w)(\*|_)(.+?)\1(?!\w)"#, "$2")
        ]
        return replacements.reduce(text) { value, replacement in
            value.replacingOccurrences(of: replacement.0, with: replacement.1, options: .regularExpression)
        }.trimmingCharacters(in: .whitespaces)
    }

    private static func scalar(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            return decoded
        }
        if let comment = value.range(of: " #") {
            return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func collectionDate(_ value: String) -> Date? {
        let datePart = String(value.prefix(10))
        guard datePart.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let numbers = datePart.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        let calendar = collectionCalendar
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        if value.count == 10 { return date }
        let timestampPattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"
        guard value.range(of: timestampPattern, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
