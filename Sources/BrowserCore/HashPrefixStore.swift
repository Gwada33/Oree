import Foundation
import CryptoKit

public enum HashPrefixStoreError: Error, Equatable, Sendable {
    case invalidPrefixSize(Int)
    case malformedRawHashes
    case unsortedAdditions
    case removalIndexOutOfRange(Int)
    case unsortedRemovals
    case checksumMismatch
}

/// Local copy of one Safe Browsing threat list: the set of SHA-256 hash
/// prefixes the server says are (possibly) bad.
///
/// The Update API defines the list as one lexicographically sorted sequence;
/// removals are *indices into that sequence* and the integrity checksum is the
/// SHA-256 of all prefixes concatenated in that order. Prefixes are almost
/// always 4 bytes but the protocol allows 4...32, and lexicographic order
/// interleaves sizes (a 4-byte prefix sorts before any longer prefix that
/// starts with it), so sizes are kept in separate flat sorted buffers and
/// merged on the fly only where the global order actually matters.
public struct HashPrefixStore: Sendable, Equatable {
    /// prefix size -> concatenated sorted prefixes of exactly that size.
    private var classes: [Int: [UInt8]] = [:]

    public init() {}

    public var count: Int {
        classes.reduce(0) { $0 + $1.value.count / $1.key }
    }

    public var isEmpty: Bool { classes.values.allSatisfy(\.isEmpty) }

    public struct Addition: Sendable {
        public let prefixSize: Int
        public let rawHashes: [UInt8]

        public init(prefixSize: Int, rawHashes: [UInt8]) {
            self.prefixSize = prefixSize
            self.rawHashes = rawHashes
        }
    }

    // MARK: - Lookup

    /// The stored prefix (of whatever size) that `hash` starts with, if any.
    public func matchingPrefix(of hash: Data) -> Data? {
        let bytes = [UInt8](hash)
        for (size, flat) in classes where bytes.count >= size {
            if Self.contains(bytes, size: size, in: flat) { return Data(bytes.prefix(size)) }
        }
        return nil
    }

    public func contains(hash: Data) -> Bool {
        matchingPrefix(of: hash) != nil
    }

    // MARK: - Updates

    /// Applies one server update atomically: on any error `self` is unchanged.
    ///
    /// - Parameter removalIndices: indices into the list as it was *before*
    ///   this update, ascending.
    public mutating func apply(removalIndices: [Int], additions: [Addition], expectedChecksum: Data? = nil) throws {
        var next = self

        try next.remove(indices: removalIndices)
        for addition in additions {
            try next.add(addition)
        }
        if let expectedChecksum, next.checksum() != expectedChecksum {
            throw HashPrefixStoreError.checksumMismatch
        }
        self = next
    }

    /// Discards everything (a FULL_UPDATE response replaces the list).
    public mutating func removeAll() {
        classes = [:]
    }

    private mutating func remove(indices: [Int]) throws {
        guard !indices.isEmpty else { return }
        for (previous, current) in zip(indices, indices.dropFirst()) where current <= previous {
            throw HashPrefixStoreError.unsortedRemovals
        }
        let total = count
        if let bad = indices.first(where: { $0 < 0 || $0 >= total }) {
            throw HashPrefixStoreError.removalIndexOutOfRange(bad)
        }

        // Which (size, position) does each global index refer to?
        var removed: [Int: Set<Int>] = [:]
        if classes.count == 1, let size = classes.keys.first {
            removed[size] = Set(indices)               // global index == position
        } else {
            let wanted = Set(indices)
            var globalIndex = 0
            forEachInMergedOrder { size, position in
                if wanted.contains(globalIndex) { removed[size, default: []].insert(position) }
                globalIndex += 1
            }
        }

        for (size, positions) in removed {
            guard let flat = classes[size] else { continue }
            var kept: [UInt8] = []
            kept.reserveCapacity(flat.count - positions.count * size)
            for position in 0..<(flat.count / size) where !positions.contains(position) {
                kept.append(contentsOf: flat[(position * size)..<((position + 1) * size)])
            }
            classes[size] = kept
        }
        classes = classes.filter { !$0.value.isEmpty }
    }

    private mutating func add(_ addition: Addition) throws {
        let size = addition.prefixSize
        guard (4...32).contains(size) else { throw HashPrefixStoreError.invalidPrefixSize(size) }
        guard addition.rawHashes.count % size == 0 else { throw HashPrefixStoreError.malformedRawHashes }
        guard !addition.rawHashes.isEmpty else { return }
        guard Self.isSorted(addition.rawHashes, size: size) else { throw HashPrefixStoreError.unsortedAdditions }

        if let existing = classes[size], !existing.isEmpty {
            classes[size] = Self.merge(existing, addition.rawHashes, size: size)
        } else {
            classes[size] = addition.rawHashes
        }
    }

    // MARK: - Checksum

    /// SHA-256 over every prefix in global lexicographic order — the value
    /// the server sends as `checksum.sha256`.
    public func checksum() -> Data {
        var hasher = SHA256()
        if classes.count <= 1 {
            if let flat = classes.values.first {
                flat.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
        } else {
            forEachInMergedOrder { size, position in
                classes[size]!.withUnsafeBytes { buffer in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[(position * size)..<((position + 1) * size)]))
                }
            }
        }
        return Data(hasher.finalize())
    }

    // MARK: - Persistence

    private static let magic: [UInt8] = Array("HBSB1".utf8)

    /// Layout: magic, class count (1 byte), then per class: prefix size (1 byte),
    /// entry count (4 bytes, little endian), raw bytes.
    public func serialized() -> Data {
        var out = Data(Self.magic)
        out.append(UInt8(classes.count))
        for size in classes.keys.sorted() {
            let flat = classes[size]!
            out.append(UInt8(size))
            var entries = UInt32(flat.count / size).littleEndian
            withUnsafeBytes(of: &entries) { out.append(contentsOf: $0) }
            out.append(contentsOf: flat)
        }
        return out
    }

    /// Returns `nil` for anything that isn't exactly what `serialized()` wrote,
    /// including lists that aren't sorted — a corrupted file must never be
    /// trusted as a (silently wrong) blocklist.
    public init?(serialized data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.magic.count + 1, Array(bytes.prefix(Self.magic.count)) == Self.magic else { return nil }
        var cursor = Self.magic.count
        let classCount = Int(bytes[cursor]); cursor += 1

        var parsed: [Int: [UInt8]] = [:]
        for _ in 0..<classCount {
            guard cursor + 5 <= bytes.count else { return nil }
            let size = Int(bytes[cursor]); cursor += 1
            guard (4...32).contains(size), parsed[size] == nil else { return nil }
            let entries = bytes[cursor..<(cursor + 4)].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            cursor += 4
            let length = entries * size
            guard cursor + length <= bytes.count else { return nil }
            let flat = Array(bytes[cursor..<(cursor + length)])
            cursor += length
            guard Self.isSorted(flat, size: size) else { return nil }
            parsed[size] = flat
        }
        guard cursor == bytes.count else { return nil }
        classes = parsed
    }

    // MARK: - Flat-buffer primitives

    private static func compare(_ a: [UInt8], _ aOffset: Int, _ aLength: Int,
                                _ b: [UInt8], _ bOffset: Int, _ bLength: Int) -> Int {
        let common = min(aLength, bLength)
        for i in 0..<common {
            let x = a[aOffset + i], y = b[bOffset + i]
            if x != y { return x < y ? -1 : 1 }
        }
        return aLength == bLength ? 0 : (aLength < bLength ? -1 : 1)
    }

    private static func contains(_ needle: [UInt8], size: Int, in flat: [UInt8]) -> Bool {
        var low = 0, high = flat.count / size
        while low < high {
            let mid = (low + high) / 2
            let order = compare(flat, mid * size, size, needle, 0, size)
            if order == 0 { return true }
            if order < 0 { low = mid + 1 } else { high = mid }
        }
        return false
    }

    private static func isSorted(_ flat: [UInt8], size: Int) -> Bool {
        let entries = flat.count / size
        guard entries > 1 else { return true }
        for i in 1..<entries where compare(flat, (i - 1) * size, size, flat, i * size, size) > 0 {
            return false
        }
        return true
    }

    private static func merge(_ a: [UInt8], _ b: [UInt8], size: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if compare(a, i, size, b, j, size) <= 0 {
                out.append(contentsOf: a[i..<(i + size)]); i += size
            } else {
                out.append(contentsOf: b[j..<(j + size)]); j += size
            }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }

    /// Visits every stored prefix in global lexicographic order.
    private func forEachInMergedOrder(_ visit: (_ size: Int, _ position: Int) -> Void) {
        let sizes = classes.keys.sorted()
        var positions = Array(repeating: 0, count: sizes.count)
        let totals = sizes.map { classes[$0]!.count / $0 }

        while true {
            var best: Int?
            for index in sizes.indices where positions[index] < totals[index] {
                guard let current = best else { best = index; continue }
                let order = Self.compare(
                    classes[sizes[index]]!, positions[index] * sizes[index], sizes[index],
                    classes[sizes[current]]!, positions[current] * sizes[current], sizes[current]
                )
                if order < 0 { best = index }
            }
            guard let chosen = best else { return }
            visit(sizes[chosen], positions[chosen])
            positions[chosen] += 1
        }
    }
}
