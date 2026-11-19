import Foundation
import LevelifyKit

/// Bridge protocol v1, matched to `packages/contract/src/bridge.ts`.
/// The wire is one JSON string, at most 65,536 UTF-8 bytes. The scheme handler matches the raw URL text.
package enum BridgeDirection: String, Sendable, Equatable {
    case toPlayer
    case toHost
}

package struct BridgeMessage: Equatable, Sendable {
    package var bridge: Int
    package var id: String
    package var type: String
    package var payload: [String: LKJSON]
    package var replyTo: String?

    package init(bridge: Int = 1, id: String, type: String, payload: [String: LKJSON], replyTo: String? = nil) {
        self.bridge = bridge
        self.id = id
        self.type = type
        self.payload = payload
        self.replyTo = replyTo
    }
}

package enum BridgeVerdict: Equatable, Sendable {
    case accept(BridgeMessage)
    case ignore(code: String, type: String, detail: String)
    case reject(code: String, detail: String)
}

package enum SchemeTarget: Equatable, Sendable {
    case build(file: String, contentType: String)
    case media(sha256: String, ext: String, contentType: String)
    case notFound
}

package let bridgeVersions = [1]
package let maxMessageBytes = 65_536
package let maxResponseBytes = 2_048
package let maxAnnounceScalars = 200
package let playerOrigin = "levelify-player://player"
package let playerEntryURL = "levelify-player://player/index.html"

package let playerContentTypes: [String: String] = [
    "html": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "webp": "image/webp",
    "mp3": "audio/mpeg",
    "m4a": "audio/mp4",
]

private let hostToPlayer = ["host.hello", "step.load", "settings.update", "step.lock", "step.unload"]
private let playerToHost = ["player.hello", "player.ready", "step.result", "haptic", "sound", "a11y.announce", "player.error"]
private let hapticKinds = ["success", "error", "tap", "celebrate"]
private let soundKinds = ["correct", "wrong", "tap"]
private let playerErrorCodes = ["step_type_unknown", "step_invalid", "media_missing", "internal"]

package func mediaURL(sha256: String, ext: String) -> String {
    "\(playerOrigin)/media/\(sha256).\(ext)"
}

package func chooseBridgeVersion(_ playerVersions: [Int], _ hostVersions: [Int]) -> Int? {
    let host = Set(hostVersions)
    return playerVersions.filter { host.contains($0) }.max()
}

/// What the scheme handler serves. Do not normalise `url` before calling this.
package func resolvePlayerUrl(_ url: String) -> SchemeTarget {
    let prefix = playerOrigin + "/"
    guard url.hasPrefix(prefix) else { return .notFound }
    let path = String(url.dropFirst(prefix.count))
    if path.contains("?") || path.contains("#") || path.contains("%") || path.contains("\\") { return .notFound }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 1 {
        let file = parts[0]
        guard whole("^[a-z0-9][a-z0-9._-]{0,63}$", file), !file.contains("..") else { return .notFound }
        guard let contentType = playerContentTypes[extensionOf(file)] else { return .notFound }
        return .build(file: file, contentType: contentType)
    }
    if parts.count == 2, parts[0] == "media" {
        guard let match = firstMatch("^([0-9a-f]{64})\\.([a-z0-9]{1,8})$", parts[1]), match.count == 3 else { return .notFound }
        guard let contentType = playerContentTypes[match[2]] else { return .notFound }
        return .media(sha256: match[1], ext: match[2], contentType: contentType)
    }
    return .notFound
}

package func parseMessage(_ raw: String, direction: BridgeDirection) -> BridgeVerdict {
    if raw.utf8.count > maxMessageBytes {
        return .reject(code: "too_large", detail: "over \(maxMessageBytes) bytes")
    }
    guard let value = JSONValue.parse(raw) else {
        return .reject(code: "not_json", detail: "not JSON text")
    }
    return validate(value, direction: direction)
}

/// A transport that already parsed the JSON. The size limit applies to `JSON.stringify` of that value.
package func parseMessageObject(_ raw: String, direction: BridgeDirection) -> BridgeVerdict {
    guard let value = JSONValue.parse(raw) else {
        return .reject(code: "not_json", detail: "not JSON text")
    }
    let text = value.stringify()
    if text.utf8.count > maxMessageBytes {
        return .reject(code: "too_large", detail: "over \(maxMessageBytes) bytes")
    }
    return validate(value, direction: direction)
}

private func validate(_ value: JSONValue, direction: BridgeDirection) -> BridgeVerdict {
    guard case .object(let fields) = value else {
        return .reject(code: "bad_envelope", detail: "not a JSON object")
    }
    guard let bridge = fields.last("bridge"), isVersion(bridge) else {
        return .reject(code: "bad_envelope", detail: "bridge must be a version number")
    }
    guard let id = fields.last("id"), case .string(let idText) = id, isUUID(idText) else {
        return .reject(code: "bad_envelope", detail: "id must be a UUID")
    }
    guard let typeValue = fields.last("type"), case .string(let type) = typeValue, jsLen(type) <= 64, isTypeName(type) else {
        return .reject(code: "bad_envelope", detail: "type must be a message type name")
    }
    guard let payloadValue = fields.last("payload"), case .object(let payload) = payloadValue else {
        return .reject(code: "bad_envelope", detail: "payload must be an object")
    }
    let reply: String?
    if let replyValue = fields.last("replyTo") {
        guard case .string(let replyText) = replyValue, isUUID(replyText) else {
            return .reject(code: "bad_envelope", detail: "replyTo must be a UUID")
        }
        reply = replyText
    } else {
        reply = nil
    }

    let mine = direction == .toPlayer ? hostToPlayer : playerToHost
    let theirs = direction == .toPlayer ? playerToHost : hostToPlayer
    if theirs.contains(type) {
        return .reject(code: "wrong_direction", detail: "\(type) is not sent to this side")
    }
    if !mine.contains(type) {
        return .ignore(code: "unknown_type", type: type, detail: "unknown message type \(type)")
    }

    do {
        if let ignore = try checkPayload(type: type, payload: payload) {
            return .ignore(code: ignore, type: type, detail: "unknown value in \(type)")
        }
    } catch let error as PayloadError {
        return .reject(code: "bad_payload", detail: "\(type): \(error.detail)")
    } catch {
        return .reject(code: "bad_payload", detail: type)
    }

    if type == "host.hello", fields.last("bridge") != payload.last("bridge") {
        return .reject(code: "bad_envelope", detail: "host.hello's bridge must equal payload.bridge")
    }
    if type == "player.hello", intValue(fields.last("bridge")) != 1 {
        return .reject(code: "bad_envelope", detail: "player.hello always carries bridge 1")
    }
    return .accept(BridgeMessage(
        bridge: intValue(fields.last("bridge")) ?? 0,
        id: idText,
        type: type,
        payload: payload.asLKJSON(),
        replyTo: reply
    ))
}

private struct PayloadError: Error { var detail: String }

private func need(_ condition: Bool, _ detail: String) throws {
    if !condition { throw PayloadError(detail: detail) }
}

private func checkPayload(type: String, payload: JSONFields) throws -> String? {
    switch type {
    case "host.hello":
        try need(isVersion(payload.last("bridge")), "payload.bridge must be a version number")
        if case .string(let host) = payload.last("host") {
            try need(jsLen(host) >= 1 && jsLen(host) <= 100, "payload.host must be 1 to 100 characters")
        } else {
            try need(false, "payload.host must be 1 to 100 characters")
        }
        if case .string(let platform) = payload.last("platform") {
            try need(jsLen(platform) <= 32 && isToken(platform), "payload.platform must be a token")
        } else {
            try need(false, "payload.platform must be a token")
        }
        if case .string(let locale) = payload.last("locale") {
            try need(jsLen(locale) <= 35 && isLocale(locale), "payload.locale must be a BCP 47 tag")
        } else {
            try need(false, "payload.locale must be a BCP 47 tag")
        }
        try checkSettings(payload.last("settings"), at: "payload.settings")
    case "step.load":
        try need(isContentId(payload.last("lessonId")), "payload.lessonId must be a content id")
        let version = payload.last("lessonVersion")
        if case .null = version {
        } else if case .string(let sha) = version, isSHA256(sha) {
        } else {
            try need(false, "payload.lessonVersion must be a SHA-256 or null")
        }
        guard case .object(let step) = payload.last("step") else {
            try need(false, "payload.step must be an object")
            return nil
        }
        try need(isContentId(step.last("id")), "payload.step.id must be a content id")
        if case .string(let stepType) = step.last("type") {
            try need(isStepType(stepType), "payload.step.type must be a step type name")
        } else {
            try need(false, "payload.step.type must be a step type name")
        }
        if step.last("typeVersion") != nil {
            try need(isVersion(step.last("typeVersion")), "payload.step.typeVersion must be a version number")
        }
        guard case .object(let media) = payload.last("media") else {
            try need(false, "payload.media must be an object")
            return nil
        }
        for (sha, url) in media.pairs {
            try need(isSHA256(sha), "payload.media keys must be SHA-256s")
            guard case .string(let text) = url else {
                try need(false, "payload.media values must be that file's levelify-player URL")
                continue
            }
            guard case .media(let mediaSha, let ext, _) = resolvePlayerUrl(text) else {
                try need(false, "payload.media values must be that file's levelify-player URL")
                continue
            }
            try need(mediaSha == sha && isMediaExt(ext), "payload.media values must be that file's levelify-player URL")
        }
    case "settings.update":
        try checkSettings(payload.last("settings"), at: "payload.settings")
    case "step.lock", "step.unload", "player.ready":
        try need(isContentId(payload.last("stepId")), "payload.stepId must be a content id")
    case "player.hello":
        guard case .array(let versions) = payload.last("bridgeVersions") else {
            try need(false, "payload.bridgeVersions must list 1 to 16 version numbers")
            return nil
        }
        try need(versions.count >= 1 && versions.count <= 16 && versions.allSatisfy(isVersion), "payload.bridgeVersions must list 1 to 16 version numbers")
        if case .string(let playerVersion) = payload.last("playerVersion") {
            try need(isSemver(playerVersion), "payload.playerVersion must be a semver")
        } else {
            try need(false, "payload.playerVersion must be a semver")
        }
        if let buildId = payload.last("buildId") {
            if case .string(let text) = buildId {
                try need(jsLen(text) <= 128 && isToken(text), "payload.buildId must be a token")
            } else {
                try need(false, "payload.buildId must be a token")
            }
        }
        guard case .object(let stepTypes) = payload.last("stepTypes") else {
            try need(false, "payload.stepTypes must be an object")
            return nil
        }
        for (name, version) in stepTypes.pairs {
            try need(isStepType(name) && isVersion(version), "payload.stepTypes must map type names to version numbers")
        }
    case "step.result":
        try need(isContentId(payload.last("stepId")), "payload.stepId must be a content id")
        let correct = payload.last("correct")
        if case .null = correct {
        } else if case .bool = correct {
        } else {
            try need(false, "payload.correct must be true, false or null")
        }
        try need(isSafeResponse(payload.last("response")), "payload.response must be an object of ids, numbers and enumerated values, at most 2 KB")
        if let duration = intValue(payload.last("durationMs")) {
            try need(duration >= 0 && duration <= 86_400_000, "payload.durationMs must be a whole number of milliseconds")
        } else {
            try need(false, "payload.durationMs must be a whole number of milliseconds")
        }
    case "haptic":
        guard case .string(let kind) = payload.last("kind") else {
            try need(false, "payload.kind must be a string")
            return nil
        }
        if !hapticKinds.contains(kind) { return "unknown_value" }
    case "sound":
        guard case .string(let kind) = payload.last("kind") else {
            try need(false, "payload.kind must be a string")
            return nil
        }
        if !soundKinds.contains(kind) { return "unknown_value" }
    case "a11y.announce":
        if case .string(let text) = payload.last("text") {
            try need(!jsTrim(text).isEmpty && text.unicodeScalars.count <= maxAnnounceScalars, "payload.text must be 1 to \(maxAnnounceScalars) characters")
        } else {
            try need(false, "payload.text must be 1 to \(maxAnnounceScalars) characters")
        }
    case "player.error":
        if case .string(let code) = payload.last("code") {
            try need(playerErrorCodes.contains(code), "payload.code must be a known error code")
        } else {
            try need(false, "payload.code must be a known error code")
        }
        let step = payload.last("stepId")
        if case .null = step {
        } else {
            try need(isContentId(step), "payload.stepId must be a content id or null")
        }
    default:
        break
    }
    return nil
}

private func checkSettings(_ value: JSONValue?, at: String) throws {
    guard case .object(let object) = value else { throw PayloadError(detail: "\(at) must be an object") }
    guard case .bool = object.last("reduceMotion") else { throw PayloadError(detail: "\(at).reduceMotion must be true or false") }
    guard case .number(let scale) = object.last("textScale"), scale.isFinite, scale >= 0.5, scale <= 4 else {
        throw PayloadError(detail: "\(at).textScale must be a number from 0.5 to 4")
    }
    guard case .string(let scheme) = object.last("colorScheme"), scheme == "light" || scheme == "dark" else {
        throw PayloadError(detail: "\(at).colorScheme must be \"light\" or \"dark\"")
    }
    guard case .bool = object.last("sound") else { throw PayloadError(detail: "\(at).sound must be true or false") }
    guard case .bool = object.last("haptics") else { throw PayloadError(detail: "\(at).haptics must be true or false") }
}

private func isSafeResponse(_ value: JSONValue?) -> Bool {
    guard let value, case .object = value else { return false }
    guard value.stringify().utf8.count <= maxResponseBytes else { return false }
    func ok(_ item: JSONValue, depth: Int) -> Bool {
        switch item {
        case .null, .bool: return true
        case .number(let number): return number.isFinite
        case .string(let text): return jsLen(text) <= 64 && isToken(text)
        case .array(let items):
            if depth >= 3 { return false }
            return items.count <= 64 && items.allSatisfy { ok($0, depth: depth + 1) }
        case .object(let fields):
            if depth >= 3 { return false }
            return fields.pairs.allSatisfy { jsLen($0.0) <= 64 && isToken($0.0) && ok($0.1, depth: depth + 1) }
        }
    }
    return ok(value, depth: 0)
}

private func isVersion(_ value: JSONValue?) -> Bool {
    guard let number = intValue(value) else { return false }
    return number >= 1 && number <= 1_000
}

private func intValue(_ value: JSONValue?) -> Int? {
    guard case .number(let number) = value, number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_992 else { return nil }
    return Int(number)
}

private func isContentId(_ value: JSONValue?) -> Bool {
    guard case .string(let text) = value else { return false }
    return jsLen(text) <= 64 && whole("^[a-z0-9]+(?:-[a-z0-9]+)*$", text)
}

private func isUUID(_ text: String) -> Bool {
    whole("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", text, caseInsensitive: true)
}

private func isSHA256(_ text: String) -> Bool { whole("^[0-9a-f]{64}$", text) }
private func isTypeName(_ text: String) -> Bool { whole("^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", text, caseInsensitive: true) }
private func isStepType(_ text: String) -> Bool { whole("^[A-Za-z][A-Za-z0-9]{0,63}$", text) }
private func isToken(_ text: String) -> Bool { whole("^[A-Za-z0-9]+(?:[._:-][A-Za-z0-9]+)*$", text) }
private func isSemver(_ text: String) -> Bool { whole("^\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?$", text) }
private func isLocale(_ text: String) -> Bool { whole("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", text) }
private func isMediaExt(_ text: String) -> Bool { whole("^[a-z0-9]{1,8}$", text) }

private func extensionOf(_ file: String) -> String {
    guard let dot = file.lastIndex(of: ".") else { return "" }
    return String(file[file.index(after: dot)...])
}

private func jsLen(_ text: String) -> Int { text.utf16.count }

private func jsTrim(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
}

private func whole(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
    firstMatch(pattern, text, caseInsensitive: caseInsensitive) != nil
}

private func firstMatch(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> [String]? {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, options: [], range: range), match.range == range else { return nil }
    return captures(match, in: text)
}

private func captures(_ match: NSTextCheckingResult, in text: String) -> [String] {
    (0..<match.numberOfRanges).compactMap { index in
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

/// JSON value that keeps bools distinct from numbers, and object key order.
private enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONFields)

    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(text)
        guard let value = parser.parseValue(), parser.skipWhitespace(), parser.done else { return nil }
        return value
    }

    func stringify() -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value.rounded() == value, abs(value) <= Double(Int64.max) {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value): return quote(value)
        case .array(let values): return "[" + values.map { $0.stringify() }.joined(separator: ",") + "]"
        case .object(let fields):
            let body = fields.pairs.map { quote($0.0) + ":" + $0.1.stringify() }.joined(separator: ",")
            return "{" + body + "}"
        }
    }

    func asLKJSON() -> LKJSON {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map { $0.asLKJSON() })
        case .object(let fields): return .object(fields.asLKJSON())
        }
    }
}

private struct JSONFields: Equatable {
    var pairs: [(String, JSONValue)]

    func last(_ key: String) -> JSONValue? {
        pairs.last { $0.0 == key }?.1
    }

    func asLKJSON() -> [String: LKJSON] {
        var object: [String: LKJSON] = [:]
        for (key, value) in pairs { object[key] = value.asLKJSON() }
        return object
    }

    static func == (lhs: JSONFields, rhs: JSONFields) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

private func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5c: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0c: out += "\\f"
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        case 0x2028: out += "\\u2028"
        case 0x2029: out += "\\u2029"
        case 0x00..<0x20:
            out += String(format: "\\u%04x", scalar.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}

private struct JSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    var done: Bool { index >= scalars.count }

    mutating func parseValue() -> JSONValue? {
        guard skipWhitespace(), !done else { return nil }
        switch scalars[index].value {
        case 0x6e: return consumeLiteral("null") ? .null : nil
        case 0x74: return consumeLiteral("true") ? .bool(true) : nil
        case 0x66: return consumeLiteral("false") ? .bool(false) : nil
        case 0x22: return parseString().map(JSONValue.string)
        case 0x5b: return parseArray()
        case 0x7b: return parseObject()
        case 0x2d, 0x30...0x39: return parseNumber()
        default: return nil
        }
    }

    mutating func skipWhitespace() -> Bool {
        while !done, isSpace(scalars[index].value) { index += 1 }
        return true
    }

    mutating func parseObject() -> JSONValue? {
        index += 1
        var pairs: [(String, JSONValue)] = []
        guard skipWhitespace() else { return nil }
        if !done, scalars[index].value == 0x7d { index += 1; return .object(JSONFields(pairs: [])) }
        while !done {
            guard let key = parseString(), skipWhitespace(), consume(0x3a), let value = parseValue() else { return nil }
            if let existing = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[existing] = (key, value)
            } else {
                pairs.append((key, value))
            }
            guard skipWhitespace() else { return nil }
            if !done, scalars[index].value == 0x7d { index += 1; return .object(JSONFields(pairs: pairs)) }
            guard consume(0x2c) else { return nil }
            _ = skipWhitespace()
        }
        return nil
    }

    mutating func parseArray() -> JSONValue? {
        index += 1
        var values: [JSONValue] = []
        guard skipWhitespace() else { return nil }
        if !done, scalars[index].value == 0x5d { index += 1; return .array([]) }
        while !done {
            guard let value = parseValue() else { return nil }
            values.append(value)
            guard skipWhitespace() else { return nil }
            if !done, scalars[index].value == 0x5d { index += 1; return .array(values) }
            guard consume(0x2c) else { return nil }
            _ = skipWhitespace()
        }
        return nil
    }

    mutating func parseString() -> String? {
        guard consume(0x22) else { return nil }
        var out = ""
        while !done {
            let value = scalars[index].value
            index += 1
            if value == 0x22 { return out }
            if value < 0x20 { return nil }
            if value != 0x5c {
                out.unicodeScalars.append(Unicode.Scalar(value)!)
                continue
            }
            guard !done else { return nil }
            let escaped = scalars[index].value
            index += 1
            switch escaped {
            case 0x22: out += "\""
            case 0x5c: out += "\\"
            case 0x2f: out += "/"
            case 0x62: out += "\u{08}"
            case 0x66: out += "\u{0c}"
            case 0x6e: out += "\n"
            case 0x72: out += "\r"
            case 0x74: out += "\t"
            case 0x75:
                guard let unit = hex4() else { return nil }
                if let scalar = Unicode.Scalar(unit) {
                    out.unicodeScalars.append(scalar)
                } else {
                    return nil
                }
            default: return nil
            }
        }
        return nil
    }

    mutating func parseNumber() -> JSONValue? {
        let start = index
        if consume(0x2d), done { return nil }
        guard !done else { return nil }
        if scalars[index].value == 0x30 {
            index += 1
        } else if (0x31...0x39).contains(scalars[index].value) {
            while !done, (0x30...0x39).contains(scalars[index].value) { index += 1 }
        } else {
            return nil
        }
        if !done, scalars[index].value == 0x2e {
            index += 1
            let fraction = index
            while !done, (0x30...0x39).contains(scalars[index].value) { index += 1 }
            if index == fraction { return nil }
        }
        if !done, scalars[index].value == 0x65 || scalars[index].value == 0x45 {
            index += 1
            if !done, scalars[index].value == 0x2b || scalars[index].value == 0x2d { index += 1 }
            let exponent = index
            while !done, (0x30...0x39).contains(scalars[index].value) { index += 1 }
            if index == exponent { return nil }
        }
        let literal = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let number = Double(literal), number.isFinite else { return nil }
        return .number(number)
    }

    mutating func hex4() -> UInt32? {
        var unit: UInt32 = 0
        for _ in 0..<4 {
            guard !done else { return nil }
            let value = scalars[index].value
            index += 1
            unit <<= 4
            switch value {
            case 0x30...0x39: unit += value - 0x30
            case 0x61...0x66: unit += value - 0x61 + 10
            case 0x41...0x46: unit += value - 0x41 + 10
            default: return nil
            }
        }
        return unit
    }

    mutating func consumeLiteral(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            guard !done, scalars[index] == scalar else { return false }
            index += 1
        }
        return true
    }

    mutating func consume(_ value: UInt32) -> Bool {
        guard !done, scalars[index].value == value else { return false }
        index += 1
        return true
    }

    func isSpace(_ value: UInt32) -> Bool {
        value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d
    }
}
