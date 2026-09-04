@preconcurrency import ApplicationServices

public enum AccessibilityAuthorization {
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Requests the system Accessibility prompt when access has not been granted.
    /// The return value reflects the permission state at the time of this call; the
    /// app normally needs to retry after the user changes the setting.
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

package struct AccessibilityRecoveryRequest: Equatable, Sendable {
    package let reportCompletion: Bool
}

package struct AccessibilityRecoveryTrigger: Sendable {
    package private(set) var isWaitingForGrant = false
    private var reportCompletionAfterGrant = false

    package init() {}

    package mutating func waitForGrant(reportCompletion: Bool) {
        isWaitingForGrant = true
        reportCompletionAfterGrant = reportCompletionAfterGrant || reportCompletion
    }

    package mutating func prepareForAuthorizedRecovery() {
        isWaitingForGrant = false
        reportCompletionAfterGrant = false
    }

    package mutating func consumeGrant(
        isTrusted: Bool
    ) -> AccessibilityRecoveryRequest? {
        guard isWaitingForGrant, isTrusted else {
            return nil
        }
        let request = AccessibilityRecoveryRequest(
            reportCompletion: reportCompletionAfterGrant
        )
        isWaitingForGrant = false
        reportCompletionAfterGrant = false
        return request
    }
}
