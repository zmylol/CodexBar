import ApplicationServices
import Foundation
import CodexBarCore
import CodexBarWindowing

@MainActor
func windowSnapshotDiscoveryTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "window snapshots distinguish no application from unreadable windows") {
            let reader = FakeWindowSnapshotReading()
            try expect(
                VSCodeWindowSnapshotReader.enumerate(applicationIdentities: [], using: reader) == [],
                "no running application did not produce a confirmed empty snapshot"
            )
            try expect(readWindowSnapshot(using: reader) == [], "an empty AXWindows list was rejected")

            reader.windowElements = nil
            try expect(
                readWindowSnapshot(using: reader) == nil,
                "a failed AXWindows read was treated as all windows being closed"
            )
        },
        CodexBarTestCase(name: "window snapshots reject unreadable window attributes without returning partial results") {
            for missingAttribute in ["role", "subrole", "title"] {
                let reader = FakeWindowSnapshotReading()
                reader.windowElements = [0, 1]
                reader.missingAttribute = missingAttribute

                try expect(
                    readWindowSnapshot(using: reader) == nil,
                    "an unreadable \(missingAttribute) silently removed a window from the snapshot"
                )
            }
        },
        CodexBarTestCase(name: "window snapshots include minimized standard windows and ignore known nonstandard windows") {
            let reader = FakeWindowSnapshotReading()
            reader.windowElements = [0, 1, 2]
            reader.nonstandardWindow = 1

            try expect(
                readWindowSnapshot(using: reader) == [
                    VSCodeWindowDescriptor(id: Int(123) << 32, title: "project-0 — Visual Studio Code"),
                    VSCodeWindowDescriptor(id: (Int(123) << 32) | 2, title: "project-2 — Visual Studio Code")
                ],
                "standard windows were filtered by visibility or nonstandard windows were included"
            )
        },
        CodexBarTestCase(name: "window snapshots reject cancellation and missing Accessibility permission even when empty") {
            let reader = FakeWindowSnapshotReading()
            reader.isTrusted = false
            try expect(
                VSCodeWindowSnapshotReader.enumerate(applicationIdentities: [], using: reader) == nil,
                "missing Accessibility permission was treated as a confirmed empty snapshot"
            )

            reader.isTrusted = true
            reader.isCancelled = true
            try expect(
                VSCodeWindowSnapshotReader.enumerate(applicationIdentities: [], using: reader) == nil,
                "a cancelled enumeration was treated as a confirmed empty snapshot"
            )
        },
        CodexBarTestCase(name: "window snapshots discard reads when Accessibility permission is revoked mid-read") {
            let reader = FakeWindowSnapshotReading()
            reader.revokePermissionAfterWindowRead = true
            try expect(
                readWindowSnapshot(using: reader) == nil,
                "revoking Accessibility during enumeration produced a usable snapshot"
            )
        },
        CodexBarTestCase(name: "window snapshots reject stale and changed application identities") {
            let reader = FakeWindowSnapshotReading()
            reader.currentIdentityChecks = [false]
            try expect(readWindowSnapshot(using: reader) == nil, "a stale process became an empty snapshot")

            reader.windowElements = [0]
            reader.currentIdentityChecks = [true, false]
            try expect(
                readWindowSnapshot(using: reader) == nil,
                "an application identity that changed during enumeration was accepted"
            )
        },
        CodexBarTestCase(name: "window snapshots discard partial reads when a second application fails") {
            let reader = FakeWindowSnapshotReading()
            reader.windowElements = [0]
            reader.currentIdentityChecks = [true, false]
            let identities = [snapshotApplicationIdentity(123), snapshotApplicationIdentity(456)]

            try expect(
                VSCodeWindowSnapshotReader.enumerate(applicationIdentities: identities, using: reader) == nil,
                "a failed application read returned only another application's windows"
            )
        }
    ]
}

private func snapshotApplicationIdentity(_ processIdentifier: Int32) -> VSCodeApplicationIdentity {
    VSCodeApplicationIdentity(
        processIdentifier: processIdentifier,
        bundleIdentifier: "com.microsoft.VSCode",
        launchDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func readWindowSnapshot(using reader: FakeWindowSnapshotReading) -> [VSCodeWindowDescriptor]? {
    VSCodeWindowSnapshotReader.enumerate(
        applicationIdentities: [snapshotApplicationIdentity(123)],
        using: reader
    )
}

private final class FakeWindowSnapshotReading: VSCodeWindowSnapshotReading {
    var isTrusted = true
    var isCancelled = false
    var windowElements: [Int]? = []
    var missingAttribute: String?
    var nonstandardWindow: Int?
    var currentIdentityChecks: [Bool] = []
    var revokePermissionAfterWindowRead = false

    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool {
        currentIdentityChecks.isEmpty ? true : currentIdentityChecks.removeFirst()
    }

    func windows(for identity: VSCodeApplicationIdentity) -> [Int]? {
        if revokePermissionAfterWindowRead {
            isTrusted = false
        }
        return windowElements
    }

    func role(of window: Int) -> String? {
        missingAttribute == "role" && window == 1 ? nil : kAXWindowRole as String
    }

    func subrole(of window: Int) -> String? {
        if missingAttribute == "subrole", window == 1 {
            return nil
        }
        return window == nonstandardWindow ? kAXDialogSubrole as String : kAXStandardWindowSubrole as String
    }

    func title(of window: Int) -> String? {
        missingAttribute == "title" && window == 1 ? nil : "project-\(window) — Visual Studio Code"
    }
}
