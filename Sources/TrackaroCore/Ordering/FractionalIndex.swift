import Foundation

/// Base-62 fractional index keys, compatible with the widely used `fractional-indexing` scheme.
///
/// A key is an integer part (head character encodes its length) followed by a fractional part with no
/// trailing zero. Keys compare correctly as plain byte strings, which is SQLite's default collation, so a
/// column of issues sorts with `ORDER BY sortKey` and a move rewrites exactly one row.
public enum FractionalIndex {
    static let digits: [UInt8] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let base = digits.count
    static let zero = UInt8(ascii: "0")
    static let smallestInteger: [UInt8] = [UInt8(ascii: "A")] + Array(repeating: zero, count: 26)

    private static let digitValues: [Int] = {
        var table = [Int](repeating: -1, count: 256)
        for (value, digit) in digits.enumerated() { table[Int(digit)] = value }
        return table
    }()

    public struct InvalidKey: Error, Equatable, Sendable {
        public let reason: String
    }

    /// A key strictly between `lower` and `upper`. Either bound may be nil for "no neighbour on that side".
    public static func key(between lower: String?, and upper: String?) throws -> String {
        let a = lower.map { Array($0.utf8) }
        let b = upper.map { Array($0.utf8) }
        if let a { try validate(a) }
        if let b { try validate(b) }
        let result: [UInt8]
        switch (a, b) {
        case (nil, nil):
            result = Array("a0".utf8)
        case let (nil, b?):
            let integer = try integerPart(b)
            let fraction = Array(b[integer.count...])
            if integer == smallestInteger {
                result = integer + (try midpoint([], fraction))
            } else if integer.count < b.count {
                result = integer
            } else {
                guard let decremented = decrement(integer) else {
                    throw InvalidKey(reason: "cannot decrement any further")
                }
                result = decremented
            }
        case let (a?, nil):
            let integer = try integerPart(a)
            let fraction = Array(a[integer.count...])
            if let incremented = increment(integer) {
                result = incremented
            } else {
                result = integer + (try midpoint(fraction, nil))
            }
        case let (a?, b?):
            guard a.lexicographicallyPrecedes(b) else {
                throw InvalidKey(reason: "lower bound \(lower ?? "") is not below upper bound \(upper ?? "")")
            }
            let integerA = try integerPart(a)
            let fractionA = Array(a[integerA.count...])
            let integerB = try integerPart(b)
            let fractionB = Array(b[integerB.count...])
            if integerA == integerB {
                result = integerA + (try midpoint(fractionA, fractionB))
            } else {
                guard let incremented = increment(integerA) else {
                    throw InvalidKey(reason: "cannot increment any further")
                }
                result = incremented.lexicographicallyPrecedes(b)
                    ? incremented
                    : integerA + (try midpoint(fractionA, nil))
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func isValid(_ key: String) -> Bool {
        (try? validate(Array(key.utf8))) != nil
    }

    static func validate(_ key: [UInt8]) throws {
        guard !key.isEmpty else { throw InvalidKey(reason: "empty key") }
        guard key != smallestInteger else { throw InvalidKey(reason: "reserved key") }
        guard key.allSatisfy({ digitValues[Int($0)] >= 0 }) else { throw InvalidKey(reason: "non base-62 character") }
        let integer = try integerPart(key)
        if key.count > integer.count, key.last == zero {
            throw InvalidKey(reason: "fractional part ends in zero")
        }
    }

    static func integerLength(head: UInt8) throws -> Int {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
        default: throw InvalidKey(reason: "invalid head character")
        }
    }

    static func integerPart(_ key: [UInt8]) throws -> [UInt8] {
        guard let head = key.first else { throw InvalidKey(reason: "empty key") }
        let length = try integerLength(head: head)
        guard length <= key.count else { throw InvalidKey(reason: "integer part longer than key") }
        return Array(key[0..<length])
    }

    static func midpoint(_ a: [UInt8], _ b: [UInt8]?) throws -> [UInt8] {
        if let b {
            guard a.lexicographicallyPrecedes(b) else { throw InvalidKey(reason: "midpoint bounds out of order") }
            var shared = 0
            while shared < b.count, (shared < a.count ? a[shared] : zero) == b[shared] {
                shared += 1
            }
            if shared > 0 {
                let rest = try midpoint(Array(a.dropFirst(shared)), Array(b.dropFirst(shared)))
                return Array(b[0..<shared]) + rest
            }
        }
        let digitA = a.first.map { digitValues[Int($0)] } ?? 0
        let digitB = b.map { digitValues[Int($0[0])] } ?? base
        if digitB - digitA > 1 {
            let middle = Int((Double(digitA + digitB) * 0.5).rounded())
            return [digits[middle]]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digits[digitA]] + (try midpoint(Array(a.dropFirst()), nil))
    }

    static func increment(_ integer: [UInt8]) -> [UInt8]? {
        guard let head = integer.first else { return nil }
        var body = Array(integer.dropFirst())
        var carry = true
        var index = body.count - 1
        while carry, index >= 0 {
            let next = digitValues[Int(body[index])] + 1
            if next == base {
                body[index] = zero
            } else {
                body[index] = digits[next]
                carry = false
            }
            index -= 1
        }
        guard carry else { return [head] + body }
        if head == UInt8(ascii: "Z") { return Array("a0".utf8) }
        if head == UInt8(ascii: "z") { return nil }
        let nextHead = head + 1
        if nextHead > UInt8(ascii: "a") {
            body.append(zero)
        } else {
            body.removeLast()
        }
        return [nextHead] + body
    }

    static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        guard let head = integer.first, let largestDigit = digits.last else { return nil }
        var body = Array(integer.dropFirst())
        var borrow = true
        var index = body.count - 1
        while borrow, index >= 0 {
            let next = digitValues[Int(body[index])] - 1
            if next == -1 {
                body[index] = largestDigit
            } else {
                body[index] = digits[next]
                borrow = false
            }
            index -= 1
        }
        guard borrow else { return [head] + body }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), largestDigit] }
        if head == UInt8(ascii: "A") { return nil }
        let nextHead = head - 1
        if nextHead < UInt8(ascii: "Z") {
            body.append(largestDigit)
        } else {
            body.removeLast()
        }
        return [nextHead] + body
    }
}
