import Foundation
import LevelifyKit

public struct LKPlayerSettings: Sendable, Equatable {
    public var reduceMotion: Bool
    public var textScale: Double
    public var colorScheme: String
    public var sound: Bool
    public var haptics: Bool

    public init(reduceMotion: Bool, textScale: Double, colorScheme: String, sound: Bool, haptics: Bool) {
        self.reduceMotion = reduceMotion
        self.textScale = textScale
        self.colorScheme = colorScheme
        self.sound = sound
        self.haptics = haptics
    }
}

public enum LKPlayerState: Sendable, Equatable {
    case loading
    case ready
    case failed(offline: Bool)
    case locked
}

public struct LKPlayerResult: Sendable, Equatable {
    public let stepId: String
    public let correct: Bool?
    public let response: [String: LKJSON]
    public let durationMs: Int

    public init(stepId: String, correct: Bool?, response: [String: LKJSON], durationMs: Int) {
        self.stepId = stepId
        self.correct = correct
        self.response = response
        self.durationMs = durationMs
    }
}

package struct PlayerOutgoing: Equatable, Sendable {
    package var bridge: Int
    package var type: String
    package var payload: [String: LKJSON]
    package var replyTo: String?

    package init(bridge: Int, type: String, payload: [String: LKJSON], replyTo: String?) {
        self.bridge = bridge
        self.type = type
        self.payload = payload
        self.replyTo = replyTo
    }
}

package enum PlayerEffect: Equatable, Sendable {
    case state(LKPlayerState)
    case result(LKPlayerResult)
    case send(PlayerOutgoing)
    case haptic(String)
    case sound(String)
    case announce(String)
}

package let playerReadyTimeout: TimeInterval = 8
