import Foundation

@main @MainActor enum PanelSizePreferencesChecks {
    static func main() {
        let suiteName = "codexbar-panel-size-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PanelSizePreferences(defaults: defaults)
        check(settings.width == 126 && settings.height == nil, "Fresh settings must preserve compact sizing")
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.setWidth(260)
        settings.setHeight(360)
        check(changes == 2, "Each size change must notify the live panel")
        let restored = PanelSizePreferences(defaults: defaults)
        check(restored.width == 260 && restored.height == 360, "Restart lost the custom dimensions")

        settings.setWidth(1)
        settings.setHeight(10_000)
        check(settings.width == 126 && settings.height == 1200, "Out-of-range settings were not bounded")
        settings.setWidth(.infinity)
        settings.setHeight(.nan)
        check(settings.width == 126 && settings.height == nil, "Nonfinite dimensions must restore automatic sizing")

        defaults.set(-20, forKey: "CodexBar.panel.width")
        defaults.set("invalid", forKey: "CodexBar.panel.height")
        let invalid = PanelSizePreferences(defaults: defaults)
        check(invalid.width == 126 && invalid.height == nil, "Invalid saved preferences produced unusable dimensions")

        settings.setWidth(300)
        settings.setHeight(400)
        let beforeReset = changes
        settings.reset()
        check(changes == beforeReset + 1, "Reset must update the live panel once")
        let reset = PanelSizePreferences(defaults: defaults)
        check(reset.width == 126 && reset.height == nil, "Reset did not persist the original automatic height")
        print("PASS panel size preferences: defaults, persistence, bounds, invalid values, live updates and reset")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
