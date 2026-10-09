import Foundation

/// Loosely-typed JSON, for the parts of harness protocols we pass through
/// rather than model (tool inputs, hook payloads, MCP messages).
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { a[index] } else { nil }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var int: Int? { number.map { Int($0) } }
    public var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Keep integers integral on the wire; some peers reject `1.0` for ids.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON {
    public init(_ value: some Encodable) throws {
        self = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// One-line JSON, for writing NDJSON frames.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }

    public var compact: String {
        String(decoding: line().dropLast(), as: UTF8.self)
    }

    public static func parse(_ data: some DataProtocol) -> JSON? {
        try? JSONDecoder().decode(JSON.self, from: Data(data))
    }

    public static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    /// This object with `other`'s keys set on top.
    public func merging(_ other: [String: JSON]) -> JSON {
        .object((object ?? [:]).merging(other) { _, new in new })
    }
}
