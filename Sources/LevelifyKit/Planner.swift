import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Swift port of `packages/contract/src/lesson-format.ts` (`decodeLesson` and `planLesson`).
package enum LessonPlanner {
    package static let nativeRegistry: Set<String> = [
        "multipleChoice", "pickPrompt", "fillBlank", "buildPrompt", "spotProblem", "matchPairs", "freeWrite",
    ]

    package struct RawPlan: Equatable, Sendable {
        package var ok: Bool
        package var failure: String?
        package var playable: Bool
        package var reason: String?
        package var steps: [(id: String, action: String, type: String, typeVersion: Int)]

        package static func == (lhs: RawPlan, rhs: RawPlan) -> Bool {
            lhs.ok == rhs.ok && lhs.failure == rhs.failure && lhs.playable == rhs.playable && lhs.reason == rhs.reason
                && lhs.steps.elementsEqual(rhs.steps, by: { $0.id == $1.id && $0.action == $1.action && $0.type == $1.type && $0.typeVersion == $1.typeVersion })
        }
    }

    /// `planLesson` against `caps`, then the host mapping from docs/08 §8.3.
    /// Shell types stay `native`. A type only the Player build covers becomes `player`.
    package static func hostPlan(
        lesson: Data,
        shell: LKCapabilities,
        playerStepTypes: [String: Int],
        playerAvailable: Bool
    ) -> LKLessonPlan {
        var effective = shell.stepTypes
        if playerAvailable {
            for (type, version) in playerStepTypes where effective[type] == nil {
                effective[type] = version
            }
        }
        let caps = LKCapabilities(formatVersion: shell.formatVersion, stepTypes: effective)
        let raw = plan(lesson: lesson, caps: caps)
        if raw.failure != nil || !raw.ok {
            return LKLessonPlan(playable: false, reason: "update-app", steps: [])
        }
        let steps: [(id: String, action: LKLessonPlan.Action)] = raw.steps.map { step in
            let action: LKLessonPlan.Action
            switch step.action {
            case "play":
                if let have = shell.stepTypes[step.type], step.typeVersion <= have {
                    action = .native
                } else {
                    action = .player
                }
            case "hidden":
                action = .hidden
            default:
                action = .placeholder
            }
            return (id: step.id, action: action)
        }
        var reason = raw.reason
        if reason == "missing-step-types" {
            let missingNative = effectiveMissing(lesson: lesson, caps: caps).contains { nativeRegistry.contains($0) }
            reason = missingNative ? "missing-step-types" : "player-unavailable"
        }
        return LKLessonPlan(playable: raw.playable, reason: reason, steps: steps)
    }

    package static func plan(lesson data: Data, caps: LKCapabilities) -> RawPlan {
        guard let root = jsonObject(data) else {
            return RawPlan(ok: false, failure: "malformed", playable: false, reason: "update-app", steps: [])
        }
        let decoded = decodeLesson(root, caps: caps)
        guard decoded.ok, let lesson = decoded.lesson else {
            return RawPlan(ok: false, failure: decoded.failure ?? "malformed", playable: false, reason: "update-app", steps: [])
        }
        let planned = planLesson(lesson, caps: caps)
        return RawPlan(ok: true, failure: nil, playable: planned.playable, reason: planned.reason, steps: planned.steps)
    }

    package static func decodedLesson(data: Data, caps: LKCapabilities) -> LKLesson? {
        guard let root = jsonObject(data) else { return nil }
        let decoded = decodeLesson(root, caps: caps)
        guard let lesson = decoded.lesson else { return nil }
        return LKLesson(
            id: lesson.id,
            title: lesson.title,
            symbol: lesson.symbol,
            formatVersion: lesson.formatVersion,
            steps: lesson.steps.map {
                LKDecodedStep(id: $0.id, type: $0.type, supported: $0.kind == .step)
            }
        )
    }

    private static func effectiveMissing(lesson data: Data, caps: LKCapabilities) -> [String] {
        guard let root = jsonObject(data), let lesson = decodeLesson(root, caps: caps).lesson else { return [] }
        return lesson.requires.compactMap { type, need in
            let have = caps.stepTypes[type] ?? 0
            return have < need ? type : nil
        }
    }

    private static func jsonObject(_ data: Data) -> J? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let value = J.from(object)
        if case .object = value { return value }
        return nil
    }
}

private extension LessonPlanner {
    struct Decoded {
        var ok: Bool
        var failure: String?
        var lesson: Lesson?
    }

    struct Lesson {
        var id: String
        var title: String
        var symbol: String
        var formatVersion: Int
        var requires: [String: Int]
        var steps: [Step]
    }

    struct Step {
        enum Kind { case step, unsupported }
        var kind: Kind
        var id: String
        var type: String
        var typeVersion: Int
        var fallbackFor: String?
    }

    static func decodeLesson(_ raw: J, caps: LKCapabilities) -> Decoded {
        guard case .object(let root) = raw else {
            return Decoded(ok: false, failure: "malformed", lesson: nil)
        }
        let formatVersion: Int
        if root["formatVersion"] == nil {
            formatVersion = 1
        } else if let number = intValue(root["formatVersion"]), number >= 1 {
            formatVersion = number
        } else {
            return Decoded(ok: false, failure: "malformed", lesson: nil)
        }
        if formatVersion > caps.formatVersion {
            return Decoded(ok: false, failure: "format-too-new", lesson: nil)
        }
        guard let id = string(root["id"]), let title = string(root["title"]), let symbol = string(root["symbol"]),
              let exercises = array(root["exercises"]) else {
            return Decoded(ok: false, failure: "malformed", lesson: nil)
        }
        var requires: [String: Int] = [:]
        if let declared = object(object(root["requires"])?["stepTypes"]) {
            for (type, version) in declared {
                guard let number = intValue(version), number >= 1 else {
                    return Decoded(ok: false, failure: "malformed", lesson: nil)
                }
                requires[type] = number
            }
        }
        let steps = exercises.enumerated().map { decodeStep($0.element, index: $0.offset, caps: caps) }
        return Decoded(
            ok: true,
            failure: nil,
            lesson: Lesson(id: id, title: title, symbol: symbol, formatVersion: formatVersion, requires: requires, steps: steps)
        )
    }

    static func decodeStep(_ raw: J, index: Int, caps: LKCapabilities) -> Step {
        let fields = object(raw) ?? [:]
        let id = string(fields["id"]).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(index)"
        let type = string(fields["type"]) ?? ""
        let fallback = string(fields["fallbackFor"])
        func unsupported() -> Step {
            Step(kind: .unsupported, id: id, type: type, typeVersion: 1, fallbackFor: fallback)
        }
        let typeVersion: Int?
        if fields["typeVersion"] == nil {
            typeVersion = 1
        } else {
            typeVersion = intValue(fields["typeVersion"])
        }
        let common = object(raw) != nil && string(fields["id"]) == id && !type.isEmpty
            && string(fields["instruction"]) != nil && string(fields["explanation"]) != nil
            && isStringArray(fields["concepts"])
            && (typeVersion ?? 0) >= 1
            && (fields["fallbackFor"] == nil || string(fields["fallbackFor"]) != nil)
        guard common, let typeVersion else { return unsupported() }
        guard let supported = caps.stepTypes[type] else { return unsupported() }
        if typeVersion > supported { return unsupported() }
        if !sharedFieldsOk(fields) || payloadGuard(type, fields) == false { return unsupported() }
        return Step(kind: .step, id: id, type: type, typeVersion: typeVersion, fallbackFor: fallback)
    }

    static func planLesson(_ lesson: Lesson, caps: LKCapabilities) -> (playable: Bool, reason: String?, steps: [(id: String, action: String, type: String, typeVersion: Int)]) {
        let missing = lesson.requires.contains { type, need in (caps.stepTypes[type] ?? 0) < need }
        let byId = Dictionary(uniqueKeysWithValues: lesson.steps.map { ($0.id, $0) })
        let replaced = Set(lesson.steps.compactMap { step -> String? in
            guard step.kind == .step, let fallback = step.fallbackFor else { return nil }
            return fallback
        })
        let steps = lesson.steps.map { step -> (id: String, action: String, type: String, typeVersion: Int) in
            let action: String
            if let fallback = step.fallbackFor, byId[fallback]?.kind == .step {
                action = "hidden"
            } else if step.kind == .step {
                action = "play"
            } else {
                action = replaced.contains(step.id) ? "hidden" : "placeholder"
            }
            return (step.id, action, step.type, step.typeVersion)
        }
        if missing { return (false, "missing-step-types", steps) }
        if !steps.contains(where: { $0.action == "play" }) { return (false, "nothing-to-play", steps) }
        return (true, nil, steps)
    }

    static func sharedFieldsOk(_ step: [String: J]) -> Bool {
        for key in ["context", "template"] where step[key] != nil && string(step[key]) == nil { return false }
        for key in ["options", "tiles", "distractors", "segments", "rubric", "difficulty"] where step[key] != nil && !isStringArray(step[key]) {
            return false
        }
        if let pairs = step["pairs"] {
            guard let list = array(pairs), list.allSatisfy(isStringArray) else { return false }
        }
        if let answer = step["answer"] {
            guard let list = array(answer), list.allSatisfy({ intValue($0) != nil }) else { return false }
        }
        return true
    }

    static func payloadGuard(_ type: String, _ step: [String: J]) -> Bool? {
        switch type {
        case "multipleChoice", "pickPrompt":
            guard let options = stringArray(step["options"]), options.count >= 2 else { return false }
            return oneIndex(step["answer"], count: options.count)
        case "fillBlank":
            guard let options = stringArray(step["options"]), options.count >= 2,
                  oneIndex(step["answer"], count: options.count),
                  let template = string(step["template"]),
                  template.components(separatedBy: "___").count == 2 else { return false }
            return true
        case "buildPrompt":
            guard let tiles = stringArray(step["tiles"]), tiles.count >= 1 else { return false }
            return true
        case "spotProblem":
            guard let segments = stringArray(step["segments"]), segments.count >= 2 else { return false }
            return oneIndex(step["answer"], count: segments.count)
        case "matchPairs":
            guard let pairs = array(step["pairs"]), pairs.count >= 2 else { return false }
            return pairs.allSatisfy { pair in
                guard let values = stringArray(pair) else { return false }
                return values.count == 2
            }
        case "freeWrite":
            guard let rubric = stringArray(step["rubric"]), rubric.count >= 1 else { return false }
            return true
        default:
            return nil
        }
    }

    static func oneIndex(_ answer: J?, count: Int) -> Bool {
        guard let list = array(answer), list.count == 1, let index = intValue(list[0]) else { return false }
        return index >= 0 && index < count
    }

    static func intValue(_ value: J?) -> Int? {
        guard case .number(let number) = value, number.isFinite, number.rounded() == number,
              number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    static func string(_ value: J?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    static func array(_ value: J?) -> [J]? {
        if case .array(let list) = value { return list }
        return nil
    }

    static func object(_ value: J?) -> [String: J]? {
        if case .object(let object) = value { return object }
        return nil
    }

    static func isStringArray(_ value: J?) -> Bool {
        stringArray(value) != nil
    }

    static func stringArray(_ value: J?) -> [String]? {
        guard let list = array(value) else { return nil }
        var texts: [String] = []
        for item in list {
            guard let text = string(item) else { return nil }
            texts.append(text)
        }
        return texts
    }
}

private enum J {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([J])
    case object([String: J])

    static func from(_ value: Any) -> J {
        if value is NSNull { return .null }
        if let flag = boolean(value) { return .bool(flag) }
        if let number = value as? NSNumber { return .number(number.doubleValue) }
        if let text = value as? String { return .string(text) }
        if let list = value as? [Any] { return .array(list.map(from)) }
        if let object = value as? [String: Any] { return .object(object.mapValues(from)) }
        return .null
    }

    private static func boolean(_ value: Any) -> Bool? {
        #if canImport(CoreFoundation)
        if let object = value as? NSObject {
            let ref = object as CFTypeRef
            if CFGetTypeID(ref) == CFBooleanGetTypeID() {
                return (value as? NSNumber)?.boolValue ?? false
            }
        }
        #endif
        guard let number = value as? NSNumber else {
            if let flag = value as? Bool { return flag }
            return nil
        }
        let kind = String(cString: number.objCType)
        if kind == "c" || kind == "B" { return number.boolValue }
        return nil
    }
}
