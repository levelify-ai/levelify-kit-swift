import Foundation

public final class LevelifyKit: Sendable {
    package let runtime: LKRuntime
    public let auth: LKAuth
    public let content: LKContent
    public let progress: LKProgress
    public let config: LKRemoteConfig

    public static func configure(_ config: LevelifyConfig) throws -> LevelifyKit {
        if config.publishableKey.isEmpty { throw LKError.configMissing("publishableKey") }
        if !Self.valid(config.supabaseURL) { throw LKError.configMissing("supabaseURL") }
        if !Self.valid(config.contentBaseURL) { throw LKError.configMissing("contentBaseURL") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("levelifykit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backend = Self.makeBackend(config: config, directory: directory)
        return LevelifyKit(backend: backend, directory: directory, sleeper: SystemSleeper(), config: config, now: { Date() }, timezone: nil, jitter: nil)
    }

    package init(
        backend: any LKBackend,
        directory: URL,
        sleeper: any LKSleeper,
        config: LevelifyConfig,
        now: @escaping @Sendable () -> Date = { Date() },
        timezone: String? = nil,
        jitter: (@Sendable () -> Double)? = nil
    ) {
        let runtime = LKRuntime(
            backend: backend,
            store: LKStore(root: directory),
            sleeper: sleeper,
            config: config,
            now: now,
            timezone: timezone ?? TimeZone.current.identifier,
            jitter: jitter ?? { Double.random(in: -0.2...0.2) }
        )
        self.runtime = runtime
        self.auth = LKAuth(runtime: runtime)
        self.content = LKContent(runtime: runtime)
        self.progress = LKProgress(runtime: runtime)
        self.config = LKRemoteConfig(runtime: runtime)
    }

    private static func valid(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return false }
        return true
    }

    private static func makeBackend(config: LevelifyConfig, directory: URL) -> any LKBackend {
        #if canImport(Supabase)
        return SupabaseBackend(config: config)
        #else
        return HTTPBackend(config: config, directory: directory)
        #endif
    }
}

public actor LKAuth {
    package nonisolated let runtime: LKRuntime

    package init(runtime: LKRuntime) { self.runtime = runtime }

    public func confirmAgeGate(minorUntil: LKMonth?) async {
        await runtime.confirmAgeGate(minorUntil)
    }

    public var ageGateConfirmed: Bool {
        get async { await runtime.ageConfirmed() }
    }

    public var currentUser: LKUser? {
        get async { await runtime.currentUser() }
    }

    public func ensureSession() async throws -> LKUser {
        try await runtime.ensureSession()
    }

    public func signOut() async throws {
        try await runtime.signOut()
    }

    public nonisolated var userChanges: AsyncStream<LKUser?> {
        AsyncStream { continuation in
            Task { await runtime.addUser(continuation) }
        }
    }
}

public actor LKRemoteConfig {
    private let runtime: LKRuntime

    package init(runtime: LKRuntime) { self.runtime = runtime }

    @discardableResult
    public func refresh() async throws -> LKAppConfig {
        try await runtime.refreshConfig()
    }

    public var current: LKAppConfig {
        get async { await runtime.currentConfig() }
    }
}

public actor LKContent {
    private let runtime: LKRuntime

    package init(runtime: LKRuntime) { self.runtime = runtime }

    @discardableResult
    public func refresh() async throws -> LKManifest {
        try await runtime.refreshContent()
    }

    public var manifest: LKManifest? {
        get async { await runtime.currentManifest() }
    }

    public func lesson(id: String) async throws -> LKLessonFile {
        try await runtime.lesson(id: id)
    }

    public func trackDocument(trackId: String, lessonIds: [String]) async throws -> Data {
        try await runtime.trackDocument(trackId: trackId, lessonIds: lessonIds)
    }

    public func plan(_ lesson: LKLessonFile) async -> LKLessonPlan {
        await runtime.plan(lesson)
    }

    public func prefetch(lessonIds: [String]) async {
        await runtime.prefetch(lessonIds: lessonIds)
    }

    public func isAvailableOffline(lessonId: String) async -> Bool {
        await runtime.isAvailableOffline(lessonId: lessonId)
    }

    package func setRefreshInterval(_ interval: TimeInterval) async {
        await runtime.setRefreshInterval(interval)
    }

    package func preloadPlayer() async {
        await runtime.preloadPlayer()
    }

    package func stepContext(_ lesson: LKLessonFile, stepId: String) async -> PlayerStepContext {
        await runtime.stepContext(lesson, stepId: stepId)
    }

    package func playerBuildFile(_ name: String) async -> Data? {
        await runtime.playerBuildFile(name)
    }

    package func playerMediaFile(sha256: String) async -> Data? {
        await runtime.playerMediaFile(sha256: sha256)
    }
}

public actor LKProgress {
    package nonisolated let runtime: LKRuntime

    package init(runtime: LKRuntime) { self.runtime = runtime }

    public func record(_ attempt: LKAttempt) async {
        await runtime.record(attempt)
    }

    public func complete(_ session: LKSessionCompletion) async {
        await runtime.complete(session)
    }

    @discardableResult
    public func flush() async -> LKSyncResult {
        await runtime.flush()
    }

    public func state() async throws -> LKProgressState {
        try await runtime.state()
    }

    public var pendingCount: Int {
        get async { await runtime.pendingCount() }
    }

    public nonisolated var stateChanges: AsyncStream<LKProgressState> {
        AsyncStream { continuation in
            Task { await runtime.addState(continuation) }
        }
    }
}
