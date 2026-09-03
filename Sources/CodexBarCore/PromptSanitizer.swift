import Foundation

public enum PromptSanitizer {
    public static func sanitize(_ prompt: String?, maxLength: Int = 80) -> String? {
        guard let prompt, maxLength > 0 else {
            return nil
        }

        let firstLine = prompt.components(separatedBy: .newlines).first ?? ""
        var summary = stripUnsafeControls(String(firstLine.prefix(4_096)))
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        guard !summary.isEmpty else {
            return nil
        }

        let assignments = #"(?i)\b(api[\s_-]?key|access[\s_-]?token|auth[\s_-]?token|password|passwd|secret|client[\s_-]?secret)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)"#
        summary = summary.replacingOccurrences(
            of: assignments,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )

        let bearerToken = #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#
        summary = summary.replacingOccurrences(
            of: bearerToken,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )

        let basicAuthorization = #"(?i)\b(?:authorization\s*:\s*)?basic\s+[A-Za-z0-9+/=]{8,}"#
        summary = summary.replacingOccurrences(
            of: basicAuthorization,
            with: "Basic [REDACTED]",
            options: .regularExpression
        )

        let uriUserInfo = #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@"#
        summary = summary.replacingOccurrences(
            of: uriUserInfo,
            with: "$1[REDACTED]@",
            options: .regularExpression
        )

        let recognizableTokens = #"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|glpat-[A-Za-z0-9_-]{10,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#
        summary = summary.replacingOccurrences(
            of: recognizableTokens,
            with: "[REDACTED]",
            options: .regularExpression
        )

        return String(summary.prefix(maxLength))
    }

    public static func sanitizeDisplayText(_ value: String, maxLength: Int) -> String? {
        guard maxLength > 0 else {
            return nil
        }
        let sanitized = stripUnsafeControls(value)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !sanitized.isEmpty else {
            return nil
        }
        return String(sanitized.prefix(maxLength))
    }

    private static func stripUnsafeControls(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return false
            }
            switch scalar.value {
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                return false
            default:
                return true
            }
        })
    }
}
