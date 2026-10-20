import Foundation

/// File-backed store for payloads that couldn't be sent yet, so they survive the app being
/// suspended, killed or relaunched. Holds already-serialized request bodies only, so a
/// restored payload is resent byte-for-byte (same event ids).
///
/// Bounded: at most `maxBytes` of bodies and records younger than `maxAge`; the oldest go first.
final class Storage: @unchecked Sendable {
    struct Record {
        let route: Route
        let body: Data
        let savedAt: Date
    }

    let fileURL: URL
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let log: Log
    private let lock = NSLock()
    private var lastSignature: Int?

    private let protection: StorageProtection

    init(directory: URL, name: String, maxBytes: Int = 5_000_000, maxAge: TimeInterval = 7 * 86_400,
         protection: StorageProtection = .completeUntilFirstUserAuthentication, log: Log) {
        self.fileURL = directory.appendingPathComponent("\(name).json")
        self.protection = protection
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.log = log
    }

    /// Default location for app platforms: Application Support/Raindrop, excluded from backups.
    static func defaultDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Raindrop", isDirectory: true)
    }

    #if canImport(Darwin)
    var protectionOption: Data.WritingOptions {
        switch protection {
        case .completeUntilFirstUserAuthentication: return .completeFileProtectionUntilFirstUserAuthentication
        case .completeUnlessOpen: return .completeFileProtectionUnlessOpen
        case .complete: return .completeFileProtection
        case .none: return .noFileProtection
        }
    }
    #endif

    /// Stable, non-reversible file name per write key + project, so two clients never share a file.
    static func name(writeKey: String, project: String?) -> String {
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a
        for byte in (writeKey + "|" + (project ?? "")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "queue-" + String(hash, radix: 16)
    }

    /// Reads the file and, only if that worked, deletes it. Returns usable records (oldest
    /// first), `[]` when there's no file, or nil when the file exists but can't be read yet
    /// (e.g. data protection while the device is locked); the file is then left in place.
    func takeAll() -> [Record]? {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                log.warn("storage.read", "offline storage not readable yet (device locked?): \(error.localizedDescription); will retry")
                return nil
            }
            try? FileManager.default.removeItem(at: fileURL)
            lastSignature = nil
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["version"] as? Int == 1,
                  let items = root["records"] as? [[String: Any]] else {
                log.warn("storage.corrupt", "offline storage file was unreadable JSON; discarded")
                return []
            }
            let cutoff = Date().addingTimeInterval(-maxAge)
            return items.compactMap { item in
                guard let r = (item["route"] as? String).flatMap(Route.init(rawValue:)),
                      let b = (item["body"] as? String).flatMap({ Data(base64Encoded: $0) }),
                      let t = item["savedAt"] as? Double else { return nil }
                let savedAt = Date(timeIntervalSince1970: t)
                return savedAt >= cutoff ? Record(route: r, body: b, savedAt: savedAt) : nil
            }
        }
    }

    /// Replaces the file with `records` (or deletes it when empty). Skips the write when
    /// nothing changed since the last one.
    func write(_ records: [Record]) {
        var kept = records
        var total = kept.reduce(0) { $0 + $1.body.count }
        var dropped = 0
        while total > maxBytes, !kept.isEmpty {
            total -= kept.removeFirst().body.count
            dropped += 1
        }
        if dropped > 0 { log.warn("storage.full", "offline storage full; dropped \(dropped) oldest unsent payload(s)") }

        var hasher = Hasher()
        for r in kept {
            hasher.combine(r.route.rawValue)
            hasher.combine(r.body)
        }
        let signature = hasher.finalize()

        lock.withLock {
            guard signature != lastSignature else { return }
            lastSignature = signature
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let items: [JSONValue] = kept.map {
                ["route": .string($0.route.rawValue), "body": .string($0.body.base64EncodedString()),
                 "savedAt": .double($0.savedAt.timeIntervalSince1970)]
            }
            let data = JSONWriter.data(["version": 1, "records": .array(items)])
            do {
                let dir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                #if canImport(Darwin)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableDir = dir
                try? mutableDir.setResourceValues(values)
                try data.write(to: fileURL, options: [.atomic, protectionOption])
                #else
                try data.write(to: fileURL, options: [.atomic])
                #endif
            } catch {
                lastSignature = nil
                log.warn("storage.write", "couldn't save unsent payloads to disk: \(error)")
            }
        }
    }
}
