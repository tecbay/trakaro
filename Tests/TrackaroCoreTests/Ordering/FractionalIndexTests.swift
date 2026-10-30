import Testing
@testable import TrackaroCore

@Suite("Fractional index")
struct FractionalIndexTests {
    @Test("Known keys between bounds", arguments: [
        (nil, nil, "a0"),
        (nil, "a0", "Zz"),
        (nil, "Zz", "Zy"),
        ("a0", nil, "a1"),
        ("a1", nil, "a2"),
        ("a0", "a1", "a0V"),
        ("a1", "a2", "a1V"),
        ("a0V", "a1", "a0l"),
        ("Zz", "a0", "ZzV"),
        ("Zz", "a1", "a0"),
        (nil, "Y00", "Xzzz"),
        ("bzz", nil, "c000"),
        ("a0", "a0V", "a0G"),
        ("a0", "a0G", "a08"),
        ("b125", "b129", "b127"),
        ("a0", "a1V", "a1"),
        ("Zz", "a01", "a0"),
        (nil, "a0V", "a0"),
        (nil, "b999", "b99"),
        ("zzzzzzzzzzzzzzzzzzzzzzzzzzy", nil, "zzzzzzzzzzzzzzzzzzzzzzzzzzz"),
        ("zzzzzzzzzzzzzzzzzzzzzzzzzzz", nil, "zzzzzzzzzzzzzzzzzzzzzzzzzzzV"),
        (nil, "A000000000000000000000000001", "A000000000000000000000000000V"),
    ] as [(String?, String?, String)])
    func knownKeys(lower: String?, upper: String?, expected: String) throws {
        #expect(try FractionalIndex.key(between: lower, and: upper) == expected)
    }

    @Test("Rejects invalid or out of order bounds", arguments: [
        (nil, "A00000000000000000000000000"),
        ("a00", nil),
        ("a00", "a1"),
        ("0", "1"),
        ("a1", "a0"),
        ("a1", "a1"),
    ] as [(String?, String?)])
    func rejectsInvalid(lower: String?, upper: String?) {
        #expect(throws: FractionalIndex.InvalidKey.self) {
            try FractionalIndex.key(between: lower, and: upper)
        }
    }

    @Test("Random insertions keep a strictly ordered, valid sequence")
    func randomInsertionsStayOrdered() throws {
        var generator = SeededGenerator(seed: 42)
        var keys: [String] = [try FractionalIndex.key(between: nil, and: nil)]
        for _ in 0..<3000 {
            let slot = Int.random(in: 0...keys.count, using: &generator)
            let lower = slot == 0 ? nil : keys[slot - 1]
            let upper = slot == keys.count ? nil : keys[slot]
            let key = try FractionalIndex.key(between: lower, and: upper)
            if let lower { #expect(lower < key) }
            if let upper { #expect(key < upper) }
            #expect(FractionalIndex.isValid(key))
            keys.insert(key, at: slot)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test("Repeated prepends and appends stay short and ordered")
    func repeatedEnds() throws {
        var first = try FractionalIndex.key(between: nil, and: nil)
        var last = first
        for _ in 0..<1000 {
            let earlier = try FractionalIndex.key(between: nil, and: first)
            #expect(earlier < first)
            first = earlier
            let later = try FractionalIndex.key(between: last, and: nil)
            #expect(last < later)
            last = later
        }
        #expect(first.count <= 4)
        #expect(last.count <= 4)
    }

    @Test("Inserting repeatedly at the same spot grows keys slowly")
    func repeatedMidpoint() throws {
        let lower = try FractionalIndex.key(between: nil, and: nil)
        var upper = try FractionalIndex.key(between: lower, and: nil)
        for _ in 0..<200 {
            let middle = try FractionalIndex.key(between: lower, and: upper)
            #expect(lower < middle && middle < upper)
            upper = middle
        }
        #expect(upper.count < 50)
    }
}

/// SplitMix64, so the property test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
