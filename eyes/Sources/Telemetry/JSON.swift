import Foundation

/// A JSON value: what a record's fields are made of.
public enum JSON: Sendable, Equatable, Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case array([JSON])
    case object([String: JSON])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// One line of JSON, keys sorted.
    public var line: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self) + Data("\n".utf8)
        }
    }
}
