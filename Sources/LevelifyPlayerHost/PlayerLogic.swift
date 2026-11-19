import Foundation
import LevelifyKit

/// Bridge v1 state machine. No WebKit, so Linux tests can run it.
package struct PlayerLogic {
    package var settings: LKPlayerSettings
    package var hostVersions: [Int]
    package var locale: String
    package var hostName: String
    package private(set) var bridge: Int?
    private var phase: Phase = .idle
    private var activeStep: String?
    private var sawResult = false
    private var filesReady = false
    private var connected = true
    private var pendingLoad: Load?

    private enum Phase { case idle, loading, ready, failed, locked }

    private struct Load {
        var lessonId: String
        var lessonVersion: String?
        var step: [String: LKJSON]
        var media: [String: String]
    }

    package init(
        settings: LKPlayerSettings = LKPlayerSettings(reduceMotion: false, textScale: 1, colorScheme: "light", sound: true, haptics: true),
        hostVersions: [Int] = bridgeVersions,
        locale: String = "en",
        hostName: String = "levelifykit-ios/0.1.0"
    ) {
        self.settings = settings
        self.hostVersions = hostVersions
        self.locale = locale
        self.hostName = hostName
    }

    package mutating func appear(
        stepId: String,
        lessonId: String,
        lessonVersion: String?,
        step: [String: LKJSON],
        media: [String: String],
        filesReady: Bool,
        connected: Bool
    ) -> [PlayerEffect] {
        self.filesReady = filesReady
        self.connected = connected
        activeStep = stepId
        sawResult = false
        let load = Load(lessonId: lessonId, lessonVersion: lessonVersion, step: step, media: media)
        pendingLoad = load
        if !filesReady && !connected {
            phase = .failed
            pendingLoad = nil
            return [.state(.failed(offline: true))]
        }
        phase = .loading
        var effects: [PlayerEffect] = [.state(.loading)]
        if bridge != nil {
            effects.append(contentsOf: loadMessages(load))
        }
        return effects
    }

    package mutating func disappear() -> [PlayerEffect] {
        var effects: [PlayerEffect] = []
        if let activeStep, let bridge {
            effects.append(.send(PlayerOutgoing(bridge: bridge, type: "step.unload", payload: ["stepId": .string(activeStep)], replyTo: nil)))
        }
        activeStep = nil
        pendingLoad = nil
        sawResult = false
        phase = .idle
        return effects
    }

    package mutating func update(settings: LKPlayerSettings) -> [PlayerEffect] {
        self.settings = settings
        guard let bridge else { return [] }
        return [.send(PlayerOutgoing(bridge: bridge, type: "settings.update", payload: ["settings": .object(settingsObject())], replyTo: nil))]
    }

    /// `message` has already been accepted by `parseMessage`. Rejected and ignored messages never reach here.
    package mutating func receive(_ message: BridgeMessage) -> [PlayerEffect] {
        switch message.type {
        case "player.hello":
            guard phase != .failed else { return [] }
            return hello(message)
        case "player.ready":
            guard phase == .loading, string(message.payload["stepId"]) == activeStep else { return [] }
            phase = .ready
            return [.state(.ready)]
        case "step.result":
            return result(message)
        case "player.error":
            guard phase == .loading || phase == .ready else { return [] }
            phase = .failed
            return [.state(.failed(offline: !filesReady && !connected))]
        case "haptic":
            guard settings.haptics, let kind = string(message.payload["kind"]) else { return [] }
            return [.haptic(kind)]
        case "sound":
            guard settings.sound, let kind = string(message.payload["kind"]) else { return [] }
            return [.sound(kind)]
        case "a11y.announce":
            guard let text = string(message.payload["text"]), !text.isEmpty else { return [] }
            return [.announce(text)]
        default:
            return []
        }
    }

    package mutating func timeout() -> [PlayerEffect] {
        guard phase == .loading else { return [] }
        phase = .failed
        return [.state(.failed(offline: false))]
    }

    private mutating func hello(_ message: BridgeMessage) -> [PlayerEffect] {
        let versions = ints(message.payload["bridgeVersions"])
        guard let chosen = chooseBridgeVersion(versions, hostVersions) else {
            bridge = nil
            phase = .failed
            pendingLoad = nil
            return [.state(.failed(offline: false))]
        }
        bridge = chosen
        var effects: [PlayerEffect] = [
            .send(PlayerOutgoing(bridge: chosen, type: "host.hello", payload: [
                "bridge": .number(Double(chosen)),
                "host": .string(hostName),
                "platform": .string("ios"),
                "locale": .string(locale),
                "settings": .object(settingsObject()),
            ], replyTo: message.id)),
        ]
        if let pendingLoad, phase == .loading {
            effects.append(contentsOf: loadMessages(pendingLoad))
        }
        return effects
    }

    private mutating func result(_ message: BridgeMessage) -> [PlayerEffect] {
        guard !sawResult, phase == .loading || phase == .ready, let stepId = string(message.payload["stepId"]), stepId == activeStep else {
            return []
        }
        guard let duration = int(message.payload["durationMs"]), case .object(let response) = message.payload["response"] else { return [] }
        sawResult = true
        phase = .locked
        let correct = bool(message.payload["correct"])
        let agreed = bridge ?? 1
        return [
            .result(LKPlayerResult(stepId: stepId, correct: correct, response: response, durationMs: duration)),
            .send(PlayerOutgoing(bridge: agreed, type: "step.lock", payload: ["stepId": .string(stepId)], replyTo: nil)),
            .state(.locked),
        ]
    }

    private func loadMessages(_ load: Load) -> [PlayerEffect] {
        let agreed = bridge ?? 1
        let media = load.media.mapValues { LKJSON.string($0) }
        let version: LKJSON = load.lessonVersion.map { .string($0) } ?? .null
        return [
            .send(PlayerOutgoing(bridge: agreed, type: "step.load", payload: [
                "lessonId": .string(load.lessonId),
                "lessonVersion": version,
                "step": .object(load.step),
                "media": .object(media),
            ], replyTo: nil)),
        ]
    }

    private func settingsObject() -> [String: LKJSON] {
        [
            "reduceMotion": .bool(settings.reduceMotion),
            "textScale": .number(settings.textScale),
            "colorScheme": .string(settings.colorScheme),
            "sound": .bool(settings.sound),
            "haptics": .bool(settings.haptics),
        ]
    }

    private func string(_ value: LKJSON?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    private func int(_ value: LKJSON?) -> Int? {
        if case .number(let number) = value, number.rounded() == number { return Int(number) }
        return nil
    }

    private func ints(_ value: LKJSON?) -> [Int] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(int)
    }

    private func bool(_ value: LKJSON?) -> Bool? {
        if case .bool(let flag) = value { return flag }
        if case .null = value { return nil }
        return nil
    }
}
