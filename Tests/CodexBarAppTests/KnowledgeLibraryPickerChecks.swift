import AppKit
import CodexBarCore

@main @MainActor enum KnowledgeLibraryPickerChecks {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let parent = PickerParentPanel(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.level = .floating
        parent.makeKeyAndOrderFront(nil)
        let suite = "codexbar-picker-check-\(UUID().uuidString)"
        let model = KnowledgeLibraryModel(defaultsSuiteName: suite)
        defer {
            model.stop()
            parent.orderOut(nil)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        model.chooseVault(in: parent)
        settle()
        guard let first = parent.attachedSheet as? NSOpenPanel else {
            fatalError("The folder chooser must belong to the floating knowledge library window")
        }
        model.chooseVault(in: parent)
        precondition(parent.attachedSheet === first, "Repeated clicks created another chooser")
        first.cancel(nil)
        settle()
        precondition(parent.attachedSheet == nil && model.review == nil, "Cancel changed the vault or retained the sheet")
        model.chooseVault(in: parent)
        settle()
        precondition(parent.attachedSheet is NSOpenPanel, "The chooser cannot reopen after cancel")
        model.stop()
        settle()
        precondition(parent.attachedSheet == nil && model.review == nil, "Stopping retained an actionable folder chooser")
        print("PASS knowledge library picker: attached sheet, repeated click, cancel, reopen and stop")
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
}

@MainActor private final class PickerParentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
