import Foundation
import GRDB

/// A date without a time or zone, stored as `YYYY-MM-DD`. Used for due, start and target dates.
public struct CalendarDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        guard (1...9999).contains(year), components.isValidDate(in: calendar) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = CalendarDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected YYYY-MM-DD, got \(text)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension CalendarDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CalendarDate? {
        String.fromDatabaseValue(dbValue).flatMap(CalendarDate.init)
    }
}
