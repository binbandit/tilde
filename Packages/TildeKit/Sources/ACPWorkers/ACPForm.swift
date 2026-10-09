import Foundation
import TildeSupport
import WorkerKit

/// A form-mode `elicitation/create`: an agent asking structured questions.
/// Each field becomes one `WorkerQuestion`; the manager's single reply is
/// typed per field when tilde answers.
struct ACPForm {
    struct Field {
        var key: String
        var question: WorkerQuestion
        var schema: JSON
    }

    var message: String
    var fields: [Field]

    init(_ params: JSON) {
        message = params["message"]?.string ?? ""
        let schema = params["requestedSchema"] ?? [:]
        let properties = schema["properties"]?.object ?? [:]
        let required = schema["required"]?.array?.compactMap(\.string) ?? []
        // JSON objects lose their order here; required fields first keeps it sensible.
        let keys = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        fields = keys.map { [message] key in
            let property = properties[key] ?? [:]
            let detail = keys.count == 1
                ? property["description"]?.string
                : property["title"]?.string ?? property["description"]?.string ?? key
            return Field(
                key: key,
                question: WorkerQuestion(
                    question: [message, detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n"),
                    options: Self.choices(property).map(\.title), multiSelect: property["type"]?.string == "array"),
                schema: property)
        }
    }

    var questions: [WorkerQuestion] {
        fields.isEmpty ? [WorkerQuestion(question: message, options: [], multiSelect: false)] : fields.map(\.question)
    }

    /// The `content` to accept with: `reply` answers every field, as its type.
    func content(_ reply: String) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, Self.value(reply, for: $0.schema)) }))
    }

    private static func value(_ reply: String, for schema: JSON) -> JSON {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        switch schema["type"]?.string {
        case "boolean": return .bool(WorkerAnswer.isYes(text))
        case "integer": return Int(text).map { .number(Double($0)) } ?? .string(text)
        case "number": return Double(text).map { .number($0) } ?? .string(text)
        case "array":
            let picks = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return .array(picks.map { .string(match($0, in: choices(schema)) ?? $0) })
        default: return .string(match(text, in: choices(schema)) ?? text)
        }
    }

    /// Enum choices as (value, title): `enum`, titled `oneOf`, or a multi-select's items.
    private static func choices(_ schema: JSON) -> [(value: String, title: String)] {
        if schema["type"]?.string == "boolean" { return [("true", "Yes"), ("false", "No")] }
        let source = schema["type"]?.string == "array" ? schema["items"] ?? [:] : schema
        if let titled = (source["oneOf"] ?? source["anyOf"])?.array {
            return titled.compactMap { option in
                option["const"]?.string.map { ($0, option["title"]?.string ?? $0) }
            }
        }
        return (source["enum"]?.array ?? []).compactMap(\.string).map { ($0, $0) }
    }

    private static func match(_ text: String, in choices: [(value: String, title: String)]) -> String? {
        choices.first {
            $0.value.caseInsensitiveCompare(text) == .orderedSame || $0.title.caseInsensitiveCompare(text) == .orderedSame
        }?.value
    }
}
