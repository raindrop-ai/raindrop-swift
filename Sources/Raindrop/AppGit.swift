import Foundation

/// Application build identity. Values are explicit only: the SDK never inspects a Git
/// checkout or CI environment on its own.
public struct AppGitConfig: Sendable, Equatable {
    /// Full 40- or 64-character hex commit SHA. Other values are ignored with a warning.
    public var commitSha: String?
    public var commitDirty: Bool?
    public var branch: String?
    /// Read `RAINDROP_COMMIT_SHA`, `RAINDROP_COMMIT_DIRTY` and `RAINDROP_BRANCH` for values
    /// not set above. Default true.
    public var useEnvironment: Bool

    public init(commitSha: String? = nil, commitDirty: Bool? = nil, branch: String? = nil, useEnvironment: Bool = true) {
        self.commitSha = commitSha
        self.commitDirty = commitDirty
        self.branch = branch
        self.useEnvironment = useEnvironment
    }
}

/// Resolved once per client: an immutable snapshot of `raindrop.app.*` values.
struct AppGitSnapshot: Sendable {
    static let shaKey = "raindrop.app.commit_sha"
    static let dirtyKey = "raindrop.app.commit_dirty"
    static let branchKey = "raindrop.app.branch"

    let values: [String: JSONValue]

    static let empty = AppGitSnapshot(values: [:])

    static func resolve(_ config: AppGitConfig?, environment: [String: String], log: Log) -> AppGitSnapshot {
        guard let config else { return .empty }
        let env = config.useEnvironment ? environment : [:]
        var values: [String: JSONValue] = [:]

        if let sha = nonEmpty(config.commitSha) ?? nonEmpty(env["RAINDROP_COMMIT_SHA"]) {
            if isValidSha(sha) {
                values[shaKey] = .string(sha)
            } else {
                log.warn("appgit.sha", "ignoring commit SHA that isn't 40 or 64 hex characters")
            }
        }
        if let dirty = config.commitDirty {
            values[dirtyKey] = .bool(dirty)
        } else if let raw = env["RAINDROP_COMMIT_DIRTY"]?.lowercased() {
            if raw == "true" { values[dirtyKey] = .bool(true) }
            if raw == "false" { values[dirtyKey] = .bool(false) }
        }
        if let branch = nonEmpty(config.branch) ?? nonEmpty(env["RAINDROP_BRANCH"]) {
            values[branchKey] = .string(branch)
        }
        return AppGitSnapshot(values: values)
    }

    /// Adds missing keys only: caller properties (including null or "") always win.
    func fill(_ properties: inout [String: JSONValue]) {
        for (key, value) in values where properties[key] == nil {
            properties[key] = value
        }
    }

    static func isValidSha(_ s: String) -> Bool {
        (s.count == 40 || s.count == 64) && s.allSatisfy(\.isHexDigit)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
