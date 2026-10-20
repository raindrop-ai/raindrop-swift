import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

/// App lifecycle and connectivity hooks (Apple platforms only).
///
/// - Going to the background: flush within a short budget under an expiring-activity
///   assertion, then save anything left to disk. Uses `ProcessInfo.performExpiringActivity`,
///   which is also allowed in app extensions (unlike `UIApplication.shared`).
/// - Connectivity restored: retry parked payloads right away.
final class LifecycleObserver: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    init(pipeline: Pipeline, budget: Duration, observeApp: Bool) {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        if observeApp {
            #if os(watchOS)
            // String form: WKApplication's constant is main-actor isolated.
            let name = Notification.Name("WKApplicationDidEnterBackgroundNotification")
            #else
            let name = UIApplication.didEnterBackgroundNotification
            #endif
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak pipeline] _ in
                guard let pipeline else { return }
                Self.flushInBackground(pipeline, budget: budget)
            }
            tokens.append(token)
        }
        #endif

        #if canImport(Network)
        let monitor = NWPathMonitor()
        let state = PathState()
        monitor.pathUpdateHandler = { [weak pipeline] path in
            if state.update(satisfied: path.status == .satisfied) { pipeline?.wake() }
        }
        monitor.start(queue: DispatchQueue(label: "ai.raindrop.network", qos: .utility))
        self.monitor = monitor
        #endif
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        #if canImport(Network)
        monitor?.cancel()
        #endif
    }

    /// Holds a background-execution assertion while flushing, then checkpoints to disk.
    static func flushInBackground(_ pipeline: Pipeline, budget: Duration) {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Raindrop: send queued telemetry") { expired in
            guard !expired else { return }
            // This block runs on a background thread and the assertion lasts until it returns.
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                _ = await pipeline.flush(within: budget)
                await pipeline.checkpoint()
                done.signal()
            }
            _ = done.wait(timeout: .now() + .seconds(Int(budget.components.seconds) + 2))
        }
        #endif
    }
}

/// Tracks connectivity transitions; true when it just came back.
private final class PathState: @unchecked Sendable {
    private let lock = NSLock()
    private var satisfied = true
    func update(satisfied now: Bool) -> Bool {
        lock.withLock {
            defer { satisfied = now }
            return now && !satisfied
        }
    }
}
