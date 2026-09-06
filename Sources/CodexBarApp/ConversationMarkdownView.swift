import SwiftUI

/// Small block layout around the system inline Markdown renderer; no HTML or remote resources.
struct ConversationMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(text):
                    inlineText(text)
                case let .heading(text, level):
                    inlineText(text)
                        .font(.system(size: level == 1 ? 15 : 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                case let .code(text, language):
                    VStack(alignment: .leading, spacing: 5) {
                        if !language.isEmpty {
                            Text(language)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .font(.system(size: 12))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inlineText(_ text: String) -> some View {
        Text((try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Block {
        case paragraph(String)
        case heading(String, Int)
        case code(String, String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var language = ""

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openingFence = fence {
                if trimmed.hasPrefix(openingFence) {
                    result.append(.code(code.joined(separator: "\n"), language))
                    code.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = trimmed.first!
                let delimiter = String(trimmed.prefix(while: { $0 == marker }))
                fence = delimiter
                language = String(trimmed.dropFirst(delimiter.count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(headingLevel), trimmed.dropFirst(headingLevel).first == " " {
                    flushParagraph()
                    result.append(.heading(String(trimmed.dropFirst(headingLevel + 1)), headingLevel))
                } else {
                    // Keep list markers and line breaks intact while rendering inline emphasis.
                    paragraph.append(line)
                }
            }
        }
        if fence != nil { result.append(.code(code.joined(separator: "\n"), language)) }
        flushParagraph()
        return result
    }
}
