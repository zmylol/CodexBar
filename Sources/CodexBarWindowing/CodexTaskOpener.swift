import AppKit
import CodexBarCore
import Foundation
import Security

@MainActor
public protocol VSCodeTaskActivating: AnyObject {
    func activateWindow(
        forCWD cwd: String,
        promptForAccessibility: Bool
    ) async -> VSCodeWindowActivationResult
}

extension AccessibilityWindowActivator: VSCodeTaskActivating {}

public enum CodexDesktopTaskActivationResult: Equatable, Sendable {
    case opened
    case invalidSessionID
    case applicationNotInstalled
    case untrustedApplication
    case openingFailed
}

@MainActor
public protocol CodexDesktopTaskActivating: AnyObject {
    func openThread(sessionID: String) async -> CodexDesktopTaskActivationResult
}

public enum CodexTaskOpeningResult: Equatable, Sendable {
    case visualStudioCode(VSCodeWindowActivationResult)
    case codexDesktop(CodexDesktopTaskActivationResult)
    case fallbackFailed(
        visualStudioCode: VSCodeWindowActivationResult,
        codexDesktop: CodexDesktopTaskActivationResult
    )
}

public enum CodexDesktopThreadLink {
    public static func make(sessionID: String) -> URL? {
        guard let uuid = UUID(uuidString: sessionID),
              uuid.uuidString.caseInsensitiveCompare(sessionID) == .orderedSame
        else {
            return nil
        }
        return URL(string: "codex://threads/\(sessionID)")
    }
}

@MainActor
public final class CodexDesktopTaskActivator: CodexDesktopTaskActivating {
    public static let bundleIdentifier = "com.openai.codex"

    private let applicationURLProvider: () -> URL?
    private let signatureValidator: (URL) async -> Bool
    private let urlOpener: (URL, URL) async -> Bool

    public convenience init() {
        self.init(
            applicationURLProvider: {
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: Self.bundleIdentifier
                )
            },
            signatureValidator: { applicationURL in
                let validationTask = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else {
                        return false
                    }
                    return CodexDesktopCodeSignatureVerifier.isOfficialCodexApplication(
                        applicationURL
                    )
                }
                return await withTaskCancellationHandler {
                    await validationTask.value
                } onCancel: {
                    validationTask.cancel()
                }
            },
            urlOpener: Self.open
        )
    }

    package init(
        applicationURLProvider: @escaping () -> URL?,
        signatureValidator: @escaping (URL) async -> Bool,
        urlOpener: @escaping (URL, URL) async -> Bool
    ) {
        self.applicationURLProvider = applicationURLProvider
        self.signatureValidator = signatureValidator
        self.urlOpener = urlOpener
    }

    public func openThread(sessionID: String) async -> CodexDesktopTaskActivationResult {
        guard !Task.isCancelled else {
            return .openingFailed
        }
        guard let threadURL = CodexDesktopThreadLink.make(sessionID: sessionID) else {
            return .invalidSessionID
        }
        guard let applicationURL = applicationURLProvider() else {
            return .applicationNotInstalled
        }
        let hasValidSignature = await signatureValidator(applicationURL)
        guard !Task.isCancelled else {
            return .openingFailed
        }
        guard hasValidSignature else {
            return .untrustedApplication
        }
        guard await urlOpener(threadURL, applicationURL) else {
            return .openingFailed
        }
        return .opened
    }

    private static func open(_ threadURL: URL, with applicationURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.open(
                [threadURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}

@MainActor
public final class CodexTaskOpener {
    private let visualStudioCodeActivator: any VSCodeTaskActivating
    private let codexDesktopActivator: any CodexDesktopTaskActivating

    public init(
        visualStudioCodeActivator: any VSCodeTaskActivating,
        codexDesktopActivator: any CodexDesktopTaskActivating
    ) {
        self.visualStudioCodeActivator = visualStudioCodeActivator
        self.codexDesktopActivator = codexDesktopActivator
    }

    public func open(_ task: CodexTask) async -> CodexTaskOpeningResult {
        switch task.destination {
        case .codexDesktop:
            return .codexDesktop(
                await codexDesktopActivator.openThread(sessionID: task.sessionID)
            )
        case .visualStudioCode:
            return .visualStudioCode(
                await visualStudioCodeActivator.activateWindow(
                    forCWD: task.cwd,
                    promptForAccessibility: false
                )
            )
        case nil:
            let visualStudioCodeResult = await visualStudioCodeActivator.activateWindow(
                forCWD: task.cwd,
                promptForAccessibility: false
            )
            guard visualStudioCodeResult == .applicationNotRunning
                    || visualStudioCodeResult == .windowNotFound
            else {
                return .visualStudioCode(visualStudioCodeResult)
            }

            let codexDesktopResult = await codexDesktopActivator.openThread(
                sessionID: task.sessionID
            )
            if codexDesktopResult == .opened {
                return .codexDesktop(.opened)
            }
            return .fallbackFailed(
                visualStudioCode: visualStudioCodeResult,
                codexDesktop: codexDesktopResult
            )
        }
    }
}

private enum CodexDesktopCodeSignatureVerifier {
    private static let requirement = #"identifier "com.openai.codex" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2DC432GLL2""#

    static func isOfficialCodexApplication(_ applicationURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var codeRequirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(),
            &codeRequirement
        ) == errSecSuccess,
              let codeRequirement
        else {
            return false
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            codeRequirement
        ) == errSecSuccess
    }
}
