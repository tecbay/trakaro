import Foundation

public enum Identifiers {
    /// A time-ordered UUID (RFC 9562 version 7), lowercased. Sorting ids sorts by creation time.
    public static func uuidV7(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xFF)
        }
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}

/// A human issue reference such as `ENG-42`.
public struct IssueKey: Hashable, Sendable, CustomStringConvertible {
    public let teamKey: String
    public let number: Int

    public init(teamKey: String, number: Int) {
        self.teamKey = teamKey.uppercased()
        self.number = number
    }

    /// Parses `ENG-42` case-insensitively. Returns nil for anything that is not an identifier.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let dash = trimmed.lastIndex(of: "-") else { return nil }
        let key = String(trimmed[..<dash])
        let digits = trimmed[trimmed.index(after: dash)...]
        guard TeamKey.isValid(key), !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit),
              let number = Int(digits), number > 0 else { return nil }
        self.init(teamKey: key, number: number)
    }

    public var description: String { "\(teamKey)-\(number)" }
}

public enum TeamKey {
    /// Two to six ASCII alphanumerics, starting with a letter.
    public static func isValid(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard (2...6).contains(scalars.count), let first = scalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return scalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
