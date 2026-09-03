import Foundation

public enum CodexTaskDestination: String, Codable, Equatable, Sendable {
    case visualStudioCode = "vscode"
    case codexDesktop

    public static func fromHookEnvironment(
        _ environment: [String: String]
    ) -> CodexTaskDestination? {
        guard let originator = environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }

        switch originator {
        case "codex_vscode":
            return .visualStudioCode
        case "codex", "codex desktop", "codex_work_desktop":
            return .codexDesktop
        default:
            return nil
        }
    }
}
