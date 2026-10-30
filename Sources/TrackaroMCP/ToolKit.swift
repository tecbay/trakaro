import Foundation
import MCP
import TrackaroCore

/// Who is calling and what they can touch, handed to every tool.
struct ToolContext: Sendable {
    let store: TrackaroStore
    /// The person who owns this Mac. "me" in tool arguments.
    let user: Member
    /// The connected agent. "self" in tool arguments, and the author of every write.
    let agent: Member
}

struct ToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: Value
    let readOnly: Bool
    let destructive: Bool
    let run: @Sendable (ToolContext, Arguments) throws -> Value

    init(
        name: String, title: String, description: String, inputSchema: Value,
        readOnly: Bool, destructive: Bool = false,
        run: @escaping @Sendable (ToolContext, Arguments) throws -> Value
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.run = run
    }

    var tool: Tool {
        Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            annotations: .init(
                title: title,
                readOnlyHint: readOnly,
                destructiveHint: readOnly ? nil : destructive,
                idempotentHint: readOnly ? true : nil,
                openWorldHint: false
            )
        )
    }

    var argumentNames: Set<String> {
        Set(inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
    }

    var requiredArguments: [String] {
        inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Runs the tool, turning every failure into an `isError` result the agent can read and act on.
    func call(_ context: ToolContext, _ raw: [String: Value]?) -> CallTool.Result {
        do {
            let arguments = Arguments(raw ?? [:])
            let unknown = Set(arguments.values.keys).subtracting(argumentNames).sorted()
            if !unknown.isEmpty {
                throw TrackaroError.invalid(
                    field: unknown.joined(separator: ", "),
                    message: "Unknown argument. \(name) accepts: \(argumentNames.sorted().joined(separator: ", "))."
                )
            }
            for key in requiredArguments where arguments.values[key] == nil || arguments.values[key] == .null {
                throw TrackaroError.invalid(field: key, message: "Required.")
            }
            return CallTool.Result(content: [Output.text(Output.render(try run(context, arguments)))])
        } catch let error as TrackaroError {
            return CallTool.Result(content: [Output.text("Error: \(error.description)")], isError: true)
        } catch {
            return CallTool.Result(content: [Output.text("Error: \(error)")], isError: true)
        }
    }
}

// MARK: - Arguments

/// Typed access to a tool's JSON arguments. A wrong type is an `invalid` error naming the argument.
struct Arguments: Sendable {
    let values: [String: Value]

    init(_ values: [String: Value]) {
        self.values = values
    }

    func has(_ key: String) -> Bool { values[key] != nil }

    /// True when the caller passed an explicit `null`, which means "clear this field".
    func isNull(_ key: String) -> Bool { values[key] == .null }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let text = value.stringValue else { throw mistyped(key, "a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The raw string, untrimmed and possibly empty. For bodies where whitespace matters.
    func text(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let text = value.stringValue else { throw mistyped(key, "a string") }
        return text
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw TrackaroError.invalid(field: key, message: "Required.") }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        if let integer = value.intValue { return integer }
        if let double = value.doubleValue, double.rounded() == double, abs(double) < 1e12 { return Int(double) }
        if let text = value.stringValue, let integer = Int(text) { return integer }
        throw mistyped(key, "a whole number")
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        if let flag = value.boolValue { return flag }
        if let text = value.stringValue?.lowercased(), text == "true" || text == "false" { return text == "true" }
        throw mistyped(key, "true or false")
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key], value != .null else { return nil }
        if let single = value.stringValue { return [single] }
        guard let array = value.arrayValue else { throw mistyped(key, "an array of strings") }
        return try array.map {
            guard let text = $0.stringValue else { throw mistyped(key, "an array of strings") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func objects(_ key: String) throws -> [Arguments]? {
        guard let value = values[key], value != .null else { return nil }
        guard let array = value.arrayValue else { throw mistyped(key, "an array of objects") }
        return try array.map {
            guard let object = $0.objectValue else { throw mistyped(key, "an array of objects") }
            return Arguments(object)
        }
    }

    func date(_ key: String) throws -> CalendarDate? {
        guard let text = try string(key) else { return nil }
        guard let date = CalendarDate(text) else { throw mistyped(key, "a date as YYYY-MM-DD") }
        return date
    }

    func priority(_ key: String) throws -> Priority? {
        guard let text = try string(key) else { return nil }
        guard let priority = Priority(name: text) else {
            throw TrackaroError.invalid(field: key, message: "Use one of: \(Priority.allCases.map(\.name).joined(separator: ", ")).")
        }
        return priority
    }

    private func mistyped(_ key: String, _ expected: String) -> TrackaroError {
        TrackaroError.invalid(field: key, message: "Expected \(expected).")
    }
}

// MARK: - JSON Schema

/// Builders for the small subset of JSON Schema the tools use.
enum JSONSchema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, oneOf options: [String]? = nil, nullable: Bool = false) -> Value {
        var schema: [String: Value] = ["type": type("string", nullable: nullable), "description": .string(description)]
        if let options { schema["enum"] = .array(options.map { .string($0) } + (nullable ? [.null] : [])) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil, nullable: Bool = false) -> Value {
        var schema: [String: Value] = ["type": type("integer", nullable: nullable), "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func array(_ description: String, of items: Value, minItems: Int? = nil, maxItems: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "array", "description": .string(description), "items": items]
        if let minItems { schema["minItems"] = .int(minItems) }
        if let maxItems { schema["maxItems"] = .int(maxItems) }
        return .object(schema)
    }

    private static func type(_ name: String, nullable: Bool) -> Value {
        nullable ? .array([.string(name), "null"]) : .string(name)
    }
}

// MARK: - Output

enum Output {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Compact JSON. Tool results go straight into an agent's context, so whitespace is wasted tokens.
    static func render(_ value: Value) -> String {
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func text(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    static func timestamp(_ date: Date?) -> Value {
        guard let date else { return .null }
        return .string(date.formatted(.iso8601))
    }
}

/// Builds a JSON object while skipping absent values, so results only carry fields that have something to say.
struct ObjectBuilder {
    private(set) var fields: [String: Value] = [:]

    mutating func set(_ key: String, _ value: Value?) {
        guard let value, value != .null else { return }
        if case let .array(items) = value, items.isEmpty { return }
        fields[key] = value
    }

    mutating func set(_ key: String, _ text: String?) {
        set(key, text.map(Value.string))
    }

    mutating func set(_ key: String, _ number: Int?) {
        set(key, number.map(Value.int))
    }

    mutating func set(_ key: String, _ flag: Bool?) {
        set(key, flag.map(Value.bool))
    }

    /// Issue lists always carry `count` and `issues`, even when empty, so "no results" is unambiguous.
    mutating func setIssues(_ issues: [Value]) {
        fields["count"] = .int(issues.count)
        fields["issues"] = .array(issues)
    }

    var value: Value { .object(fields) }
}
