import Foundation

/// Un cache à durée de vie : une valeur n'est rendue que tant qu'elle est fraîche, et peut être effacée d'un coup (la page a changé, la tâche est finie).
public final class TTLCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry { var value: Value; var expires: Date; var order: Int }
    private var counter = 0
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = capacity }

    public func value(for key: String, now: Date = Date()) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard entry.expires > now else { entries[key] = nil; return nil }
        return entry.value
    }

    public func set(_ value: Value, for key: String, ttl: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        entries[key] = Entry(value: value, expires: now.addingTimeInterval(ttl), order: counter)
        if entries.count > capacity {
            entries = entries.filter { $0.value.expires > now }
            while entries.count > capacity, let oldest = entries.min(by: { $0.value.order < $1.value.order })?.key { entries[oldest] = nil }      // le plus ancien d'abord
        }
    }

    public func remove(prefix: String) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    public func removeAll() { lock.lock(); entries = [:]; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

/// Une empreinte courte et stable d'un texte (FNV-1a 64 bits) : de quoi savoir si une page a changé, sans garder la page.
public enum ContentSignature {
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
