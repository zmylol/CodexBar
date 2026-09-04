import Foundation
import CodexBarCore

let maximumInputBytes = 4 * 1_024 * 1_024

if let source = CodexHookSource.fromHookEnvironment(ProcessInfo.processInfo.environment) {
    do {
        if let input = try FileHandle.standardInput.read(upToCount: maximumInputBytes + 1),
           !input.isEmpty,
           input.count <= maximumInputBytes {
            let mode: HookCaptureMode = CommandLine.arguments.contains("--probe") ? .probe : .inbox
            let parser = CodexHookEventParser(source: source)
            _ = try? HookCaptureService(parser: parser).capture(input, mode: mode)
        }
    } catch {
        // Lifecycle hooks must keep stdout/stderr empty.
    }
}
