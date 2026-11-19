import Foundation
import Testing
import LevelifyKit

@Test func planMatchesSharedFixtures() throws {
    let data = try fixture("plan-cases")
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cases = try #require(root["cases"] as? [[String: Any]])
    #expect(cases.count == 30)
    for item in cases {
        let name = item["name"] as? String ?? "?"
        let lesson = try JSONSerialization.data(withJSONObject: try #require(item["lesson"]))
        let capsObject = try #require(item["caps"] as? [String: Any])
        var stepTypes: [String: Int] = [:]
        for (key, value) in capsObject["stepTypes"] as? [String: Any] ?? [:] {
            if let number = value as? Int {
                stepTypes[key] = number
            } else if let number = value as? NSNumber {
                stepTypes[key] = number.intValue
            }
        }
        let format = (capsObject["formatVersion"] as? Int) ?? (capsObject["formatVersion"] as? NSNumber)?.intValue ?? 1
        let caps = LKCapabilities(formatVersion: format, stepTypes: stepTypes)
        let raw = LessonPlanner.plan(lesson: lesson, caps: caps)
        let decode = item["decode"] as? String
        if decode != "ok" {
            #expect(raw.failure == decode, "\(name)")
            #expect(item["expect"] == nil || item["expect"] is NSNull, "\(name)")
            continue
        }
        let expect = try #require(item["expect"] as? [String: Any], "\(name)")
        #expect(raw.ok, "\(name)")
        let playable = (expect["playable"] as? Bool) ?? ((expect["playable"] as? NSNumber)?.boolValue ?? false)
        #expect(raw.playable == playable, "\(name)")
        if expect["reason"] is NSNull || expect["reason"] == nil {
            #expect(raw.reason == nil, "\(name)")
        } else {
            #expect(raw.reason == expect["reason"] as? String, "\(name)")
        }
        let expectedSteps = try #require(expect["steps"] as? [[String: Any]], "\(name)")
        #expect(raw.steps.count == expectedSteps.count, "\(name)")
        for (got, want) in zip(raw.steps, expectedSteps) {
            #expect(got.id == want["id"] as? String, "\(name)")
            #expect(got.action == want["action"] as? String, "\(name) \(got.id)")
        }
        let host = LessonPlanner.hostPlan(lesson: lesson, shell: caps, playerStepTypes: [:], playerAvailable: false)
        for (got, step) in zip(host.steps, raw.steps) where step.action == "play" {
            #expect(got.action == .native, "\(name) \(step.id)")
        }
    }
}

@Test func playerOnlyRequirementIsPlayerUnavailable() {
    let lesson = Data("""
    {"id":"l","title":"t","symbol":"s","formatVersion":1,"requires":{"stepTypes":{"simulation":1}},"exercises":[
      {"id":"sim","type":"simulation","instruction":"Run it","explanation":"Done","concepts":["agents"]}
    ]}
    """.utf8)
    let shell = LKCapabilities.rorkIOS4fe5be7
    let unavailable = LessonPlanner.hostPlan(lesson: lesson, shell: shell, playerStepTypes: ["simulation": 1], playerAvailable: false)
    #expect(unavailable.playable == false)
    #expect(unavailable.reason == "player-unavailable")

    let ready = LessonPlanner.hostPlan(lesson: lesson, shell: shell, playerStepTypes: ["simulation": 1], playerAvailable: true)
    #expect(ready.playable == true)
    #expect(ready.reason == nil)
    #expect(ready.steps.first?.action == .player)
}
