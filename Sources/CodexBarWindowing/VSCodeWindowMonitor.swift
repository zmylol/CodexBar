import AppKit
import ApplicationServices

public enum VSCodeWindowMonitorStatus: Equatable, Sendable {
    case stopped
    case observing
    case accessibilityPermissionRequired
    case failed
}

/// Workspace and Accessibility notifications drive discovery; no periodic scan is scheduled.
@MainActor
public final class VSCodeWindowMonitor {
    public private(set) var status: VSCodeWindowMonitorStatus = .stopped
    public var onStatusChange: (@MainActor @Sendable (VSCodeWindowMonitorStatus) -> Void)?

    private var worker: VSCodeObservationWorker?
    private var notificationTokens: [WorkspaceNotificationToken] = []
    private var generation = UUID()
    private var onChange: (@MainActor @Sendable () -> Void)?

    public init() {}

    public func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        self.onChange = onChange
        let generation = generation
        worker = VSCodeObservationWorker { [weak self] status, changed in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.worker != nil else { return }
                self.updateStatus(status)
                if changed { self.onChange?() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            notificationTokens.append(WorkspaceNotificationToken(center: center,
                token: center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    application.bundleIdentifier == "com.microsoft.VSCode" else { return }
                MainActor.assumeIsolated { self?.refresh(emitChange: true) }
            }))
        }
        // Activation also recovers after a grant in System Settings. A nonactivating
        // floating panel cannot rely on its own application's activation notification.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            notificationTokens.append(WorkspaceNotificationToken(center: center,
                token: center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(emitChange: true) }
            }))
        }
        refresh(emitChange: true)
    }

    /// Reattaches listeners after a manual refresh, without requesting another snapshot.
    public func refreshObservers() {
        refresh(emitChange: false)
    }

    public func stop() {
        generation = UUID()
        notificationTokens.removeAll()
        worker?.stop()
        worker = nil
        onChange = nil
        updateStatus(.stopped)
    }

    private func refresh(emitChange: Bool) {
        let identities = NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.bundleIdentifier == "com.microsoft.VSCode",
                  let launchDate = application.launchDate else { return nil as VSCodeApplicationIdentity? }
            return VSCodeApplicationIdentity(processIdentifier: application.processIdentifier,
                                            bundleIdentifier: "com.microsoft.VSCode", launchDate: launchDate)
        }
        worker?.refresh(identities, emitChange: emitChange)
    }

    private func updateStatus(_ status: VSCodeWindowMonitorStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatusChange?(status)
    }

    deinit {
        worker?.stop()
    }
}

/// NotificationCenter removal is thread-safe, including during nonisolated deinit.
private final class WorkspaceNotificationToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}

package protocol VSCodeWindowObservationBackend {
    associatedtype Observation
    var isTrusted: Bool { get }
    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool
    func createObservation(for identity: VSCodeApplicationIdentity) -> Observation?
    func refreshWindows(in observation: Observation) -> Bool
    func removeObservation(_ observation: Observation)
}

/// Confined to the observer run loop; the backend is injectable for lifecycle tests.
package final class VSCodeWindowObservationSession<Backend: VSCodeWindowObservationBackend> {
    private let backend: Backend
    private var observations: [Int32: (VSCodeApplicationIdentity, Backend.Observation)] = [:]

    package init(backend: Backend) { self.backend = backend }

    package func refresh(_ identities: [VSCodeApplicationIdentity]) -> VSCodeWindowMonitorStatus {
        guard backend.isTrusted else {
            stop()
            return .accessibilityPermissionRequired
        }
        for (pid, entry) in observations where !identities.contains(entry.0) {
            backend.removeObservation(entry.1)
            observations.removeValue(forKey: pid)
        }
        var succeeded = true
        for identity in identities {
            let pid = identity.processIdentifier
            guard backend.isCurrentApplication(identity) else {
                if let entry = observations.removeValue(forKey: pid) { backend.removeObservation(entry.1) }
                succeeded = false
                continue
            }
            if observations[pid] == nil {
                guard let observation = backend.createObservation(for: identity) else {
                    succeeded = false
                    continue
                }
                observations[pid] = (identity, observation)
            }
            if let entry = observations[pid], !backend.refreshWindows(in: entry.1) { succeeded = false }
        }
        guard backend.isTrusted else {
            stop()
            return .accessibilityPermissionRequired
        }
        return succeeded ? .observing : .failed
    }

    package func stop() {
        for entry in observations.values { backend.removeObservation(entry.1) }
        observations.removeAll()
    }
}

/// AX requires a run-loop source. This dedicated thread sleeps in CFRunLoopRun
/// between notifications; every AX call and observer teardown uses this same thread.
private final class VSCodeObservationWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var pending: [@Sendable () -> Void] = []
    private var acceptsWork = true
    private let onUpdate: @Sendable (VSCodeWindowMonitorStatus, Bool) -> Void
    private var identities: [VSCodeApplicationIdentity] = []
    private var revision = 0
    private lazy var session = VSCodeWindowObservationSession(backend: AXWindowObservationBackend {
        [weak self] in
        guard let self else { return }
        self.reconcile(emitChange: true)
    })

    init(onUpdate: @escaping @Sendable (VSCodeWindowMonitorStatus, Bool) -> Void) {
        self.onUpdate = onUpdate
        let thread = Thread { [self] in run() }
        thread.name = "CodexBar VS Code window events"
        thread.qualityOfService = .utility
        thread.start()
    }

    func refresh(_ identities: [VSCodeApplicationIdentity], emitChange: Bool) {
        enqueue { [self] in
            self.identities = identities
            revision += 1
            reconcile(emitChange: emitChange)
        }
    }

    func stop() {
        enqueue(finishing: true) { [self] in
            revision += 1
            session.stop()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func reconcile(emitChange: Bool, retriesRemaining: Int = 2) {
        let status = session.refresh(identities)
        onUpdate(status, emitChange)
        guard status == .failed, retriesRemaining > 0 else { return }
        let revision = revision
        // Launch notifications can precede Electron's AX readiness. Retry only
        // this event's registration twice; failure never starts a periodic timer.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enqueue { [weak self] in
                guard let self, self.revision == revision else { return }
                self.reconcile(emitChange: emitChange, retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    private func enqueue(finishing: Bool = false, _ action: @escaping @Sendable () -> Void) {
        let pooledAction: @Sendable () -> Void = { autoreleasepool(invoking: action) }
        lock.lock()
        defer { lock.unlock() }
        guard acceptsWork else { return }
        if finishing { acceptsWork = false }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, pooledAction)
            CFRunLoopWakeUp(runLoop)
        } else {
            pending.append(pooledAction)
        }
    }

    private func run() {
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        guard let current = CFRunLoopGetCurrent(),
              let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) else {
            lock.lock()
            acceptsWork = false
            pending.removeAll()
            lock.unlock()
            onUpdate(.failed, true)
            return
        }
        CFRunLoopAddSource(current, keepAlive, .defaultMode)
        lock.lock()
        runLoop = current
        for action in pending { CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue, action) }
        pending.removeAll()
        lock.unlock()
        CFRunLoopRun()
        CFRunLoopRemoveSource(current, keepAlive, .defaultMode)
        lock.lock()
        runLoop = nil
        lock.unlock()
    }
}

private final class AXWindowObservationBackend: VSCodeWindowObservationBackend {
    private let onChange: () -> Void
    private let windowNotifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification]

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    var isTrusted: Bool { AccessibilityAuthorization.isTrusted }

    func isCurrentApplication(_ identity: VSCodeApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: identity.processIdentifier) else {
            return false
        }
        return identity.matches(processIdentifier: application.processIdentifier,
                                bundleIdentifier: application.bundleIdentifier,
                                launchDate: application.launchDate,
                                isTerminated: application.isTerminated,
                                hasValidCodeSignature: VSCodeCodeSignatureVerifier.isOfficialVisualStudioCode(
                                    processIdentifier: identity.processIdentifier))
    }

    func createObservation(for identity: VSCodeApplicationIdentity) -> AXApplicationObservation? {
        var observer: AXObserver?
        guard AXObserverCreate(identity.processIdentifier, { _, _, _, context in
            guard let context else { return }
            autoreleasepool {
                Unmanaged<AXApplicationObservation>.fromOpaque(context).takeUnretainedValue().onChange()
            }
        }, &observer) == .success, let observer else { return nil }
        let application = AXUIElementCreateApplication(identity.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        let observation = AXApplicationObservation(observer: observer, application: application,
                                                   onChange: onChange)
        guard register(kAXWindowCreatedNotification, element: application, observation: observation) else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return observation
    }

    func refreshWindows(in observation: AXApplicationObservation) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(observation.application, kAXWindowsAttribute as CFString, &value)
            == .success, let elements = value as? [AXUIElement] else { return false }
        var windows: [AXUIElement] = []
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 1)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  let role = role as? String else { return false }
            guard role == kAXWindowRole else { continue }
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                  let subrole = subrole as? String else { return false }
            if subrole == kAXStandardWindowSubrole { windows.append(element) }
        }
        for old in observation.windows where !windows.contains(where: { CFEqual($0, old) }) {
            for notification in windowNotifications {
                AXObserverRemoveNotification(observation.observer, old, notification as CFString)
            }
        }
        observation.windows.removeAll { old in !windows.contains(where: { CFEqual($0, old) }) }
        var succeeded = true
        for window in windows where !observation.windows.contains(where: { CFEqual($0, window) }) {
            var registered = true
            for notification in windowNotifications {
                if !register(notification, element: window, observation: observation) { registered = false }
            }
            if registered {
                observation.windows.append(window)
            } else {
                for notification in windowNotifications {
                    AXObserverRemoveNotification(observation.observer, window, notification as CFString)
                }
                succeeded = false
            }
        }
        return succeeded
    }

    func removeObservation(_ observation: AXApplicationObservation) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observation.observer), .defaultMode)
        AXObserverRemoveNotification(observation.observer, observation.application, kAXWindowCreatedNotification as CFString)
        for window in observation.windows {
            for notification in windowNotifications {
                AXObserverRemoveNotification(observation.observer, window, notification as CFString)
            }
        }
    }

    private func register(_ notification: String, element: AXUIElement,
                          observation: AXApplicationObservation) -> Bool {
        let result = AXObserverAddNotification(observation.observer, element, notification as CFString,
                                               Unmanaged.passUnretained(observation).toOpaque())
        return result == .success || result == .notificationAlreadyRegistered
    }
}

private final class AXApplicationObservation {
    let observer: AXObserver
    let application: AXUIElement
    let onChange: () -> Void
    var windows: [AXUIElement] = []

    init(observer: AXObserver, application: AXUIElement, onChange: @escaping () -> Void) {
        self.observer = observer
        self.application = application
        self.onChange = onChange
    }
}
