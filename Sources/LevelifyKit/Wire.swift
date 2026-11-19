import Foundation

package enum LKTime {
    package static func string(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    package static func date(from string: String) -> Date? {
        let trimmed = string.hasSuffix("Z") ? String(string.dropLast()) : string
        let head = trimmed.split(separator: ".", maxSplits: 1).first.map(String.init) ?? trimmed
        let pieces = head.split(separator: "T")
        guard pieces.count == 2 else { return nil }
        let day = pieces[0].split(separator: "-")
        let time = pieces[1].split(separator: ":")
        guard day.count == 3, time.count >= 2,
              let year = Int(day[0]), let month = Int(day[1]), let dayNum = Int(day[2]),
              let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
        let second = time.count > 2 ? Int(time[2]) ?? 0 : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = dayNum
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return calendar.date(from: parts)
    }
}

package enum LKCoding {
    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = LKTime.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date")
            }
            return date
        }
        return decoder
    }

    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LKTime.string(date))
        }
        return encoder
    }

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(T.self, from: data)
    }
}

package struct SubmitBatch: Encodable, Equatable {
    package var client: String
    package var timezone: String
    package var attempts: [AttemptWire]
    package var sessions: [SessionWire]

    package init(client: String, timezone: String, attempts: [AttemptWire], sessions: [SessionWire]) {
        self.client = client
        self.timezone = timezone
        self.attempts = attempts
        self.sessions = sessions
    }
}

package struct AttemptWire: Encodable, Equatable {
    package var id: String
    package var sessionId: String
    package var lessonId: String
    package var lessonVersion: String?
    package var stepId: String
    package var position: Int
    package var mode: String
    package var response: ResponseWire
    package var correct: Bool?
    package var answeredAt: String

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, lessonId, lessonVersion, stepId, position, mode, response, correct, answeredAt
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(lessonId, forKey: .lessonId)
        try container.encodeNilable(lessonVersion, forKey: .lessonVersion)
        try container.encode(stepId, forKey: .stepId)
        try container.encode(position, forKey: .position)
        try container.encode(mode, forKey: .mode)
        try container.encode(response, forKey: .response)
        try container.encodeNilable(correct, forKey: .correct)
        try container.encode(answeredAt, forKey: .answeredAt)
    }
}

package struct SessionWire: Encodable, Equatable {
    package var id: String
    package var mode: String
    package var lessonId: String?
    package var lessonVersion: String?
    package var unitId: String?
    package var startedAt: String
    package var completedAt: String
    package var stepCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, mode, lessonId, lessonVersion, unitId, startedAt, completedAt, stepCount
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mode, forKey: .mode)
        try container.encodeNilable(lessonId, forKey: .lessonId)
        try container.encodeNilable(lessonVersion, forKey: .lessonVersion)
        try container.encodeNilable(unitId, forKey: .unitId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(stepCount, forKey: .stepCount)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNilable(_ value: String?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    mutating func encodeNilable(_ value: Bool?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

package enum ResponseWire: Encodable, Equatable {
    case choice(Int)
    case player([String: LKJSON])
    case none

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .choice(let index):
            try container.encode(["choice": index])
        case .player(let object):
            try container.encode(object)
        case .none:
            try container.encode([String: String]())
        }
    }
}

package struct SubmitEnvelope: Encodable {
    package var p_batch: SubmitBatch
}

package struct SubmitReply: Decodable {
    package var accepted: [String]
    package var rejected: [Rejected]
    package var state: LKProgressState

    package struct Rejected: Decodable {
        package var id: String
        package var code: String
    }
}

package enum LKWire {
    package static let callGetAppConfig = "get_app_config"
    package static let callSubmitAttempts = "submit_attempts"
    package static let callGetMyProgress = "get_my_progress"

    package static func attempt(_ attempt: LKAttempt) -> AttemptWire {
        AttemptWire(
            id: attempt.id.uuidString.lowercased(),
            sessionId: attempt.sessionId.uuidString.lowercased(),
            lessonId: attempt.lessonId,
            lessonVersion: attempt.lessonVersion,
            stepId: attempt.stepId,
            position: attempt.position,
            mode: attempt.mode.rawValue,
            response: response(attempt.response),
            correct: attempt.correct,
            answeredAt: LKTime.string(attempt.answeredAt)
        )
    }

    package static func session(_ session: LKSessionCompletion) -> SessionWire {
        SessionWire(
            id: session.id.uuidString.lowercased(),
            mode: session.mode.rawValue,
            lessonId: session.lessonId,
            lessonVersion: session.lessonVersion,
            unitId: session.unitId,
            startedAt: LKTime.string(session.startedAt),
            completedAt: LKTime.string(session.completedAt),
            stepCount: session.stepCount
        )
    }

    package static func response(_ response: LKResponse) -> ResponseWire {
        switch response {
        case .choice(let index): return .choice(index)
        case .player(let object): return .player(object)
        case .none: return .none
        }
    }

    package static func encodeEnvelope(_ batch: SubmitBatch) throws -> Data {
        try LKCoding.encoder().encode(SubmitEnvelope(p_batch: batch))
    }
}

package enum LKLog {
    package static func call(_ name: String, status: Int, code: String? = nil) {
        let line: String
        if let code {
            line = "levelifykit \(name) status=\(status) code=\(code)\n"
        } else {
            line = "levelifykit \(name) status=\(status)\n"
        }
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
