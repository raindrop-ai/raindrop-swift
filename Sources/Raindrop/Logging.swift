import Foundation

/// Logger with per-key rate limiting so a broken network can't flood the host's logs.
/// Warnings are never suppressed entirely: the first one per key per minute is emitted.
final class Log: @unchecked Sendable {
    private let debugEnabled: Bool
    private let handler: @Sendable (LogLevel, String) -> Void
    private let lock = NSLock()
    private var lastEmitted: [String: ContinuousClock.Instant] = [:]
    private let window: Duration = .seconds(60)

    init(debug: Bool, handler: (@Sendable (LogLevel, String) -> Void)?) {
        self.debugEnabled = debug
        self.handler = handler ?? { level, message in
            FileHandle.standardError.write(Data("[raindrop] \(level.rawValue): \(message)\n".utf8))
        }
    }

    func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        handler(.debug, message())
    }

    func warn(_ key: String, _ message: @autoclosure () -> String) {
        let now = ContinuousClock.now
        let emit: Bool = lock.withLock {
            if let last = lastEmitted[key], now - last < window { return false }
            lastEmitted[key] = now
            return true
        }
        if emit { handler(.warning, message()) }
    }
}
