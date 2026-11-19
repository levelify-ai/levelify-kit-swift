import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

package struct LessonEntry: Sendable, Equatable {
    package var id: String
    package var path: String
    package var sha256: String
    package var trackId: String
    package var unitId: String
    package var media: [MediaEntry]
    package var needsPlayer: Bool
}

package struct MediaEntry: Sendable, Equatable {
    package var path: String
    package var sha256: String
    package var ext: String
}

package struct UnitEntry: Sendable, Equatable {
    package var id: String
    package var tier: Int
    package var title: String
    package var summary: String
    package var lessonIds: [String]
}

package struct TrackEntry: Sendable, Equatable {
    package var id: String
    package var title: String
    package var subtitle: String
    package var symbol: String
    package var units: [UnitEntry]
}

package struct PlayerEntry: Sendable, Equatable {
    package var buildId: String
    package var entry: String
    package var stepTypes: [String: Int]
    package var bridgeVersions: [Int]
    package var files: [MediaEntry]
}

package struct ManifestDoc: Sendable, Equatable {
    package var lessons: [String: LessonEntry]
    package var tracks: [TrackEntry]
    package var player: PlayerEntry?

    package var lessonIds: [String] {
        tracks.flatMap { track in track.units.flatMap(\.lessonIds) }
    }
}

package struct PlayerStepContext: Sendable {
    package var lessonId: String
    package var lessonVersion: String
    package var step: [String: LKJSON]
    package var media: [String: String]
    package var filesReady: Bool
}

package actor LKRuntime {
    let backend: any LKBackend
    let store: LKStore
    let sleeper: any LKSleeper
    let client: LKClientInfo
    let capabilities: LKCapabilities
    let contentBase: URL
    let timezone: String
    var now: @Sendable () -> Date
    var jitter: @Sendable () -> Double
    var refreshInterval: TimeInterval
    private var lastRefresh: Date?
    private var config: LKAppConfig
    private var manifest: ManifestDoc?
    private var session: LKSessionMaterial?
    private var lastState: LKProgressState?
    private var userWaiters: [UUID: AsyncStream<LKUser?>.Continuation] = [:]
    private var stateWaiters: [UUID: AsyncStream<LKProgressState>.Continuation] = [:]
    private var flushing = false
    private var flushWaiters: [CheckedContinuation<LKSyncResult, Never>] = []
    private var retryAttempt = 0
    private var debounceGeneration = 0
    private let attemptLimit = 200
    private let sessionLimit = 50

    package init(
        backend: any LKBackend,
        store: LKStore,
        sleeper: any LKSleeper,
        config: LevelifyConfig,
        now: @escaping @Sendable () -> Date,
        timezone: String,
        jitter: @escaping @Sendable () -> Double
    ) {
        self.backend = backend
        self.store = store
        self.sleeper = sleeper
        self.client = config.client
        self.capabilities = config.capabilities
        self.contentBase = config.contentBaseURL
        self.timezone = timezone
        self.now = now
        self.jitter = jitter
        self.refreshInterval = 300
        if let data = store.savedConfig(), let saved = try? LKCoding.decode(LKAppConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .builtIn
        }
        if let data = store.savedManifest(), let saved = try? Self.parseManifest(data) {
            self.manifest = saved
        }
        if let data = store.savedState(), let saved = try? LKCoding.decode(LKProgressState.self, from: data) {
            self.lastState = saved
        }
    }

    package func confirmAgeGate(_ minorUntil: LKMonth?) {
        store.setAgeGate(confirmed: true, minorUntil: minorUntil)
        if store.count() > 0 {
            Task { _ = await self.flush() }
        }
    }

    package func ageConfirmed() -> Bool { store.ageGate().confirmed }

    package func currentUser() async -> LKUser? {
        if let session { return user(session) }
        if let restored = await backend.restoreSession() {
            session = restored
            return user(restored)
        }
        return nil
    }

    package func ensureSession() async throws -> LKUser {
        guard store.ageGate().confirmed else { throw LKError.ageGateRequired }
        if let session { return user(session) }
        if let restored = await backend.restoreSession() {
            session = restored
            return user(restored)
        }
        do {
            let created = try await backend.signInAnonymously()
            session = created
            let signedIn = user(created)
            yieldUser(signedIn)
            return signedIn
        } catch {
            throw map(error)
        }
    }

    package func signOut() async throws {
        try await backend.signOut()
        session = nil
        yieldUser(nil)
    }

    package func addUser(_ continuation: AsyncStream<LKUser?>.Continuation) {
        let id = UUID()
        userWaiters[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.removeUser(id) }
        }
    }

    package func currentConfig() -> LKAppConfig { config }

    package func refreshConfig() async throws -> LKAppConfig {
        let data: Data
        do {
            data = try await backend.rpc(name: LKWire.callGetAppConfig, body: Data("{}".utf8), accessToken: nil)
        } catch {
            throw map(error)
        }
        let decoded: LKAppConfig
        do {
            decoded = try LKCoding.decode(LKAppConfig.self, from: data)
        } catch {
            throw LKError.server(code: "bad_config", status: 200)
        }
        config = decoded
        store.saveConfig(data)
        return decoded
    }

    package func setRefreshInterval(_ interval: TimeInterval) { refreshInterval = interval }

    package func refreshContent() async throws -> LKManifest {
        if let lastRefresh, let manifest, now().timeIntervalSince(lastRefresh) < refreshInterval {
            return publicManifest(manifest)
        }
        _ = try await refreshConfig()
        guard let pointer = config.content else { throw LKError.notFound("content") }
        let data = try await download(path: pointer.manifestPath, sha: pointer.manifestSha256)
        let parsed = try Self.parseManifest(data)
        manifest = parsed
        store.saveManifest(data)
        lastRefresh = now()
        if let player = parsed.player {
            for file in player.files {
                _ = try? await download(path: file.path, sha: file.sha256)
            }
        }
        return publicManifest(parsed)
    }

    package func currentManifest() -> LKManifest? {
        manifest.map(publicManifest)
    }

    package func lesson(id: String) async throws -> LKLessonFile {
        guard let entry = manifest?.lessons[id] else { throw LKError.notFound(id) }
        let data = try await download(path: entry.path, sha: entry.sha256)
        for media in entry.media {
            _ = try? await download(path: media.path, sha: media.sha256)
        }
        let decoded = LessonPlanner.decodedLesson(data: data, caps: capabilities)
            ?? LKLesson(id: id, title: "", symbol: "", formatVersion: 1, steps: [])
        return LKLessonFile(id: id, version: SHA256.hex(data), data: data, lesson: decoded)
    }

    package func trackDocument(trackId: String, lessonIds: [String]) async throws -> Data {
        guard let track = manifest?.tracks.first(where: { $0.id == trackId }) else { throw LKError.notFound(trackId) }
        var units: [[String: Any]] = []
        for unit in track.units {
            var lessons: [Any] = []
            for id in unit.lessonIds where lessonIds.contains(id) {
                let file = try await lesson(id: id)
                let object = try JSONSerialization.jsonObject(with: file.data)
                lessons.append(object)
            }
            if lessons.isEmpty { continue }
            units.append([
                "id": unit.id,
                "tier": unit.tier,
                "title": unit.title,
                "summary": unit.summary,
                "lessons": lessons,
            ])
        }
        if units.isEmpty { throw LKError.notFound(lessonIds.first ?? trackId) }
        let document: [String: Any] = [
            "id": track.id,
            "title": track.title,
            "subtitle": track.subtitle,
            "symbol": track.symbol,
            "units": units,
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }

    package func plan(_ lesson: LKLessonFile) -> LKLessonPlan {
        LessonPlanner.hostPlan(
            lesson: lesson.data,
            shell: capabilities,
            playerStepTypes: manifest?.player?.stepTypes ?? [:],
            playerAvailable: playerReady()
        )
    }

    package func prefetch(lessonIds: [String]) async {
        for id in lessonIds {
            _ = try? await lesson(id: id)
        }
        await preloadPlayer()
    }

    package func isAvailableOffline(lessonId: String) -> Bool {
        guard let sha = manifest?.lessons[lessonId]?.sha256, let data = store.file(sha: sha) else { return false }
        return SHA256.hex(data) == sha.lowercased()
    }

    package func preloadPlayer() async {
        guard let player = manifest?.player, config.killSwitches["player"] != true else { return }
        for file in player.files {
            _ = try? await download(path: file.path, sha: file.sha256)
        }
    }

    package func stepContext(_ lesson: LKLessonFile, stepId: String) -> PlayerStepContext {
        let entry = manifest?.lessons[lesson.id]
        let step = Self.stepObject(lesson.data, stepId: stepId)
        var media: [String: String] = [:]
        var mediaReady = true
        for item in entry?.media ?? [] {
            media[item.sha256] = "levelify-player://player/media/\(item.sha256).\(item.ext)"
            if store.file(sha: item.sha256) == nil { mediaReady = false }
        }
        return PlayerStepContext(
            lessonId: lesson.id,
            lessonVersion: lesson.version,
            step: step,
            media: media,
            filesReady: playerReady() && mediaReady
        )
    }

    package func playerBuildFile(_ name: String) -> Data? {
        guard let player = manifest?.player else { return nil }
        guard let match = player.files.first(where: { flatName($0.path) == name }) else { return nil }
        return verified(sha: match.sha256)
    }

    package func playerMediaFile(sha256: String) -> Data? {
        verified(sha: sha256)
    }

    private func verified(sha: String) -> Data? {
        guard let data = store.file(sha: sha), SHA256.hex(data) == sha.lowercased() else { return nil }
        return data
    }

    private func flatName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    package func record(_ attempt: LKAttempt) {
        store.append(OutboxItem(kind: .attempt, attempt: attempt, session: nil))
        debounceGeneration += 1
        let generation = debounceGeneration
        Task {
            do { try await self.sleeper.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await self.flushIfCurrent(generation)
        }
    }

    private func flushIfCurrent(_ generation: Int) async {
        guard generation == debounceGeneration else { return }
        _ = await flush()
    }

    package func complete(_ session: LKSessionCompletion) async {
        store.append(OutboxItem(kind: .session, attempt: nil, session: session))
        _ = await flush()
    }

    package func flush() async -> LKSyncResult {
        if flushing {
            return await withCheckedContinuation { flushWaiters.append($0) }
        }
        flushing = true
        let result = await performFlush()
        flushing = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }

    package func state() async throws -> LKProgressState {
        if session == nil, let restored = await backend.restoreSession() {
            session = restored
        }
        guard let session else { throw LKError.server(code: "not_authenticated", status: 401) }
        do {
            let data = try await backend.rpc(name: LKWire.callGetMyProgress, body: Data("{}".utf8), accessToken: session.accessToken)
            let decoded = try LKCoding.decode(LKProgressState.self, from: data)
            remember(decoded, data: data)
            return decoded
        } catch let error as LKTransportError where error.offline {
            if let lastState { return lastState }
            throw LKError.offline
        } catch let error as LKTransportError {
            throw LKError.server(code: error.code, status: error.status)
        } catch {
            throw map(error)
        }
    }

    package func pendingCount() -> Int { store.count() }

    package func addState(_ continuation: AsyncStream<LKProgressState>.Continuation) {
        let id = UUID()
        stateWaiters[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.removeState(id) }
        }
    }

    private func performFlush() async -> LKSyncResult {
        if config.killSwitches["sync"] == true {
            return LKSyncResult(sent: 0, accepted: 0, rejected: [], remaining: store.count(), error: nil)
        }
        if store.count() == 0 {
            return LKSyncResult(sent: 0, accepted: 0, rejected: [], remaining: 0, error: nil)
        }
        do {
            _ = try await ensureSession()
        } catch let error as LKError {
            return LKSyncResult(sent: 0, accepted: 0, rejected: [], remaining: store.count(), error: error)
        } catch {
            return LKSyncResult(sent: 0, accepted: 0, rejected: [], remaining: store.count(), error: map(error))
        }

        var sent = 0
        var accepted = 0
        var rejected: [(id: UUID, code: String)] = []
        while !store.outbox().isEmpty {
            var slice = Self.prefix(store.outbox(), attempts: attemptLimit, sessions: sessionLimit)
            if slice.isEmpty { break }
            var authRetries = 0
            var sentThis = false
            while !sentThis {
                do {
                    let reply = try await submit(slice)
                    let removed = apply(reply)
                    if removed.isEmpty {
                        return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: .server(code: "empty_accept", status: 200))
                    }
                    sent += slice.count
                    accepted += reply.accepted.count
                    rejected.append(contentsOf: reply.rejected.compactMap { item in
                        guard let id = UUID(uuidString: item.id) else { return nil }
                        return (id: id, code: item.code)
                    })
                    retryAttempt = 0
                    sentThis = true
                } catch let error as LKTransportError {
                    if error.code == "not_authenticated", authRetries < 1 {
                        authRetries += 1
                        self.session = nil
                        do { _ = try await ensureSession() } catch {
                            return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: map(error))
                        }
                        continue
                    }
                    if (error.code == "bad_batch" || error.code == "batch_too_large"), slice.count > 1 {
                        slice = Array(slice.prefix(max(1, slice.count / 2)))
                        continue
                    }
                    if error.offline || error.status == 0 || error.status == 429 || error.status >= 500 {
                        scheduleBackoff(retryAfter: error.retryAfter)
                        let mapped: LKError = error.offline || error.status == 0 ? .offline : .server(code: error.code, status: error.status)
                        return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: mapped)
                    }
                    return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: .server(code: error.code, status: error.status))
                } catch {
                    return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: map(error))
                }
            }
        }
        return LKSyncResult(sent: sent, accepted: accepted, rejected: rejected, remaining: store.count(), error: nil)
    }

    private func submit(_ items: [OutboxItem]) async throws -> SubmitReply {
        let batch = SubmitBatch(
            client: client.headerValue,
            timezone: timezone,
            attempts: items.compactMap(\.attempt).map(LKWire.attempt),
            sessions: items.compactMap(\.session).map(LKWire.session)
        )
        let body = try LKWire.encodeEnvelope(batch)
        let data = try await backend.rpc(name: LKWire.callSubmitAttempts, body: body, accessToken: session?.accessToken)
        do {
            return try LKCoding.decode(SubmitReply.self, from: data)
        } catch {
            throw LKTransportError(status: 200, code: "bad_response")
        }
    }

    private func apply(_ reply: SubmitReply) -> Set<UUID> {
        var ids = Set(reply.accepted.compactMap { UUID(uuidString: $0) })
        for item in reply.rejected {
            if let id = UUID(uuidString: item.id) { ids.insert(id) }
        }
        store.remove(ids: ids)
        if let data = try? LKCoding.encoder().encode(reply.state) {
            remember(reply.state, data: data)
        }
        return ids
    }

    private func scheduleBackoff(retryAfter: TimeInterval?) {
        retryAttempt += 1
        let delay = LKRetry.delay(attempt: retryAttempt, retryAfter: retryAfter, jitter: jitter())
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        Task {
            do { try await self.sleeper.sleep(nanoseconds: nanos) } catch { return }
            _ = await self.flush()
        }
    }

    private func download(path: String, sha: String) async throws -> Data {
        let expected = sha.lowercased()
        if let cached = store.file(sha: expected), SHA256.hex(cached) == expected { return cached }
        guard let url = Self.join(contentBase, path) else { throw LKError.notFound(path) }
        let data: Data
        do {
            data = try await backend.get(url: url)
        } catch {
            throw map(error)
        }
        guard SHA256.hex(data) == expected else { throw LKError.integrity(path) }
        store.saveFile(sha: expected, data: data)
        return data
    }

    private func playerReady() -> Bool {
        guard config.killSwitches["player"] != true, let player = manifest?.player, !player.files.isEmpty else { return false }
        return player.files.allSatisfy { store.file(sha: $0.sha256) != nil }
    }

    private func remember(_ state: LKProgressState, data: Data) {
        lastState = state
        store.saveState(data)
        for waiter in stateWaiters.values { waiter.yield(state) }
    }

    private func yieldUser(_ user: LKUser?) {
        for waiter in userWaiters.values { waiter.yield(user) }
    }

    private func removeUser(_ id: UUID) { userWaiters[id] = nil }
    private func removeState(_ id: UUID) { stateWaiters[id] = nil }

    private func user(_ session: LKSessionMaterial) -> LKUser {
        LKUser(id: session.userId, isGuest: session.isGuest)
    }

    private func publicManifest(_ doc: ManifestDoc) -> LKManifest {
        LKManifest(version: 1, lessonIds: doc.lessonIds)
    }

    private func map(_ error: Error) -> LKError {
        if let error = error as? LKError { return error }
        if let error = error as? LKTransportError {
            if error.offline || error.status == 0 { return .offline }
            return .server(code: error.code, status: error.status)
        }
        return .server(code: "transport", status: 0)
    }

    private static func prefix(_ items: [OutboxItem], attempts: Int, sessions: Int) -> [OutboxItem] {
        var taken: [OutboxItem] = []
        var attemptCount = 0
        var sessionCount = 0
        for item in items {
            if item.kind == .attempt {
                if attemptCount == attempts { break }
                attemptCount += 1
            } else {
                if sessionCount == sessions { break }
                sessionCount += 1
            }
            taken.append(item)
        }
        return taken
    }

    private static func join(_ base: URL, _ path: String) -> URL? {
        let root = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: root + trimmed)
    }

    private static func stepObject(_ data: Data, stepId: String) -> [String: LKJSON] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exercises = root["exercises"] as? [[String: Any]],
              let step = exercises.first(where: { $0["id"] as? String == stepId }),
              let body = try? JSONSerialization.data(withJSONObject: step),
              let json = try? LKCoding.decode(LKJSON.self, from: body),
              case .object(let object) = json else { return [:] }
        return object
    }

    package static func parseManifest(_ data: Data) throws -> ManifestDoc {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LKError.integrity("manifest")
        }
        let version = lkInt(root["manifestVersion"]) ?? -1
        guard version == 1 else { throw LKError.unsupportedManifest(version) }
        guard let tracks = root["tracks"] as? [[String: Any]] else { throw LKError.integrity("manifest") }
        var lessonMap: [String: LessonEntry] = [:]
        var trackEntries: [TrackEntry] = []
        for track in tracks {
            guard let trackId = track["id"] as? String,
                  let title = track["title"] as? String,
                  let subtitle = track["subtitle"] as? String,
                  let symbol = track["symbol"] as? String,
                  let units = track["units"] as? [[String: Any]] else { throw LKError.integrity("manifest") }
            var unitEntries: [UnitEntry] = []
            for unit in units {
                guard let unitId = unit["id"] as? String,
                      let tier = lkInt(unit["tier"]),
                      let unitTitle = unit["title"] as? String,
                      let summary = unit["summary"] as? String,
                      let lessons = unit["lessons"] as? [[String: Any]] else { throw LKError.integrity("manifest") }
                var ids: [String] = []
                for lesson in lessons {
                    guard let id = lesson["id"] as? String,
                          let path = lesson["path"] as? String,
                          let sha = lesson["sha256"] as? String else { throw LKError.integrity("manifest") }
                    ids.append(id)
                    var media: [MediaEntry] = []
                    for item in (lesson["media"] as? [[String: Any]]) ?? [] {
                        guard let mediaPath = item["path"] as? String, let mediaSha = item["sha256"] as? String else { continue }
                        let ext = (mediaPath as NSString).pathExtension.isEmpty ? "bin" : (mediaPath as NSString).pathExtension
                        media.append(MediaEntry(path: mediaPath, sha256: mediaSha.lowercased(), ext: ext))
                    }
                    lessonMap[id] = LessonEntry(
                        id: id,
                        path: path,
                        sha256: sha.lowercased(),
                        trackId: trackId,
                        unitId: unitId,
                        media: media,
                        needsPlayer: lesson["needsPlayer"] as? Bool ?? false
                    )
                }
                unitEntries.append(UnitEntry(id: unitId, tier: tier, title: unitTitle, summary: summary, lessonIds: ids))
            }
            trackEntries.append(TrackEntry(id: trackId, title: title, subtitle: subtitle, symbol: symbol, units: unitEntries))
        }
        return ManifestDoc(lessons: lessonMap, tracks: trackEntries, player: playerEntry(root["player"]))
    }

    private static func playerEntry(_ value: Any?) -> PlayerEntry? {
        guard let player = value as? [String: Any],
              let buildId = player["buildId"] as? String,
              let entry = player["entry"] as? String,
              let files = player["files"] as? [[String: Any]] else { return nil }
        var stepTypes: [String: Int] = [:]
        for (key, version) in (player["stepTypes"] as? [String: Any]) ?? [:] {
            if let number = lkInt(version) { stepTypes[key] = number }
        }
        let bridges = (player["bridgeVersions"] as? [Any])?.compactMap(lkInt) ?? []
        let parsed = files.compactMap { file -> MediaEntry? in
            guard let path = file["path"] as? String, let sha = file["sha256"] as? String else { return nil }
            return MediaEntry(path: path, sha256: sha.lowercased(), ext: "")
        }
        return PlayerEntry(buildId: buildId, entry: entry, stepTypes: stepTypes, bridgeVersions: bridges, files: parsed)
    }
}

private func lkIsBool(_ value: Any) -> Bool {
    #if canImport(CoreFoundation)
    if let object = value as? NSObject {
        let ref = object as CFTypeRef
        if CFGetTypeID(ref) == CFBooleanGetTypeID() { return true }
    }
    #endif
    if let number = value as? NSNumber {
        let kind = String(cString: number.objCType)
        if kind == "c" || kind == "B" { return true }
    }
    return false
}

private func lkInt(_ value: Any?) -> Int? {
    guard let value, !lkIsBool(value) else { return nil }
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Int { return number }
    return nil
}
