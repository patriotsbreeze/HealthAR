import Foundation

/// A JSON document as a plain value, so requests and schemas are built from cases instead of
/// untyped dictionaries.
public enum JSONValue: Sendable, Equatable {
    /// JSON `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// Any JSON number. Whole numbers are written without a decimal point.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Decodes whichever kind of JSON value is next.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Encodes the value as the matching kind of JSON.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    /// Reads a JSON document.
    init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Writes the value as JSON with keys in a fixed order, so the same value always gives the same bytes.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The member of an object with this key, or nil when this is not an object or has no such key.
    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    /// The text of a string value.
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The number of a numeric value.
    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The flag of a boolean value.
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The items of an array value.
    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    /// Lets a string literal stand for a JSON string.
    public init(stringLiteral value: String) { self = .string(value) }
    /// Lets `true` and `false` stand for JSON booleans.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Lets a whole-number literal stand for a JSON number.
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    /// Lets an array literal stand for a JSON array.
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// Lets a dictionary literal stand for a JSON object. A repeated key keeps its last value.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
