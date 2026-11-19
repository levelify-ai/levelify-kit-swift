import Foundation

public struct LevelifyConfig: Sendable {
    public let supabaseURL: URL
    public let publishableKey: String
    public let contentBaseURL: URL
    public let client: LKClientInfo
    public let capabilities: LKCapabilities

    public init(
        supabaseURL: URL,
        publishableKey: String,
        contentBaseURL: URL,
        client: LKClientInfo,
        capabilities: LKCapabilities
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.contentBaseURL = contentBaseURL
        self.client = client
        self.capabilities = capabilities
    }
}

public struct LKClientInfo: Sendable {
    public let platform: String
    public let appVersion: String
    public let build: String

    public init(platform: String, appVersion: String, build: String) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
    }

    package var headerValue: String {
        "\(platform)/\(appVersion)(\(build)) levelifykit/0.1.0"
    }
}

public struct LKCapabilities: Sendable, Codable, Equatable {
    public var formatVersion: Int
    public var stepTypes: [String: Int]

    public init(formatVersion: Int, stepTypes: [String: Int]) {
        self.formatVersion = formatVersion
        self.stepTypes = stepTypes
    }

    /// What Rork's app at 4fe5be7 plays itself. Free write is left out: the app decodes it and does not play it.
    public static let rorkIOS4fe5be7 = LKCapabilities(
        formatVersion: 1,
        stepTypes: [
            "multipleChoice": 1,
            "pickPrompt": 1,
            "fillBlank": 1,
            "buildPrompt": 1,
            "spotProblem": 1,
            "matchPairs": 1,
        ]
    )
}

public struct LKMonth: Sendable, Codable, Equatable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }
}

public struct LKUser: Sendable, Equatable {
    public let id: UUID
    public let isGuest: Bool

    public init(id: UUID, isGuest: Bool) {
        self.id = id
        self.isGuest = isGuest
    }
}

public struct LKContentPointer: Sendable, Codable, Equatable {
    public var releaseId: String
    public var manifestPath: String
    public var manifestSha256: String

    public init(releaseId: String, manifestPath: String, manifestSha256: String) {
        self.releaseId = releaseId
        self.manifestPath = manifestPath
        self.manifestSha256 = manifestSha256
    }
}

public struct LKLimits: Sendable, Codable, Equatable {
    public var mode: String
    public var value: Int

    public init(mode: String, value: Int) {
        self.mode = mode
        self.value = value
    }
}

public struct LKAppConfig: Sendable, Codable, Equatable {
    public var content: LKContentPointer?
    public var minClientVersion: [String: String]
    public var limits: LKLimits
    public var killSwitches: [String: Bool]
    public var flags: [String: Bool]
    public var serverTime: Date?

    public init(
        content: LKContentPointer?,
        minClientVersion: [String: String],
        limits: LKLimits,
        killSwitches: [String: Bool],
        flags: [String: Bool],
        serverTime: Date?
    ) {
        self.content = content
        self.minClientVersion = minClientVersion
        self.limits = limits
        self.killSwitches = killSwitches
        self.flags = flags
        self.serverTime = serverTime
    }

    private enum CodingKeys: String, CodingKey {
        case content, minClientVersion, limits, killSwitches, flags, serverTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(LKContentPointer.self, forKey: .content)
        minClientVersion = try container.decode([String: String].self, forKey: .minClientVersion)
        limits = try container.decode(LKLimits.self, forKey: .limits)
        killSwitches = try container.decode([String: Bool].self, forKey: .killSwitches)
        flags = try container.decode([String: Bool].self, forKey: .flags)
        serverTime = try container.decode(Date.self, forKey: .serverTime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encode(minClientVersion, forKey: .minClientVersion)
        try container.encode(limits, forKey: .limits)
        try container.encode(killSwitches, forKey: .killSwitches)
        try container.encode(flags, forKey: .flags)
        if let serverTime {
            try container.encode(serverTime, forKey: .serverTime)
        } else {
            try container.encodeNil(forKey: .serverTime)
        }
    }

    package static let builtIn = LKAppConfig(
        content: nil,
        minClientVersion: ["ios": "0.0.0"],
        limits: LKLimits(mode: "dailyLessonCap", value: 3),
        killSwitches: ["player": false, "sync": false],
        flags: ["leagues": false],
        serverTime: nil
    )
}

public struct LKManifest: Sendable, Equatable {
    public let version: Int
    public let lessonIds: [String]

    public init(version: Int, lessonIds: [String]) {
        self.version = version
        self.lessonIds = lessonIds
    }
}

public struct LKDecodedStep: Sendable, Equatable {
    public let id: String
    public let type: String
    public let supported: Bool

    public init(id: String, type: String, supported: Bool) {
        self.id = id
        self.type = type
        self.supported = supported
    }
}

public struct LKLesson: Sendable, Equatable {
    public let id: String
    public let title: String
    public let symbol: String
    public let formatVersion: Int
    public let steps: [LKDecodedStep]

    public init(id: String, title: String, symbol: String, formatVersion: Int, steps: [LKDecodedStep]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.formatVersion = formatVersion
        self.steps = steps
    }
}

public struct LKLessonFile: Sendable {
    public let id: String
    public let version: String
    public let data: Data
    public let lesson: LKLesson

    public init(id: String, version: String, data: Data, lesson: LKLesson) {
        self.id = id
        self.version = version
        self.data = data
        self.lesson = lesson
    }
}

public struct LKLessonPlan: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case native, player, placeholder, hidden
    }

    public let playable: Bool
    public let reason: String?
    public let steps: [(id: String, action: Action)]

    public init(playable: Bool, reason: String?, steps: [(id: String, action: Action)]) {
        self.playable = playable
        self.reason = reason
        self.steps = steps
    }

    public static func == (lhs: LKLessonPlan, rhs: LKLessonPlan) -> Bool {
        lhs.playable == rhs.playable && lhs.reason == rhs.reason && lhs.steps.elementsEqual(rhs.steps, by: ==)
    }
}

public struct LKAttempt: Sendable, Equatable, Codable {
    public let id: UUID
    public let sessionId: UUID
    public let lessonId: String
    public let lessonVersion: String?
    public let stepId: String
    public let position: Int
    public let mode: LKMode
    public let response: LKResponse
    public let correct: Bool?
    public let answeredAt: Date

    public init(
        sessionId: UUID,
        lessonId: String,
        lessonVersion: String?,
        stepId: String,
        position: Int,
        mode: LKMode,
        response: LKResponse,
        correct: Bool?,
        answeredAt: Date = .now
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.lessonId = lessonId
        self.lessonVersion = lessonVersion
        self.stepId = stepId
        self.position = position
        self.mode = mode
        self.response = response
        self.correct = correct
        self.answeredAt = answeredAt
    }

    package init(
        id: UUID,
        sessionId: UUID,
        lessonId: String,
        lessonVersion: String?,
        stepId: String,
        position: Int,
        mode: LKMode,
        response: LKResponse,
        correct: Bool?,
        answeredAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.lessonId = lessonId
        self.lessonVersion = lessonVersion
        self.stepId = stepId
        self.position = position
        self.mode = mode
        self.response = response
        self.correct = correct
        self.answeredAt = answeredAt
    }
}

public enum LKResponse: Sendable, Equatable, Codable {
    case choice(Int)
    case player([String: LKJSON])
    case none

    private enum Kind: String, Codable {
        case choice, player, none
    }

    private struct Box: Codable {
        var kind: Kind
        var choice: Int?
        var player: [String: LKJSON]?
    }

    public init(from decoder: Decoder) throws {
        let box = try Box(from: decoder)
        switch box.kind {
        case .choice:
            self = .choice(box.choice ?? 0)
        case .player:
            self = .player(box.player ?? [:])
        case .none:
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .choice(let index):
            try Box(kind: .choice, choice: index, player: nil).encode(to: encoder)
        case .player(let object):
            try Box(kind: .player, choice: nil, player: object).encode(to: encoder)
        case .none:
            try Box(kind: .none, choice: nil, player: nil).encode(to: encoder)
        }
    }
}

public enum LKMode: String, Sendable, Codable, Equatable {
    case lesson
    case testOut = "test_out"
    case practice
    case mistakes
    case rep
}

public struct LKSessionCompletion: Sendable, Codable, Equatable {
    public let id: UUID
    public let mode: LKMode
    public let lessonId: String?
    public let lessonVersion: String?
    public let unitId: String?
    public let startedAt: Date
    public let completedAt: Date
    public let stepCount: Int

    public init(
        id: UUID,
        mode: LKMode,
        lessonId: String?,
        lessonVersion: String?,
        unitId: String?,
        startedAt: Date,
        completedAt: Date = .now,
        stepCount: Int
    ) {
        self.id = id
        self.mode = mode
        self.lessonId = lessonId
        self.lessonVersion = lessonVersion
        self.unitId = unitId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stepCount = stepCount
    }
}

public struct LKLessonResult: Sendable, Codable, Equatable {
    public var bestAccuracy: Double
    public var completions: Int
    public var isPerfect: Bool

    public init(bestAccuracy: Double, completions: Int, isPerfect: Bool) {
        self.bestAccuracy = bestAccuracy
        self.completions = completions
        self.isPerfect = isPerfect
    }
}

public struct LKProgressState: Sendable, Codable, Equatable {
    public let userId: UUID
    public let isGuest: Bool
    public let xpTotal: Int
    public let streak: Int
    public let longestStreak: Int
    public let lastActiveDay: String?
    public let streakFreezes: Int
    public let xpByDay: [String: Int]
    public let lessonsByDay: [String: Int]
    public let lessonResults: [String: LKLessonResult]
    public let serverTime: Date

    public init(
        userId: UUID,
        isGuest: Bool,
        xpTotal: Int,
        streak: Int,
        longestStreak: Int,
        lastActiveDay: String?,
        streakFreezes: Int,
        xpByDay: [String: Int],
        lessonsByDay: [String: Int],
        lessonResults: [String: LKLessonResult],
        serverTime: Date
    ) {
        self.userId = userId
        self.isGuest = isGuest
        self.xpTotal = xpTotal
        self.streak = streak
        self.longestStreak = longestStreak
        self.lastActiveDay = lastActiveDay
        self.streakFreezes = streakFreezes
        self.xpByDay = xpByDay
        self.lessonsByDay = lessonsByDay
        self.lessonResults = lessonResults
        self.serverTime = serverTime
    }

    private enum CodingKeys: String, CodingKey {
        case userId, isGuest, xpTotal, streak, longestStreak, lastActiveDay, streakFreezes
        case xpByDay, lessonsByDay, lessonResults, serverTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(UUID.self, forKey: .userId)
        isGuest = try container.decode(Bool.self, forKey: .isGuest)
        xpTotal = try container.decode(Int.self, forKey: .xpTotal)
        streak = try container.decode(Int.self, forKey: .streak)
        longestStreak = try container.decode(Int.self, forKey: .longestStreak)
        guard container.contains(.lastActiveDay) else {
            throw DecodingError.keyNotFound(CodingKeys.lastActiveDay, .init(codingPath: decoder.codingPath, debugDescription: "lastActiveDay"))
        }
        lastActiveDay = try container.decodeIfPresent(String.self, forKey: .lastActiveDay)
        streakFreezes = try container.decode(Int.self, forKey: .streakFreezes)
        xpByDay = try container.decode([String: Int].self, forKey: .xpByDay)
        lessonsByDay = try container.decode([String: Int].self, forKey: .lessonsByDay)
        lessonResults = try container.decode([String: LKLessonResult].self, forKey: .lessonResults)
        serverTime = try container.decode(Date.self, forKey: .serverTime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(isGuest, forKey: .isGuest)
        try container.encode(xpTotal, forKey: .xpTotal)
        try container.encode(streak, forKey: .streak)
        try container.encode(longestStreak, forKey: .longestStreak)
        if let lastActiveDay {
            try container.encode(lastActiveDay, forKey: .lastActiveDay)
        } else {
            try container.encodeNil(forKey: .lastActiveDay)
        }
        try container.encode(streakFreezes, forKey: .streakFreezes)
        try container.encode(xpByDay, forKey: .xpByDay)
        try container.encode(lessonsByDay, forKey: .lessonsByDay)
        try container.encode(lessonResults, forKey: .lessonResults)
        try container.encode(serverTime, forKey: .serverTime)
    }
}

public struct LKSyncResult: Sendable {
    public let sent: Int
    public let accepted: Int
    public let rejected: [(id: UUID, code: String)]
    public let remaining: Int
    public let error: LKError?

    public init(sent: Int, accepted: Int, rejected: [(id: UUID, code: String)], remaining: Int, error: LKError?) {
        self.sent = sent
        self.accepted = accepted
        self.rejected = rejected
        self.remaining = remaining
        self.error = error
    }
}

public enum LKError: Error, Sendable, Equatable {
    case configMissing(String)
    case ageGateRequired
    case offline
    case notFound(String)
    case integrity(String)
    case unsupportedManifest(Int)
    case server(code: String, status: Int)
}
