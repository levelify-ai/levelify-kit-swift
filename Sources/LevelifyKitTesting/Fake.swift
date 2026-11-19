import Foundation
import LevelifyKit

/// In-memory transport for tests and previews. No network.
public final class LKFakeBackend: LKBackend, @unchecked Sendable {
    private struct State: Sendable {
        var session: LKSessionMaterial?
        var signIns = 0
        var recorded: [(String, Data)] = []
        var failures: [LKTransportError] = []
        var offline = false
        var files: [String: Data] = [:]
        var reject: Set<String> = []
        var maxAttempts = Int.max
        var configData = Data("{}".utf8)
        var progressData = Data("{}".utf8)
    }

    private let state = LKLocked(State())
    package let userId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    public init() {}

    package var configData: Data {
        get { state.withLock { $0.configData } }
        set { state.withLock { $0.configData = newValue } }
    }

    package var progressData: Data {
        get { state.withLock { $0.progressData } }
        set { state.withLock { $0.progressData = newValue } }
    }

    package func setOffline(_ value: Bool) { state.withLock { $0.offline = value } }
    package func setFiles(_ files: [String: Data]) { state.withLock { $0.files = files } }
    package func failNext(_ errors: [LKTransportError]) { state.withLock { $0.failures = errors } }
    package func rejectIds(_ ids: Set<String>) { state.withLock { $0.reject = ids } }
    package func setAttemptLimit(_ limit: Int) { state.withLock { $0.maxAttempts = limit } }
    package func signInCount() -> Int { state.withLock { $0.signIns } }
    package func calls() -> [(String, Data)] { state.withLock { $0.recorded } }

    package func rpc(name: String, body: Data?, accessToken: String?) async throws -> Data {
        enum Gate: Sendable {
            case offline
            case failure(LKTransportError)
            case ready(config: Data, progress: Data, rejected: Set<String>, limit: Int)
        }
        let gate: Gate = state.withLock { box in
            if box.offline { return .offline }
            if !box.failures.isEmpty { return .failure(box.failures.removeFirst()) }
            box.recorded.append((name, body ?? Data()))
            return .ready(config: box.configData, progress: box.progressData, rejected: box.reject, limit: box.maxAttempts)
        }
        switch gate {
        case .offline:
            throw LKTransportError(status: 0, code: "offline", offline: true)
        case .failure(let error):
            throw error
        case .ready(let config, let progress, let rejected, let limit):
            switch name {
            case LKWire.callGetAppConfig:
                return config
            case LKWire.callGetMyProgress:
                return progress
            case LKWire.callSubmitAttempts:
                return try Self.submitReply(body: body ?? Data(), progress: progress, rejected: rejected, limit: limit)
            default:
                throw LKTransportError(status: 404, code: "unknown_rpc")
            }
        }
    }

    package func get(url: URL) async throws -> Data {
        let result: Result<Data, LKTransportError> = state.withLock { box in
            if box.offline { return .failure(LKTransportError(status: 0, code: "offline", offline: true)) }
            guard let data = box.files[url.absoluteString] else {
                return .failure(LKTransportError(status: 404, code: "not_found"))
            }
            return .success(data)
        }
        return try result.get()
    }

    package func signInAnonymously() async throws -> LKSessionMaterial {
        let material = makeSessionMaterial(userId: userId, isGuest: true, accessToken: "guest-token")
        let offline = state.withLock { box -> Bool in
            if box.offline { return true }
            box.signIns += 1
            box.session = material
            return false
        }
        if offline { throw LKTransportError(status: 0, code: "offline", offline: true) }
        return material
    }

    package func restoreSession() async -> LKSessionMaterial? {
        state.withLock { $0.session }
    }

    package func signOut() async throws {
        state.withLock { $0.session = nil }
    }

    private static func submitReply(body: Data, progress: Data, rejected: Set<String>, limit: Int) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let batch = object?["p_batch"] as? [String: Any]
        let attempts = batch?["attempts"] as? [[String: Any]] ?? []
        if attempts.count > limit {
            throw LKTransportError(status: 400, code: "bad_batch")
        }
        var accepted: [String] = []
        var rejectedItems: [[String: String]] = []
        for item in attempts + (batch?["sessions"] as? [[String: Any]] ?? []) {
            guard let id = item["id"] as? String else { continue }
            if rejected.contains(id.lowercased()) {
                rejectedItems.append(["id": id, "code": "unknown_step"])
            } else {
                accepted.append(id)
            }
        }
        let state = try JSONSerialization.jsonObject(with: progress)
        let reply: [String: Any] = ["accepted": accepted, "rejected": rejectedItems, "state": state]
        return try JSONSerialization.data(withJSONObject: reply)
    }
}

extension LevelifyKit {
    /// A kit with no network, for the app's previews.
    public static func preview() -> LevelifyKit {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levelifykit-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = LevelifyConfig(
            supabaseURL: URL(string: "https://example.invalid")!,
            publishableKey: "preview",
            contentBaseURL: URL(string: "https://example.invalid/content")!,
            client: LKClientInfo(platform: "ios", appVersion: "0.0.0", build: "0"),
            capabilities: .rorkIOS4fe5be7
        )
        return LevelifyKit(backend: LKFakeBackend(), directory: directory, sleeper: NoSleep(), config: config)
    }
}
