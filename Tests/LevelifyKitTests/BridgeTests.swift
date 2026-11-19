import Foundation
import Testing
import LevelifyKit
import LevelifyPlayerHost
#if canImport(CoreFoundation)
import CoreFoundation
#endif

private struct BridgeCase {
    var file: String
    var direction: BridgeDirection
    var expect: String
    var type: String?
    var code: String?
}

@Test func bridgeCasesMatchTheContract() throws {
    let cases = try loadCases()
    let listed = cases.map(\.file).sorted()
    #expect(Set(listed).count == listed.count)
    let onDisk = try messageFiles().sorted()
    #expect(listed == onDisk)
    #expect(cases.count == 52)

    for item in cases {
        let text = try readFixture(item.file)
        let verdict = parseMessage(text, direction: item.direction)
        switch item.expect {
        case "accept":
            guard case .accept(let message) = verdict else {
                Issue.record("\(item.file) \(verdict)")
                continue
            }
            #expect(message.type == item.type, "\(item.file)")
            guard case .accept = parseMessageObject(text, direction: item.direction) else {
                Issue.record("\(item.file) object form was not accepted")
                continue
            }
        case "ignore":
            guard case .ignore(let code, _, _) = verdict else {
                Issue.record("\(item.file) \(verdict)")
                continue
            }
            #expect(code == item.code, "\(item.file)")
        case "reject":
            guard case .reject(let code, _) = verdict else {
                Issue.record("\(item.file) \(verdict)")
                continue
            }
            #expect(code == item.code, "\(item.file) \(verdict)")
        default:
            Issue.record("unknown expect \(item.expect)")
        }
        if item.code == "too_large" {
            #expect(text.utf8.count > maxMessageBytes)
        } else {
            #expect(text.utf8.count <= maxMessageBytes, "\(item.file)")
        }
    }
}

@Test func bridgeConversationsFollowTheHandshake() throws {
    let names = ["happy-path.json", "step-type-unknown.json", "version-mismatch.json"]
    for name in names {
        let data = try Data(contentsOf: fixtureURL("conversations/\(name)"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hostVersions = jsonInts(root["hostBridgeVersions"])
        let messages = try #require(root["messages"] as? [[String: Any]])
        let expect = try #require(root["expect"] as? [String: Any])
        var seen: Set<String> = []
        var agreed: Int?
        for entry in messages {
            let from = try #require(entry["from"] as? String)
            let message = try #require(entry["message"] as? [String: Any])
            let wire = try JSONSerialization.data(withJSONObject: message)
            let text = try #require(String(data: wire, encoding: .utf8))
            let direction: BridgeDirection = from == "player" ? .toHost : .toPlayer
            guard case .accept(let parsed) = parseMessage(text, direction: direction) else {
                Issue.record("\(name) \(message["type"] ?? "") did not accept")
                continue
            }
            if let reply = parsed.replyTo {
                #expect(seen.contains(reply.lowercased()), "\(name) \(parsed.type) answers an unknown id")
            }
            seen.insert(parsed.id.lowercased())
            if parsed.type == "player.hello" {
                agreed = chooseBridgeVersion(ints(parsed.payload["bridgeVersions"]), hostVersions)
            }
            if parsed.type == "host.hello" {
                #expect(int(parsed.payload["bridge"]) == agreed, "\(name) host.hello")
            }
            if parsed.type != "player.hello" {
                #expect(parsed.bridge == agreed, "\(name) \(parsed.type)")
            }
        }
        #expect(agreed == jsonInt(expect["agreedBridge"]), "\(name)")
        let sawReady = messages.contains { ($0["message"] as? [String: Any])?["type"] as? String == "player.ready" }
        #expect(sawReady == jsonBool(expect["playerReady"]), "\(name)")
        try runHost(name: name, hostVersions: hostVersions, messages: messages, expect: expect)
    }
}

@Test func bridgeVersionChoiceAndScheme() {
    #expect(chooseBridgeVersion([1], [1]) == 1)
    #expect(chooseBridgeVersion([1, 2], [1]) == 1)
    #expect(chooseBridgeVersion([1, 2], [2, 1]) == 2)
    #expect(chooseBridgeVersion([1], [2]) == nil)
    #expect(chooseBridgeVersion([], [1]) == nil)

    #expect(resolvePlayerUrl("levelify-player://player/index.html") == .build(file: "index.html", contentType: "text/html; charset=utf-8"))
    #expect(resolvePlayerUrl("levelify-player://player/app.js") == .build(file: "app.js", contentType: "text/javascript; charset=utf-8"))
    #expect(resolvePlayerUrl("levelify-player://player/app.css") == .build(file: "app.css", contentType: "text/css; charset=utf-8"))
    let sha = String(repeating: "a", count: 64)
    #expect(resolvePlayerUrl(mediaURL(sha256: sha, ext: "png")) == .media(sha256: sha, ext: "png", contentType: "image/png"))
    let rejected = [
        "levelify-player://media/\(sha).png",
        "levelify-player://player/",
        "levelify-player://player/app.js?v=2",
        "levelify-player://player/app.js#x",
        "levelify-player://player/../secrets.json",
        "levelify-player://player/%2e%2e/x.js",
        "levelify-player://player/sub/app.js",
        "levelify-player://player/media/\(sha).exe",
        "levelify-player://player/media/\(String(repeating: "A", count: 64)).png",
        "levelify-player://player/media/short.png",
        "levelify-player://player/app.wasm",
        "levelify-player://player/.hidden.js",
        "levelify-player://Player/index.html",
        "https://player/index.html",
        "file:///index.html",
    ]
    for url in rejected {
        #expect(resolvePlayerUrl(url) == .notFound, "\(url)")
    }
}

private func runHost(name: String, hostVersions: [Int], messages: [[String: Any]], expect: [String: Any]) throws {
    let settings = LKPlayerSettings(reduceMotion: false, textScale: 1, colorScheme: "dark", sound: true, haptics: true)
    var logic = PlayerLogic(settings: settings, hostVersions: hostVersions, locale: "en")
    if let load = messages.compactMap({ $0["message"] as? [String: Any] }).first(where: { $0["type"] as? String == "step.load" }),
       let payload = load["payload"] as? [String: Any] {
        let lessonId = payload["lessonId"] as? String ?? "lesson"
        let version = payload["lessonVersion"] as? String
        let step = lkObject(payload["step"])
        let stepId = (step["id"] as? String) ?? (payload["step"] as? [String: Any]).flatMap { $0["id"] as? String } ?? "step"
        _ = logic.appear(stepId: stepId, lessonId: lessonId, lessonVersion: version, step: jsonObject(payload["step"]), media: stringMap(payload["media"]), filesReady: true, connected: true)
    }
    var sends: [String] = []
    var state: LKPlayerState?
    var ready = false
    var result: LKPlayerResult?
    for entry in messages where entry["from"] as? String == "player" {
        let message = try #require(entry["message"] as? [String: Any])
        let wire = try JSONSerialization.data(withJSONObject: message)
        let text = try #require(String(data: wire, encoding: .utf8))
        guard case .accept(let parsed) = parseMessage(text, direction: .toHost) else { continue }
        for effect in logic.receive(parsed) {
            switch effect {
            case .send(let outgoing):
                sends.append(outgoing.type)
                if outgoing.type == "host.hello" {
                    #expect(intJSON(outgoing.payload["bridge"]) == logic.bridge, "\(name)")
                }
            case .state(let next):
                state = next
                if case .ready = next { ready = true }
            case .result(let value):
                result = value
            default:
                break
            }
        }
    }
    if messages.contains(where: { ($0["message"] as? [String: Any])?["type"] as? String == "step.unload" }) {
        for effect in logic.disappear() {
            if case .send(let outgoing) = effect { sends.append(outgoing.type) }
        }
    }
    #expect(ready == (jsonBool(expect["playerReady"]) ?? false), "\(name)")
    if let expectedSends = expect["hostSends"] as? [Any] {
        #expect(sends.isEmpty && expectedSends.isEmpty, "\(name) \(sends)")
    }
    if expect["hostState"] as? String == "failed" {
        if case .failed(let offline) = state {
            #expect(offline == false, "\(name)")
        } else {
            Issue.record("\(name) state \(String(describing: state))")
        }
    }
    if let expected = expect["result"] as? [String: Any] {
        #expect(result?.stepId == expected["stepId"] as? String, "\(name)")
        #expect(result?.correct == jsonBool(expected["correct"]), "\(name)")
    }
    if name == "happy-path.json" {
        #expect(sends == ["host.hello", "step.load", "step.lock", "step.unload"])
    }
    if name == "version-mismatch.json" {
        #expect(sends.isEmpty)
        #expect(ready == false)
    }
    if name == "step-type-unknown.json" {
        #expect(ready == false)
        #expect(sends == ["host.hello", "step.load"])
    }
}

private func loadCases() throws -> [BridgeCase] {
    let data = try Data(contentsOf: fixtureURL("cases.json"))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(root["cases"] as? [[String: Any]])
    return try rows.map { row in
        let file = try #require(row["file"] as? String)
        let direction = try #require(row["direction"] as? String)
        let expect = try #require(row["expect"] as? String)
        return BridgeCase(
            file: file,
            direction: direction == "toPlayer" ? .toPlayer : .toHost,
            expect: expect,
            type: row["type"] as? String,
            code: row["code"] as? String
        )
    }
}

private func messageFiles() throws -> [String] {
    let url = fixtureURL("messages")
    let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
    return names.map { "messages/\($0)" }
}

private func readFixture(_ path: String) throws -> String {
    try String(contentsOf: fixtureURL(path), encoding: .utf8)
}

private func fixtureURL(_ path: String) -> URL {
    let root = Bundle.module.resourceURL!
    let copied = root.appendingPathComponent("BridgeFixtures").appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: copied.path) { return copied }
    return root.appendingPathComponent("bridge").appendingPathComponent(path)
}

private func jsonInts(_ value: Any?) -> [Int] {
    if let ints = value as? [Int] { return ints }
    if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
    if let array = value as? [Any] { return array.compactMap { jsonInt($0) } }
    return []
}

private func jsonIsBool(_ value: Any) -> Bool {
    #if canImport(CoreFoundation)
    if let object = value as? NSObject {
        let ref = object as CFTypeRef
        if CFGetTypeID(ref) == CFBooleanGetTypeID() { return true }
    }
    #endif
    return value is Bool && !(value is NSNumber)
}

private func jsonInt(_ value: Any?) -> Int? {
    guard let value, !jsonIsBool(value) else { return nil }
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

private func jsonBool(_ value: Any?) -> Bool? {
    guard let value, jsonIsBool(value) else { return nil }
    if let number = value as? NSNumber { return number.boolValue }
    if let flag = value as? Bool { return flag }
    return nil
}

private func ints(_ value: LKJSON?) -> [Int] {
    guard case .array(let values) = value else { return [] }
    return values.compactMap { intJSON($0) }
}

private func intJSON(_ value: LKJSON?) -> Int? {
    guard case .number(let number) = value, number.rounded() == number else { return nil }
    return Int(number)
}

private func int(_ value: LKJSON?) -> Int? { intJSON(value) }

private func jsonObject(_ value: Any?) -> [String: LKJSON] {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let json = try? LKCoding.decode(LKJSON.self, from: data),
          case .object(let object) = json else { return [:] }
    return object
}

private func stringMap(_ value: Any?) -> [String: String] {
    guard let object = value as? [String: Any] else { return [:] }
    var map: [String: String] = [:]
    for (key, item) in object {
        if let text = item as? String { map[key] = text }
    }
    return map
}

private func lkObject(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}
