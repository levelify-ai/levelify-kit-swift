import Foundation

package struct LKSessionMaterial: Sendable, Equatable {
    package var userId: UUID
    package var isGuest: Bool
    package var accessToken: String

    package init(userId: UUID, isGuest: Bool, accessToken: String) {
        self.userId = userId
        self.isGuest = isGuest
        self.accessToken = accessToken
    }
}

/// Other targets in this package call this. Swift 6 serialises the struct's memberwise `init` as internal, so `LevelifyKitTesting` cannot call it.
package func makeSessionMaterial(userId: UUID, isGuest: Bool, accessToken: String) -> LKSessionMaterial {
    LKSessionMaterial(userId: userId, isGuest: isGuest, accessToken: accessToken)
}

package struct LKTransportError: Error, Sendable {
    package var status: Int
    package var code: String
    package var retryAfter: TimeInterval?
    package var offline: Bool

    package init(status: Int, code: String, retryAfter: TimeInterval? = nil, offline: Bool = false) {
        self.status = status
        self.code = code
        self.retryAfter = retryAfter
        self.offline = offline
    }
}

package protocol LKBackend: Sendable {
    func rpc(name: String, body: Data?, accessToken: String?) async throws -> Data
    func get(url: URL) async throws -> Data
    func signInAnonymously() async throws -> LKSessionMaterial
    func restoreSession() async -> LKSessionMaterial?
    func signOut() async throws
}

/// Synchronous lock. `NSLock` cannot be taken directly inside an async function on Swift 6.2+, and `Mutex` requires iOS 18.
package final class LKLocked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    package init(_ value: Value) { self.value = value }

    package func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

package protocol LKSleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

package struct SystemSleeper: LKSleeper {
    package init() {}
    package func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

package struct NoSleep: LKSleeper {
    package init() {}
    package func sleep(nanoseconds: UInt64) async throws {
        throw CancellationError()
    }
}

package enum LKRetry {
    /// attempt is 1-based. A Retry-After value replaces the schedule for that try.
    package static func delay(attempt: Int, retryAfter: TimeInterval?, jitter: Double) -> TimeInterval {
        if let retryAfter {
            return max(0, retryAfter)
        }
        let schedule = [2.0, 5.0, 15.0, 60.0, 300.0]
        let index = min(max(attempt, 1), schedule.count) - 1
        let clamped = min(0.2, max(-0.2, jitter))
        return schedule[index] * (1 + clamped)
    }
}
