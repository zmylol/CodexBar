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
