import Foundation

public enum CodexHookSource: String, Codable, Equatable, Sendable {
    case visualStudioCode = "vscode"

    public static func fromHookEnvironment(
        _ environment: [String: String]
    ) -> CodexHookSource? {
        guard environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "codex_vscode" else {
            return nil
        }
        return .visualStudioCode
    }
}
