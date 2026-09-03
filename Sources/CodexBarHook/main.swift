import Foundation
import CodexBarCore

let maximumInputBytes = 4 * 1_024 * 1_024

do {
    if let input = try FileHandle.standardInput.read(upToCount: maximumInputBytes + 1),
       !input.isEmpty,
       input.count <= maximumInputBytes {
        let mode: HookCaptureMode = CommandLine.arguments.contains("--probe") ? .probe : .inbox
        _ = try? HookCaptureService().capture(input, mode: mode)
    }
} catch {
    // Lifecycle hooks must fail open and keep stdout/stderr empty.
}
