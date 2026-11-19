import Foundation
import Testing
import LevelifyKit
import LevelifyPlayerHost

@Test func playerHandshakeLoadsThenLocks() {
    var logic = PlayerLogic()
    let loading = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: ["id": .string("sim")], media: [:], filesReady: true, connected: true)
    #expect(loading == [.state(.loading)])

    let hello = logic.receive(BridgeMessage(id: "hello-1", type: "player.hello", payload: [
        "bridgeVersions": .array([.number(1)]),
        "playerVersion": .string("0.1.0"),
        "buildId": .string("build"),
        "stepTypes": .object(["simulation": .number(1)]),
    ]))
    #expect(hello.contains { if case .send(let message) = $0 { return message.type == "host.hello" }; return false })
    #expect(hello.contains { if case .send(let message) = $0 { return message.type == "step.load" }; return false })

    let ready = logic.receive(BridgeMessage(id: "ready-1", type: "player.ready", payload: ["stepId": .string("sim")]))
    #expect(ready == [.state(.ready)])

    let done = logic.receive(BridgeMessage(id: "result-1", type: "step.result", payload: [
        "stepId": .string("sim"),
        "correct": .bool(true),
        "response": .object(["choice": .number(1)]),
        "durationMs": .number(1200),
    ]))
    #expect(done.count == 3)
    if case .result(let result) = done[0] {
        #expect(result.correct == true)
        #expect(result.response["choice"] == .number(1))
        #expect(result.durationMs == 1200)
    } else {
        Issue.record("expected a result first")
    }
    if case .send(let message) = done[1] {
        #expect(message.type == "step.lock")
    } else {
        Issue.record("expected step.lock after the result")
    }
    #expect(done[2] == .state(.locked))

    let again = logic.receive(BridgeMessage(id: "result-2", type: "step.result", payload: [
        "stepId": .string("sim"),
        "correct": .bool(false),
        "response": .object([:]),
        "durationMs": .number(1),
    ]))
    #expect(again.isEmpty)
}

@Test func playerVersionMismatchDoesNotBecomeReady() {
    var logic = PlayerLogic()
    _ = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: [:], media: [:], filesReady: true, connected: true)
    let mismatch = logic.receive(BridgeMessage(id: "hello", type: "player.hello", payload: ["bridgeVersions": .array([.number(2)])]))
    #expect(mismatch == [.state(.failed(offline: false))])
    #expect(!mismatch.contains { if case .send = $0 { return true }; return false })
    let ready = logic.receive(BridgeMessage(id: "ready", type: "player.ready", payload: ["stepId": .string("sim")]))
    #expect(ready.isEmpty)
}

@Test func missingFilesOfflineFailsImmediately() {
    var logic = PlayerLogic()
    let effects = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: [:], media: [:], filesReady: false, connected: false)
    #expect(effects == [.state(.failed(offline: true))])
    let timeout = logic.timeout()
    #expect(timeout.isEmpty)
}

@Test func timeoutWithFilesIsNotOffline() {
    var logic = PlayerLogic()
    _ = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: [:], media: [:], filesReady: true, connected: false)
    #expect(logic.timeout() == [.state(.failed(offline: false))])
}

@Test func newInstanceLoadsAgainAfterUnload() {
    var logic = PlayerLogic(settings: LKPlayerSettings(reduceMotion: false, textScale: 1, colorScheme: "dark", sound: false, haptics: false))
    _ = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: ["id": .string("sim")], media: [:], filesReady: true, connected: true)
    _ = logic.receive(BridgeMessage(id: "h", type: "player.hello", payload: ["bridgeVersions": .array([.number(1)])]))
    let sound = logic.receive(BridgeMessage(id: "s", type: "sound", payload: ["kind": .string("tap")]))
    #expect(sound.isEmpty)
    let gone = logic.disappear()
    #expect(gone.contains { if case .send(let message) = $0 { return message.type == "step.unload" }; return false })
    let again = logic.appear(stepId: "sim", lessonId: "lesson", lessonVersion: "sha", step: ["id": .string("sim")], media: [:], filesReady: true, connected: true)
    #expect(again.contains { if case .state(.loading) = $0 { return true }; return false })
    #expect(again.contains { if case .send(let message) = $0 { return message.type == "step.load" }; return false })
}

@Test func sessionInitIsMainActor() async {
    let kit = LevelifyKit.preview()
    await MainActor.run { _ = LKPlayerSession(kit: kit) }
}
