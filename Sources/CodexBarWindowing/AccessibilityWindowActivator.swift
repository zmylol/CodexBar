import AppKit
import ApplicationServices
import CodexBarCore

public enum VSCodeWindowActivationResult: Equatable, Sendable {
    case activated(VSCodeWindowDescriptor)
    case activatedWithUnminimizedWindows(
        VSCodeWindowDescriptor,
        [VSCodeWindowDescriptor]
    )
    case accessibilityPermissionRequired
    case applicationNotRunning
    case windowNotFound
    case ambiguous([VSCodeWindowDescriptor])
    case activationFailed(VSCodeWindowDescriptor)
}

@MainActor
public final class AccessibilityWindowActivator {
    public static let visualStudioCodeBundleIdentifier = "com.microsoft.VSCode"
    private static let messagingTimeout: Float = 1

    private let activationWorker: AccessibilityWindowActivationWorker
    private let codeSignatureValidator: @Sendable (pid_t) -> Bool

    public init(matcher: VSCodeWindowMatcher = VSCodeWindowMatcher()) {
        let codeSignatureValidator = VSCodeCodeSignatureVerifier.isOfficialVisualStudioCode
        self.codeSignatureValidator = codeSignatureValidator
        activationWorker = AccessibilityWindowActivationWorker(
            matcher: matcher,
            messagingTimeout: Self.messagingTimeout,
            codeSignatureValidator: codeSignatureValidator
        )
    }

    public func discoverWindows(promptForAccessibility: Bool = false) -> [VSCodeWindowDescriptor] {
        guard ensureAccessibilityPermission(promptIfNeeded: promptForAccessibility) else {
            return []
        }

        return VSCodeWindowSnapshotReader.enumerate(
            applicationIdentities: runningVisualStudioCodeApplicationIdentities(),
            using: AccessibilityWindowDescriptorReader(
                messagingTimeout: Self.messagingTimeout,
                codeSignatureValidator: codeSignatureValidator
            )
        ).map { VSCodeWorkspaceMetadata.enrich($0) } ?? []
    }

    /// Enumerates descriptors without making Accessibility calls on the main actor.
    public func discoverWindowsAsync(
        promptForAccessibility: Bool = false
    ) async -> [VSCodeWindowDescriptor] {
        await discoverWindowSnapshotAsync(promptForAccessibility: promptForAccessibility) ?? []
    }

    /// An empty snapshot confirms there are no standard windows. `nil` means
    /// discovery was incomplete, so callers must preserve their previous state.
    public func discoverWindowSnapshotAsync(
        promptForAccessibility: Bool = false
    ) async -> [VSCodeWindowDescriptor]? {
        guard !Task.isCancelled,
              ensureAccessibilityPermission(promptIfNeeded: promptForAccessibility),
              let applicationIdentities = runningVisualStudioCodeApplicationSnapshot()
        else {
            return nil
        }

        let messagingTimeout = Self.messagingTimeout
        let codeSignatureValidator = codeSignatureValidator
        let enumerationTask = Task.detached(priority: .utility) {
            VSCodeWindowSnapshotReader.enumerate(
                applicationIdentities: applicationIdentities,
                using: AccessibilityWindowDescriptorReader(
                    messagingTimeout: messagingTimeout,
                    codeSignatureValidator: codeSignatureValidator
                )
            ).map { VSCodeWorkspaceMetadata.enrich($0) }
        }
        let snapshot = await withTaskCancellationHandler {
            await enumerationTask.value
        } onCancel: {
            enumerationTask.cancel()
        }
        guard !Task.isCancelled,
              AccessibilityAuthorization.isTrusted,
              runningVisualStudioCodeApplicationSnapshot() == applicationIdentities
        else {
            return nil
        }
        return snapshot
    }

    /// Raises an existing VS Code Stable window matching `cwd`, or an explicit
    /// workspace when no task cwd exists, preserving other
    /// windows unless explicitly asked to minimize them for project focus.
    /// This method never opens a workspace or creates a new VS Code window.
    public func activateWindow(
        forCWD cwd: String?,
        workspace: VSCodeWorkspaceIdentity? = nil,
        promptForAccessibility: Bool = false,
        minimizeOtherWindows: Bool = false
    ) async -> VSCodeWindowActivationResult {
        guard let path = cwd ?? workspace?.path, PathNormalizer.normalize(path) != nil else {
            return .windowNotFound
        }

        guard ensureAccessibilityPermission(promptIfNeeded: promptForAccessibility) else {
            return .accessibilityPermissionRequired
        }

        let applicationIdentities = runningVisualStudioCodeApplicationIdentities()
        guard !applicationIdentities.isEmpty else {
            return .applicationNotRunning
        }

        return await activationWorker.activateWindow(
            forCWD: cwd,
            workspace: workspace,
            applicationIdentities: applicationIdentities,
            minimizeOtherWindows: minimizeOtherWindows
        )
    }

    private func ensureAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        if AccessibilityAuthorization.isTrusted {
            return true
        }

        return promptIfNeeded && AccessibilityAuthorization.requestIfNeeded()
    }

    private func runningVisualStudioCodeApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.bundleIdentifier == Self.visualStudioCodeBundleIdentifier
                && codeSignatureValidator($0.processIdentifier)
        }
    }

    private func runningVisualStudioCodeApplicationIdentities()
        -> [VSCodeApplicationIdentity]
    {
        runningVisualStudioCodeApplications().compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier,
                  let launchDate = application.launchDate
            else {
                return nil
            }
            return VSCodeApplicationIdentity(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                launchDate: launchDate
            )
        }
    }

    private func runningVisualStudioCodeApplicationSnapshot() -> [VSCodeApplicationIdentity]? {
        var identities: [VSCodeApplicationIdentity] = []
        for application in NSWorkspace.shared.runningApplications where
            !application.isTerminated
                && application.bundleIdentifier == Self.visualStudioCodeBundleIdentifier
        {
            guard codeSignatureValidator(application.processIdentifier),
                  let bundleIdentifier = application.bundleIdentifier,
                  let launchDate = application.launchDate
            else {
                return nil
            }
            identities.append(VSCodeApplicationIdentity(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                launchDate: launchDate
            ))
        }
        return identities.sorted { $0.processIdentifier < $1.processIdentifier }
    }

}

private actor AccessibilityWindowActivationWorker {
    private let matcher: VSCodeWindowMatcher
    private let messagingTimeout: Float
    private let codeSignatureValidator: @Sendable (pid_t) -> Bool

    init(
        matcher: VSCodeWindowMatcher,
        messagingTimeout: Float,
        codeSignatureValidator: @escaping @Sendable (pid_t) -> Bool
    ) {
        self.matcher = matcher
        self.messagingTimeout = messagingTimeout
        self.codeSignatureValidator = codeSignatureValidator
    }

    func activateWindow(
        forCWD cwd: String?,
        workspace: VSCodeWorkspaceIdentity?,
        applicationIdentities: [VSCodeApplicationIdentity],
        minimizeOtherWindows: Bool
    ) -> VSCodeWindowActivationResult {
        guard AccessibilityAuthorization.isTrusted else {
            return .accessibilityPermissionRequired
        }
        guard applicationIdentities.contains(where: isCurrentApplication) else {
            return .applicationNotRunning
        }

        let initialWindows = enumerateWindows(applicationIdentities: applicationIdentities)
        guard !Task.isCancelled else {
            return .windowNotFound
        }

        switch matcher.match(cwd: cwd, windows: initialWindows.map(\.descriptor), workspace: workspace) {
        case .notFound:
            return .windowNotFound
        case let .ambiguous(candidates):
            return .ambiguous(candidates)
        case .matched:
            break
        }

        // Refresh immediately before acting. Window titles and ordering can change
        // while VS Code is active; only a still-unique match is safe to raise.
        let refreshedWindows = enumerateWindows(applicationIdentities: applicationIdentities)
        guard !Task.isCancelled else {
            return .windowNotFound
        }

        switch matcher.focusPlan(
            cwd: cwd,
            windows: refreshedWindows.map(\.descriptor),
            workspace: workspace,
            minimizeOtherWindows: minimizeOtherWindows
        ) {
        case .notFound:
            return .windowNotFound
        case let .ambiguous(candidates):
            return .ambiguous(candidates)
        case let .planned(plan):
            guard let window = refreshedWindows.first(where: {
                $0.descriptor.id == plan.target.id
            }) else {
                return .windowNotFound
            }
            guard isCurrentApplication(window.applicationIdentity) else {
                return .applicationNotRunning
            }
            let windowsToMinimize = Set(plan.windowsToMinimize.map(\.id))
            let otherWindows = refreshedWindows.filter {
                windowsToMinimize.contains($0.descriptor.id)
                    && isCurrentApplication($0.applicationIdentity)
            }

            switch activate(window, minimizing: otherWindows) {
            case .activated:
                return .activated(plan.target)
            case let .activatedWithUnminimizedWindows(windows):
                return .activatedWithUnminimizedWindows(plan.target, windows)
            case .failed:
                return .activationFailed(plan.target)
            }
        }
    }

    private func enumerateWindows(
        applicationIdentities: [VSCodeApplicationIdentity]
    ) -> [AccessibilityWindow] {
        var result: [AccessibilityWindow] = []

        for applicationIdentity in applicationIdentities {
            guard !Task.isCancelled else {
                return []
            }
            guard isCurrentApplication(applicationIdentity) else {
                continue
            }
            let processIdentifier = applicationIdentity.processIdentifier
            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)
            guard let elements: [AXUIElement] = copyAttribute(
                kAXWindowsAttribute as CFString,
                from: applicationElement
            ) else {
                continue
            }

            for (index, element) in elements.enumerated() {
                guard !Task.isCancelled else {
                    return []
                }
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                guard isStandardWindow(element),
                      let title: String = copyAttribute(
                          kAXTitleAttribute as CFString,
                          from: element
                      )
                else {
                    continue
                }

                result.append(AccessibilityWindow(
                    descriptor: VSCodeWindowDescriptor(
                        id: (Int(processIdentifier) << 32) | index,
                        title: title
                    ),
                    element: element,
                    applicationIdentity: applicationIdentity
                ))
            }
        }

        let descriptors = VSCodeWorkspaceMetadata.enrich(result.map(\.descriptor))
        return zip(result, descriptors).map { window, descriptor in
            AccessibilityWindow(
                descriptor: descriptor,
                element: window.element,
                applicationIdentity: window.applicationIdentity
            )
        }
    }

    private func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: identity.processIdentifier
        ) else {
            return false
        }
        return identity.matches(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate,
            isTerminated: application.isTerminated,
            hasValidCodeSignature: codeSignatureValidator(identity.processIdentifier)
        )
    }

    private func activate(
        _ window: AccessibilityWindow,
        minimizing otherWindows: [AccessibilityWindow]
    ) -> VSCodeWindowActivationSequenceResult {
        let operations = AccessibilityWindowActivationOperations(
            target: window,
            otherWindows: otherWindows,
            messagingTimeout: messagingTimeout
        )

        return VSCodeWindowActivationSequencer().activate(
            otherWindows: otherWindows.map(\.descriptor),
            using: operations
        )
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        let role: String? = copyAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole: String? = copyAttribute(kAXSubroleAttribute as CFString, from: element)
        return role == (kAXWindowRole as String)
            && subrole == (kAXStandardWindowSubrole as String)
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}

private struct AccessibilityWindow {
    let descriptor: VSCodeWindowDescriptor
    let element: AXUIElement
    let applicationIdentity: VSCodeApplicationIdentity
}

private final class AccessibilityWindowActivationOperations:
    VSCodeWindowActivationOperations
{
    private let target: AccessibilityWindow
    private let otherWindowsByID: [Int: AccessibilityWindow]
    private let applicationElement: AXUIElement

    init(
        target: AccessibilityWindow,
        otherWindows: [AccessibilityWindow],
        messagingTimeout: Float
    ) {
        self.target = target
        otherWindowsByID = Dictionary(
            uniqueKeysWithValues: otherWindows.map { ($0.descriptor.id, $0) }
        )
        applicationElement = AXUIElementCreateApplication(
            target.applicationIdentity.processIdentifier
        )
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)
    }

    func targetMinimizedState() -> Bool? {
        copyAttribute(kAXMinimizedAttribute as CFString, from: target.element)
    }

    func restoreTarget() -> Bool {
        AXUIElementSetAttributeValue(
            target.element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        ) == .success
    }

    func makeApplicationFrontmost() -> Bool {
        AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    func makeTargetMain() {
        AXUIElementSetAttributeValue(
            target.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
    }

    func raiseTarget() -> Bool {
        AXUIElementPerformAction(
            target.element,
            kAXRaiseAction as CFString
        ) == .success
    }

    func isMinimized(_ window: VSCodeWindowDescriptor) -> Bool {
        guard let otherWindow = otherWindowsByID[window.id] else {
            return false
        }
        return copyAttribute(
            kAXMinimizedAttribute as CFString,
            from: otherWindow.element
        ) ?? false
    }

    func minimize(_ window: VSCodeWindowDescriptor) -> Bool {
        guard let otherWindow = otherWindowsByID[window.id] else {
            return false
        }
        return AXUIElementSetAttributeValue(
            otherWindow.element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    func focusTarget() {
        // Electron does not make these writable on every release, so both are
        // best-effort hints after the required frontmost/main/raise operations.
        AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            target.element
        )
        AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}

package protocol VSCodeWindowSnapshotReading {
    associatedtype Window

    var isTrusted: Bool { get }
    var isCancelled: Bool { get }
    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool
    func windows(for identity: VSCodeApplicationIdentity) -> [Window]?
    func role(of window: Window) -> String?
    func subrole(of window: Window) -> String?
    func title(of window: Window) -> String?
}

package enum VSCodeWindowSnapshotReader {
    package static func enumerate<Reader: VSCodeWindowSnapshotReading>(
        applicationIdentities: [VSCodeApplicationIdentity],
        using reader: Reader
    ) -> [VSCodeWindowDescriptor]? {
        guard reader.isTrusted, !reader.isCancelled else {
            return nil
        }
        var result: [VSCodeWindowDescriptor] = []

        for applicationIdentity in applicationIdentities {
            guard reader.isTrusted, !reader.isCancelled,
                  reader.isCurrentApplication(applicationIdentity),
                  let elements = reader.windows(for: applicationIdentity)
            else {
                return nil
            }
            for (index, element) in elements.enumerated() {
                guard reader.isTrusted, !reader.isCancelled,
                      let role = reader.role(of: element)
                else {
                    return nil
                }
                guard role == (kAXWindowRole as String) else {
                    continue
                }
                guard let subrole = reader.subrole(of: element) else {
                    return nil
                }
                guard subrole == (kAXStandardWindowSubrole as String) else {
                    continue
                }
                guard let title = reader.title(of: element) else {
                    return nil
                }
                result.append(VSCodeWindowDescriptor(
                    id: (Int(applicationIdentity.processIdentifier) << 32) | index,
                    title: title
                ))
            }
        }

        guard reader.isTrusted, !reader.isCancelled,
              applicationIdentities.allSatisfy(reader.isCurrentApplication)
        else {
            return nil
        }
        return result
    }
}

private struct AccessibilityWindowDescriptorReader: VSCodeWindowSnapshotReading {
    let messagingTimeout: Float
    let codeSignatureValidator: @Sendable (pid_t) -> Bool

    var isTrusted: Bool { AccessibilityAuthorization.isTrusted }

    var isCancelled: Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
    }

    func windows(for identity: VSCodeApplicationIdentity) -> [AXUIElement]? {
        let applicationElement = AXUIElementCreateApplication(identity.processIdentifier)
        guard AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout) == .success,
              let elements: [AXUIElement] = copyAttribute(
                  kAXWindowsAttribute as CFString,
                  from: applicationElement
              )
        else {
            return nil
        }
        for element in elements {
            guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else {
                return nil
            }
        }
        return elements
    }

    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: identity.processIdentifier
        ) else {
            return false
        }
        return identity.matches(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate,
            isTerminated: application.isTerminated,
            hasValidCodeSignature: codeSignatureValidator(identity.processIdentifier)
        )
    }

    func role(of window: AXUIElement) -> String? {
        copyAttribute(kAXRoleAttribute as CFString, from: window)
    }

    func subrole(of window: AXUIElement) -> String? {
        copyAttribute(kAXSubroleAttribute as CFString, from: window)
    }

    func title(of window: AXUIElement) -> String? {
        copyAttribute(kAXTitleAttribute as CFString, from: window)
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}
