import Testing
import Foundation
import CryptoKit
@testable import BrowserCore

@Suite struct HashPrefixStoreTests {
    private func add(_ size: Int, _ entries: [[UInt8]]) -> HashPrefixStore.Addition {
        .init(prefixSize: size, rawHashes: entries.flatMap { $0 })
    }

    private func sha(_ bytes: [UInt8]) -> Data { Data(SHA256.hash(data: Data(bytes))) }

    @Test func additionAndLookup() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [add(4, [[1, 2, 3, 4], [5, 6, 7, 8]])])
        #expect(store.count == 2)
        #expect(store.contains(hash: Data([1, 2, 3, 4, 99, 99])))
        #expect(!store.contains(hash: Data([1, 2, 3, 5, 99])))
    }

    @Test func additionsMergeIntoSortedOrder() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [add(4, [[1, 0, 0, 0], [9, 0, 0, 0]])])
        try store.apply(removalIndices: [], additions: [add(4, [[5, 0, 0, 0]])])
        #expect(store.checksum() == sha([1, 0, 0, 0, 5, 0, 0, 0, 9, 0, 0, 0]))
    }

    @Test func removalByIndex() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [add(4, [[1, 0, 0, 0], [2, 0, 0, 0], [3, 0, 0, 0]])])
        try store.apply(removalIndices: [1], additions: [])
        #expect(store.count == 2)
        #expect(!store.contains(hash: Data([2, 0, 0, 0])))
        #expect(store.contains(hash: Data([3, 0, 0, 0])))
    }

    @Test func mixedSizesUseGlobalLexicographicOrder() throws {
        var store = HashPrefixStore()
        // Global order: [1,0,0,0] < [1,0,0,0,5] < [2,0,0,0]
        try store.apply(removalIndices: [], additions: [
            add(4, [[1, 0, 0, 0], [2, 0, 0, 0]]),
            add(5, [[1, 0, 0, 0, 5]]),
        ])
        #expect(store.checksum() == sha([1, 0, 0, 0, 1, 0, 0, 0, 5, 2, 0, 0, 0]))
        try store.apply(removalIndices: [1], additions: [])   // removes the 5-byte one
        #expect(store.count == 2)
        #expect(store.checksum() == sha([1, 0, 0, 0, 2, 0, 0, 0]))
    }

    @Test func checksumMismatchLeavesStoreUntouched() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [add(4, [[1, 0, 0, 0]])])
        let before = store
        #expect(throws: HashPrefixStoreError.checksumMismatch) {
            try store.apply(removalIndices: [], additions: [add(4, [[2, 0, 0, 0]])], expectedChecksum: Data(repeating: 0, count: 32))
        }
        #expect(store == before)
    }

    @Test func correctChecksumAccepted() throws {
        var store = HashPrefixStore()
        try store.apply(
            removalIndices: [],
            additions: [add(4, [[1, 0, 0, 0], [2, 0, 0, 0]])],
            expectedChecksum: sha([1, 0, 0, 0, 2, 0, 0, 0])
        )
        #expect(store.count == 2)
    }

    @Test func invalidInputsRejected() throws {
        var store = HashPrefixStore()
        #expect(throws: HashPrefixStoreError.invalidPrefixSize(3)) {
            try store.apply(removalIndices: [], additions: [.init(prefixSize: 3, rawHashes: [1, 2, 3])])
        }
        #expect(throws: HashPrefixStoreError.malformedRawHashes) {
            try store.apply(removalIndices: [], additions: [.init(prefixSize: 4, rawHashes: [1, 2, 3, 4, 5])])
        }
        #expect(throws: HashPrefixStoreError.unsortedAdditions) {
            try store.apply(removalIndices: [], additions: [add(4, [[2, 0, 0, 0], [1, 0, 0, 0]])])
        }
        #expect(throws: HashPrefixStoreError.removalIndexOutOfRange(0)) {
            try store.apply(removalIndices: [0], additions: [])
        }
        try store.apply(removalIndices: [], additions: [add(4, [[1, 0, 0, 0], [2, 0, 0, 0]])])
        #expect(throws: HashPrefixStoreError.unsortedRemovals) {
            try store.apply(removalIndices: [1, 0], additions: [])
        }
        #expect(store.count == 2)
    }

    @Test func serializationRoundTrip() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [
            add(4, [[1, 0, 0, 0], [2, 0, 0, 0]]),
            add(6, [[3, 0, 0, 0, 0, 1]]),
        ])
        let restored = try #require(HashPrefixStore(serialized: store.serialized()))
        #expect(restored == store)
        #expect(restored.checksum() == store.checksum())
    }

    @Test func corruptedDataIsRejected() throws {
        var store = HashPrefixStore()
        try store.apply(removalIndices: [], additions: [add(4, [[1, 0, 0, 0], [2, 0, 0, 0]])])
        var data = store.serialized()
        #expect(HashPrefixStore(serialized: data.dropLast()) == nil)
        data.append(0)
        #expect(HashPrefixStore(serialized: data) == nil)
        #expect(HashPrefixStore(serialized: Data("nope".utf8)) == nil)
    }
}
