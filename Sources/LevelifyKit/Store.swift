import Foundation

package struct OutboxItem: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case attempt, session }
    package var kind: Kind
    package var attempt: LKAttempt?
    package var session: LKSessionCompletion?
}

package struct AgeGateRecord: Codable, Equatable, Sendable {
    package var confirmed: Bool
    package var year: Int?
    package var month: Int?
}

/// Application Support files for the age gate, outbox, and verified content. Synchronous and lock-guarded.
package final class LKStore: @unchecked Sendable {
    package let root: URL
    private let lock = NSLock()
    private var sequence: Int

    package init(root: URL) {
        self.root = root
        let fm = FileManager.default
        for name in ["outbox", "files", "player"] {
            try? fm.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        sequence = Self.nextSequence(in: root.appendingPathComponent("outbox"))
    }

    package func ageGate() -> AgeGateRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("age-gate.json")),
              let record = try? LKCoding.decode(AgeGateRecord.self, from: data) else {
            return AgeGateRecord(confirmed: false, year: nil, month: nil)
        }
        return record
    }

    package func setAgeGate(confirmed: Bool, minorUntil: LKMonth?) {
        let record = AgeGateRecord(confirmed: confirmed, year: minorUntil?.year, month: minorUntil?.month)
        write(record, name: "age-gate.json")
    }

    package func savedConfig() -> Data? { read("config.json") }
    package func saveConfig(_ data: Data) { write(data, name: "config.json") }
    package func savedManifest() -> Data? { read("manifest.json") }
    package func saveManifest(_ data: Data) { write(data, name: "manifest.json") }
    package func savedState() -> Data? { read("progress-state.json") }
    package func saveState(_ data: Data) { write(data, name: "progress-state.json") }

    package func file(sha: String) -> Data? {
        let url = root.appendingPathComponent("files").appendingPathComponent(sha.lowercased())
        return try? Data(contentsOf: url)
    }

    package func saveFile(sha: String, data: Data) {
        let url = root.appendingPathComponent("files").appendingPathComponent(sha.lowercased())
        try? data.write(to: url, options: .atomic)
    }

    package func append(_ item: OutboxItem) {
        lock.lock()
        let name = String(format: "%016d-%@.json", sequence, (item.attempt?.id ?? item.session?.id ?? UUID()).uuidString.lowercased())
        sequence += 1
        lock.unlock()
        guard let data = try? LKCoding.encoder().encode(item) else { return }
        let url = root.appendingPathComponent("outbox").appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
    }

    package func outbox() -> [OutboxItem] {
        let directory = root.appendingPathComponent("outbox")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasSuffix(".json") && !$0.contains(".tmp") }.sorted()
        var items: [OutboxItem] = []
        for name in files {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let item = try? LKCoding.decode(OutboxItem.self, from: data) else { continue }
            items.append(item)
        }
        return items
    }

    package func count() -> Int { outbox().count }

    package func remove(ids: Set<UUID>) {
        let directory = root.appendingPathComponent("outbox")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let item = try? LKCoding.decode(OutboxItem.self, from: data) else { continue }
            let id = item.attempt?.id ?? item.session?.id
            if let id, ids.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func read(_ name: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(name))
    }

    private func write<T: Encodable>(_ value: T, name: String) {
        guard let data = try? LKCoding.encoder().encode(value) else { return }
        write(data, name: name)
    }

    private func write(_ data: Data, name: String) {
        try? data.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    private static func nextSequence(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let maxValue = names.compactMap { name -> Int? in
            guard name.hasSuffix(".json") else { return nil }
            return Int(name.split(separator: "-").first ?? "")
        }.max() ?? 0
        return maxValue + 1
    }
}
