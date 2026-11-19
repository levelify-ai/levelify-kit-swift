import Foundation
import Testing
import LevelifyKit
import LevelifyPlayerHost
import LevelifyKitTesting

@Test func sha256MatchesKnownVectors() {
    #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func configureRejectsEmptyValues() {
    let config = LevelifyConfig(
        supabaseURL: URL(string: "https://example.invalid")!,
        publishableKey: "",
        contentBaseURL: URL(string: "https://content.test/base")!,
        client: LKClientInfo(platform: "ios", appVersion: "0.4.0", build: "12"),
        capabilities: .rorkIOS4fe5be7
    )
    #expect(throws: LKError.configMissing("publishableKey")) {
        _ = try LevelifyKit.configure(config)
    }
}

@Test func remoteConfigStartsAtBuiltInDefaults() async {
    let (_, kit) = makeKit()
    let current = await kit.config.current
    #expect(current.serverTime == nil)
    #expect(current.content == nil)
    #expect(current.minClientVersion["ios"] == "0.0.0")
    #expect(current.limits == LKLimits(mode: "dailyLessonCap", value: 3))
    #expect(current.killSwitches["player"] == false)
    #expect(current.killSwitches["sync"] == false)
    #expect(current.flags["leagues"] == false)
}

@Test func stateDoesNotCreateASession() async {
    let (fake, kit) = makeKit()
    await #expect(throws: LKError.server(code: "not_authenticated", status: 401)) {
        try await kit.progress.state()
    }
    #expect(fake.signInCount() == 0)
}

@Test func ageGateBlocksTheFirstSignIn() async throws {
    let (fake, kit) = makeKit()
    await kit.progress.record(sampleAttempt())
    let blocked = await kit.progress.flush()
    #expect(blocked.error == .ageGateRequired)
    #expect(fake.signInCount() == 0)
    #expect(await kit.progress.pendingCount == 1)

    await kit.auth.confirmAgeGate(minorUntil: LKMonth(year: 2010, month: 4))
    #expect(await kit.auth.ageGateConfirmed)
    // confirmAgeGate starts a flush when the outbox is nonempty. That flush and this one coalesce.
    let sent = await kit.progress.flush()
    #expect(sent.error == nil)
    #expect(await kit.progress.pendingCount == 0)
    #expect(fake.signInCount() == 1)
    #expect(fake.calls().filter { $0.0 == LKWire.callSubmitAttempts }.count == 1)
    #expect(await kit.auth.currentUser?.isGuest == true)
}

@Test func outboxSurvivesARestartAndSendsOnce() async throws {
    let fake = LKFakeBackend()
    fake.progressData = progressJSON(extra: [:])
    fake.configData = configData(manifestSha: "abc")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levelifykit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let kit = LevelifyKit(backend: fake, directory: directory, sleeper: NoSleep(), config: sampleConfig())
    await kit.auth.confirmAgeGate(minorUntil: nil)
    await kit.progress.record(sampleAttempt(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    #expect(await kit.progress.pendingCount == 1)

    let restarted = LevelifyKit(backend: fake, directory: directory, sleeper: NoSleep(), config: sampleConfig())
    let first = await restarted.progress.flush()
    #expect(first.accepted == 1)
    #expect(await restarted.progress.pendingCount == 0)
    let second = await restarted.progress.flush()
    #expect(second.sent == 0)
    #expect(fake.calls().filter { $0.0 == LKWire.callSubmitAttempts }.count == 1)
}

@Test func rejectedItemsLeaveTheOutbox() async throws {
    let (fake, kit) = makeKit()
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    fake.rejectIds([id.uuidString.lowercased()])
    await kit.auth.confirmAgeGate(minorUntil: nil)
    await kit.progress.record(sampleAttempt(id: id))
    let result = await kit.progress.flush()
    #expect(result.accepted == 0)
    #expect(result.rejected.count == 1)
    #expect(result.rejected[0].code == "unknown_step")
    #expect(await kit.progress.pendingCount == 0)
}

@Test func badBatchIsSplitAndStillSent() async throws {
    let (fake, kit) = makeKit()
    fake.setAttemptLimit(1)
    await kit.auth.confirmAgeGate(minorUntil: nil)
    await kit.progress.record(sampleAttempt(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!))
    await kit.progress.record(sampleAttempt(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!))
    let result = await kit.progress.flush()
    #expect(result.error == nil)
    #expect(result.accepted == 2)
    #expect(await kit.progress.pendingCount == 0)
    #expect(fake.calls().filter { $0.0 == LKWire.callSubmitAttempts }.count >= 2)
}

@Test func offlineFlushKeepsTheItem() async throws {
    let (fake, kit) = makeKit()
    await kit.auth.confirmAgeGate(minorUntil: nil)
    await kit.progress.record(sampleAttempt())
    fake.setOffline(true)
    let failed = await kit.progress.flush()
    #expect(failed.error == .offline)
    #expect(await kit.progress.pendingCount == 1)
    fake.setOffline(false)
    let sent = await kit.progress.flush()
    #expect(sent.accepted == 1)
    #expect(await kit.progress.pendingCount == 0)
}

@Test func contentKeepsLastGoodManifestAndRejectsATamperedLesson() async throws {
    let (fake, kit) = makeKit()
    let lesson = Data("{\"id\":\"aut-l2-u1-l1\",\"title\":\"Map\",\"symbol\":\"gear\",\"formatVersion\":1,\"exercises\":[]}".utf8)
    let lessonSha = SHA256.hex(lesson)
    let manifest = manifestData(lessonSha: lessonSha, lessonBytes: lesson.count)
    let manifestSha = SHA256.hex(manifest)
    var files = [
        "https://content.test/base/manifests/\(manifestSha).json": manifest,
        "https://content.test/base/lessons/aut-l2-u1-l1/\(lessonSha).json": lesson,
    ]
    fake.setFiles(files)
    fake.configData = configData(manifestSha: manifestSha)
    let loaded = try await kit.content.refresh()
    #expect(loaded.lessonIds == ["aut-l2-u1-l1"])
    let file = try await kit.content.lesson(id: "aut-l2-u1-l1")
    #expect(file.id == "aut-l2-u1-l1")
    #expect(file.version == lessonSha)

    let tamperedFake = LKFakeBackend()
    var tamperedFiles = files
    tamperedFiles["https://content.test/base/lessons/aut-l2-u1-l1/\(lessonSha).json"] = Data("tampered".utf8)
    tamperedFake.setFiles(tamperedFiles)
    tamperedFake.configData = configData(manifestSha: manifestSha)
    let tamperedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("levelifykit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tamperedDirectory, withIntermediateDirectories: true)
    let tampered = LevelifyKit(backend: tamperedFake, directory: tamperedDirectory, sleeper: NoSleep(), config: sampleConfig())
    _ = try await tampered.content.refresh()
    await #expect(throws: LKError.integrity("lessons/aut-l2-u1-l1/\(lessonSha).json")) {
        try await tampered.content.lesson(id: "aut-l2-u1-l1")
    }

    files["https://content.test/base/lessons/aut-l2-u1-l1/\(lessonSha).json"] = Data("tampered".utf8)
    fake.setFiles(files)
    await kit.content.setRefreshInterval(0)
    let badManifest = manifestData(lessonSha: SHA256.hex(Data("other".utf8)), lessonBytes: 5)
    let badSha = SHA256.hex(badManifest)
    fake.configData = configData(manifestSha: badSha)
    var badFiles = files
    badFiles["https://content.test/base/manifests/\(badSha).json"] = Data("not-the-manifest".utf8)
    fake.setFiles(badFiles)
    await #expect(throws: LKError.integrity("manifests/\(badSha).json")) {
        try await kit.content.refresh()
    }
    #expect(await kit.content.manifest?.lessonIds == ["aut-l2-u1-l1"])
}

@Test func threeRpcNamesAreIndependentLiterals() async throws {
    // These strings are the contract in docs/08 §5.1. They are not read from the production constants.
    let getAppConfig = "get_app_config"
    let submitAttempts = "submit_attempts"
    let getMyProgress = "get_my_progress"
    #expect(LKWire.callGetAppConfig == getAppConfig)
    #expect(LKWire.callSubmitAttempts == submitAttempts)
    #expect(LKWire.callGetMyProgress == getMyProgress)

    let (fake, kit) = makeKit()
    _ = try await kit.config.refresh()
    await kit.auth.confirmAgeGate(minorUntil: nil)
    await kit.progress.record(sampleAttempt())
    let flushed = await kit.progress.flush()
    #expect(flushed.error == nil)
    let state = try await kit.progress.state()
    #expect(state.xpTotal == 25)

    let names = fake.calls().map(\.0)
    #expect(names.contains(getAppConfig))
    #expect(names.contains(submitAttempts))
    #expect(names.contains(getMyProgress))
    let allowed: Set<String> = [getAppConfig, submitAttempts, getMyProgress]
    #expect(names.allSatisfy { allowed.contains($0) })

    let configBody = try #require(fake.calls().first { $0.0 == getAppConfig }?.1)
    #expect(String(decoding: configBody, as: UTF8.self) == "{}")
    let progressBody = try #require(fake.calls().first { $0.0 == getMyProgress }?.1)
    #expect(String(decoding: progressBody, as: UTF8.self) == "{}")
    let submitBody = try #require(fake.calls().first { $0.0 == submitAttempts }?.1)
    let submit = try #require(JSONSerialization.jsonObject(with: submitBody) as? [String: Any])
    let liveBatch = try #require(submit["p_batch"] as? [String: Any])
    #expect(liveBatch["attempts"] != nil)
    #expect(liveBatch["sessions"] != nil)
}

@Test func submitEnvelopeUsesTheDocumentedBatch() throws {
    let attempt = sampleAttempt(id: UUID(uuidString: "0B8F0000-0000-0000-0000-000000000001")!)
    let ungraded = LKAttempt(
        id: UUID(uuidString: "0B8F0000-0000-0000-0000-000000000003")!,
        sessionId: UUID(uuidString: "6D2A0000-0000-0000-0000-000000000002")!,
        lessonId: "aut-l2-u1-l1",
        lessonVersion: nil,
        stepId: "aut-l2-u1-l1-e2",
        position: 1,
        mode: .lesson,
        response: .none,
        correct: nil,
        answeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let session = LKSessionCompletion(
        id: UUID(uuidString: "6D2A0000-0000-0000-0000-000000000002")!,
        mode: .lesson,
        lessonId: "aut-l2-u1-l1",
        lessonVersion: "abc",
        unitId: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        completedAt: Date(timeIntervalSince1970: 60),
        stepCount: 1
    )
    let batch = SubmitBatch(
        client: "ios/0.4.0(12) levelifykit/0.1.0",
        timezone: "Europe/Madrid",
        attempts: [LKWire.attempt(attempt), LKWire.attempt(ungraded)],
        sessions: [LKWire.session(session)]
    )
    let data = try LKWire.encodeEnvelope(batch)
    let text = String(decoding: data, as: UTF8.self)
    // An integer. `"stepCount":"1"` and `"stepCount":10` do not match either form.
    #expect(text.contains("\"stepCount\":1,") || text.contains("\"stepCount\":1}"))
    #expect(text.contains("\"correct\":true,") || text.contains("\"correct\":true}"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["p_batch"] != nil)
    let inner = try #require(object["p_batch"] as? [String: Any])
    for key in ["client", "timezone", "attempts", "sessions"] {
        #expect(inner[key] != nil, "missing \(key)")
    }
    #expect(inner["client"] as? String == "ios/0.4.0(12) levelifykit/0.1.0")
    #expect(inner["timezone"] as? String == "Europe/Madrid")

    let attempts = try #require(inner["attempts"] as? [[String: Any]])
    let attemptJSON = attempts[0]
    for key in ["id", "sessionId", "lessonId", "lessonVersion", "stepId", "position", "mode", "response", "correct", "answeredAt"] {
        #expect(attemptJSON[key] != nil, "missing \(key)")
    }
    #expect(attemptJSON["id"] as? String == "0b8f0000-0000-0000-0000-000000000001")
    #expect(attemptJSON["sessionId"] as? String == "00000000-0000-0000-0000-000000000020")
    #expect(attemptJSON["lessonId"] as? String == "aut-l2-u1-l1")
    #expect(attemptJSON["lessonVersion"] as? String == "abc")
    #expect(attemptJSON["stepId"] as? String == "aut-l2-u1-l1-e1")
    #expect(attemptJSON["position"] as? Int == 0)
    #expect((attemptJSON["position"] is String) == false)
    #expect(attemptJSON["mode"] as? String == "lesson")
    #expect(attemptJSON["answeredAt"] as? String == "2023-11-14T22:13:20Z")
    #expect((attemptJSON["correct"] is String) == false)
    #expect((attemptJSON["correct"] is NSNull) == false)
    let response = try #require(attemptJSON["response"] as? [String: Any])
    #expect(Set(response.keys) == Set(["choice"]))
    #expect(response["choice"] as? Int == 1)
    #expect(response["choice"] is String == false)

    let nullAttempt = attempts[1]
    #expect(nullAttempt["lessonVersion"] is NSNull)
    #expect(nullAttempt["correct"] is NSNull)
    let empty = try #require(nullAttempt["response"] as? [String: Any])
    #expect(empty.isEmpty)
    #expect(nullAttempt["position"] as? Int == 1)

    let sessionJSON = try #require((inner["sessions"] as? [[String: Any]])?.first)
    for key in ["id", "mode", "lessonId", "lessonVersion", "unitId", "startedAt", "completedAt", "stepCount"] {
        #expect(sessionJSON[key] != nil, "missing \(key)")
    }
    #expect(sessionJSON["id"] as? String == "6d2a0000-0000-0000-0000-000000000002")
    #expect(sessionJSON["mode"] as? String == "lesson")
    #expect(sessionJSON["lessonId"] as? String == "aut-l2-u1-l1")
    #expect(sessionJSON["lessonVersion"] as? String == "abc")
    #expect(sessionJSON["unitId"] is NSNull)
    #expect(sessionJSON["startedAt"] as? String == "1970-01-01T00:00:00Z")
    #expect(sessionJSON["completedAt"] as? String == "1970-01-01T00:01:00Z")
    #expect(sessionJSON["stepCount"] as? Int == 1)
    #expect((sessionJSON["stepCount"] is String) == false)
}

@Test func progressAndConfigDecodeAreAdditive() throws {
    let progress = progressJSON(extra: ["futureField": "later"])
    let progressObject = try #require(JSONSerialization.jsonObject(with: progress) as? [String: Any])
    let decoded = try LKCoding.decode(LKProgressState.self, from: progress)
    #expect(decoded.userId == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    #expect(decoded.isGuest == true)
    #expect(decoded.xpTotal == 25)
    #expect(decoded.streak == 1)
    #expect(decoded.longestStreak == 1)
    #expect(decoded.lastActiveDay == "2026-12-16")
    #expect(decoded.streakFreezes == 0)
    #expect(decoded.xpByDay["2026-12-16"] == 25)
    #expect(decoded.lessonsByDay["2026-12-16"] == 1)
    #expect(decoded.lessonResults["aut-l2-u1-l1"]?.bestAccuracy == 1.0)
    #expect(decoded.lessonResults["aut-l2-u1-l1"]?.completions == 1)
    #expect(decoded.lessonResults["aut-l2-u1-l1"]?.isPerfect == true)
    #expect(decoded.serverTime == LKTime.date(from: "2026-12-16T09:31:06Z")!)
    try expectMissing(LKProgressState.self, object: progressObject, keys: [
        "userId", "isGuest", "xpTotal", "streak", "longestStreak", "lastActiveDay",
        "streakFreezes", "xpByDay", "lessonsByDay", "lessonResults", "serverTime",
    ])
    try expectRetyped(LKProgressState.self, object: progressObject, key: "xpTotal", value: "25")
    try expectRetyped(LKProgressState.self, object: progressObject, key: "isGuest", value: "true")
    try expectRetyped(LKProgressState.self, object: progressObject, key: "serverTime", value: 1_700_000_000)

    var nullDay = progressObject
    nullDay["lastActiveDay"] = NSNull()
    let nullDayState = try LKCoding.decode(LKProgressState.self, from: JSONSerialization.data(withJSONObject: nullDay))
    #expect(nullDayState.lastActiveDay == nil)

    var results = try #require(progressObject["lessonResults"] as? [String: Any])
    var lesson = try #require(results["aut-l2-u1-l1"] as? [String: Any])
    for key in ["bestAccuracy", "completions", "isPerfect"] {
        var brokenLesson = lesson
        brokenLesson.removeValue(forKey: key)
        results["aut-l2-u1-l1"] = brokenLesson
        var broken = progressObject
        broken["lessonResults"] = results
        #expect(throws: DecodingError.self) {
            _ = try LKCoding.decode(LKProgressState.self, from: JSONSerialization.data(withJSONObject: broken))
        }
    }
    lesson["completions"] = "1"
    results["aut-l2-u1-l1"] = lesson
    var retypedLesson = progressObject
    retypedLesson["lessonResults"] = results
    #expect(throws: DecodingError.self) {
        _ = try LKCoding.decode(LKProgressState.self, from: JSONSerialization.data(withJSONObject: retypedLesson))
    }

    let config = configData(manifestSha: "abc", extra: ["futureField": true])
    let configObject = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
    let app = try LKCoding.decode(LKAppConfig.self, from: config)
    #expect(app.content?.releaseId == "abc")
    #expect(app.content?.manifestPath == "manifests/abc.json")
    #expect(app.content?.manifestSha256 == "abc")
    #expect(app.minClientVersion["ios"] == "0.0.0")
    #expect(app.limits.mode == "dailyLessonCap")
    #expect(app.limits.value == 3)
    #expect(app.killSwitches["player"] == false)
    #expect(app.killSwitches["sync"] == false)
    #expect(app.flags["leagues"] == false)
    #expect(app.serverTime == LKTime.date(from: "2026-12-16T09:30:00Z"))
    try expectMissing(LKAppConfig.self, object: configObject, keys: [
        "minClientVersion", "limits", "killSwitches", "flags", "serverTime",
    ])
    var limits = try #require(configObject["limits"] as? [String: Any])
    limits["value"] = "3"
    var retypedLimits = configObject
    retypedLimits["limits"] = limits
    #expect(throws: DecodingError.self) {
        _ = try LKCoding.decode(LKAppConfig.self, from: JSONSerialization.data(withJSONObject: retypedLimits))
    }
    var noContent = configObject
    noContent.removeValue(forKey: "content")
    let withoutContent = try LKCoding.decode(LKAppConfig.self, from: JSONSerialization.data(withJSONObject: noContent))
    #expect(withoutContent.content == nil)
    #expect(withoutContent.limits.value == 3)

    let replyObject: [String: Any] = [
        "accepted": ["0b8f0000-0000-0000-0000-000000000001"],
        "rejected": [["id": "77aa0000-0000-0000-0000-000000000099", "code": "unknown_step"]],
        "state": progressObject,
        "futureField": true,
    ]
    let reply = try LKCoding.decode(SubmitReply.self, from: JSONSerialization.data(withJSONObject: replyObject))
    #expect(reply.accepted == ["0b8f0000-0000-0000-0000-000000000001"])
    #expect(reply.rejected.first?.code == "unknown_step")
    #expect(reply.state.xpTotal == 25)
    try expectMissing(SubmitReply.self, object: replyObject, keys: ["accepted", "rejected", "state"])
    try expectRetyped(SubmitReply.self, object: replyObject, key: "accepted", value: "0b8f0000-0000-0000-0000-000000000001")
    var rejected = replyObject
    rejected["rejected"] = [["id": "77aa0000-0000-0000-0000-000000000099"]]
    #expect(throws: DecodingError.self) {
        _ = try LKCoding.decode(SubmitReply.self, from: JSONSerialization.data(withJSONObject: rejected))
    }
}

private func expectMissing<T: Decodable>(_ type: T.Type, object: [String: Any], keys: [String]) throws {
    for key in keys {
        var copy = object
        copy.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: copy)
        #expect(throws: DecodingError.self) {
            _ = try LKCoding.decode(type, from: data)
        }
    }
}

private func expectRetyped<T: Decodable>(_ type: T.Type, object: [String: Any], key: String, value: Any) throws {
    var copy = object
    copy[key] = value
    let data = try JSONSerialization.data(withJSONObject: copy)
    #expect(throws: DecodingError.self) {
        _ = try LKCoding.decode(type, from: data)
    }
}

@Test func rorkCapabilitiesMatchTheFixture() throws {
    let data = try fixture("rork-ios-4fe5be7")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["formatVersion"] as? Int == LKCapabilities.rorkIOS4fe5be7.formatVersion)
    let types = object["stepTypes"] as? [String: Any] ?? [:]
    #expect(types.count == LKCapabilities.rorkIOS4fe5be7.stepTypes.count)
    for (key, value) in LKCapabilities.rorkIOS4fe5be7.stepTypes {
        #expect((types[key] as? NSNumber)?.intValue == value || types[key] as? Int == value)
    }
}

@Test func previewDoesNotRequireASession() async {
    let kit = LevelifyKit.preview()
    #expect(await kit.config.current.serverTime == nil)
    #expect(await kit.auth.currentUser == nil)
}

private func makeKit() -> (LKFakeBackend, LevelifyKit) {
    let fake = LKFakeBackend()
    fake.progressData = progressJSON(extra: [:])
    fake.configData = configData(manifestSha: "abc")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levelifykit-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let kit = LevelifyKit(backend: fake, directory: directory, sleeper: NoSleep(), config: sampleConfig())
    return (fake, kit)
}

private func sampleConfig() -> LevelifyConfig {
    LevelifyConfig(
        supabaseURL: URL(string: "https://example.invalid")!,
        publishableKey: "test-publishable",
        contentBaseURL: URL(string: "https://content.test/base")!,
        client: LKClientInfo(platform: "ios", appVersion: "0.4.0", build: "12"),
        capabilities: .rorkIOS4fe5be7
    )
}

private func sampleAttempt(id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!) -> LKAttempt {
    LKAttempt(
        id: id,
        sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
        lessonId: "aut-l2-u1-l1",
        lessonVersion: "abc",
        stepId: "aut-l2-u1-l1-e1",
        position: 0,
        mode: .lesson,
        response: .choice(1),
        correct: true,
        answeredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func progressJSON(extra: [String: Any]) -> Data {
    var object: [String: Any] = [
        "userId": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "isGuest": true,
        "xpTotal": 25,
        "streak": 1,
        "longestStreak": 1,
        "lastActiveDay": "2026-12-16",
        "streakFreezes": 0,
        "xpByDay": ["2026-12-16": 25],
        "lessonsByDay": ["2026-12-16": 1],
        "lessonResults": ["aut-l2-u1-l1": ["bestAccuracy": 1.0, "completions": 1, "isPerfect": true]],
        "serverTime": "2026-12-16T09:31:06Z",
    ]
    for (key, value) in extra { object[key] = value }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func configData(manifestSha: String, extra: [String: Any] = [:]) -> Data {
    var object: [String: Any] = [
        "content": [
            "releaseId": manifestSha,
            "manifestPath": "manifests/\(manifestSha).json",
            "manifestSha256": manifestSha,
        ],
        "minClientVersion": ["ios": "0.0.0"],
        "limits": ["mode": "dailyLessonCap", "value": 3],
        "killSwitches": ["player": false, "sync": false],
        "flags": ["leagues": false],
        "serverTime": "2026-12-16T09:30:00Z",
    ]
    for (key, value) in extra { object[key] = value }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func manifestData(lessonSha: String, lessonBytes: Int) -> Data {
    let object: [String: Any] = [
        "manifestVersion": 1,
        "tracks": [[
            "id": "automation",
            "title": "Automation",
            "subtitle": "Hand off work safely",
            "symbol": "gearshape.2.fill",
            "units": [[
                "id": "aut-l2-u1",
                "tier": 2,
                "title": "Map the work",
                "summary": "Before you hand a step off",
                "lessons": [[
                    "id": "aut-l2-u1-l1",
                    "title": "Map",
                    "symbol": "gear",
                    "path": "lessons/aut-l2-u1-l1/\(lessonSha).json",
                    "sha256": lessonSha,
                    "bytes": lessonBytes,
                    "needsPlayer": false,
                    "media": [],
                ]],
            ]],
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

func fixture(_ name: String) throws -> Data {
    if let url = Bundle.module.url(forResource: name, withExtension: "json") {
        return try Data(contentsOf: url)
    }
    let nested = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: nested)
}
