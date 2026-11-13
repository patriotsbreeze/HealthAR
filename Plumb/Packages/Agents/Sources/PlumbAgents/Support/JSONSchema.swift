import Foundation

/// Builders for the small part of JSON Schema the agents send to constrain a model's answer.
public enum JSONSchema {
    /// An object whose listed properties are all described and whose `required` ones must appear.
    public static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
        ]
    }

    /// An array of `items`, optionally bounded in length.
    public static func array(of items: JSONValue, minItems: Int? = nil, maxItems: Int? = nil) -> JSONValue {
        var members: [String: JSONValue] = ["type": "array", "items": items]
        if let minItems { members["minItems"] = .number(Double(minItems)) }
        if let maxItems { members["maxItems"] = .number(Double(maxItems)) }
        return .object(members)
    }

    /// A string, with a note telling the model what belongs in it.
    public static func string(description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    /// An integer that must be one of the listed values.
    public static func integer(oneOf values: [Int]) -> JSONValue {
        ["type": "integer", "enum": .array(values.map { .number(Double($0)) })]
    }
}
