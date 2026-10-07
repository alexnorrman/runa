import Foundation

/// A JSON value with ordered objects, plus a deterministic writer.
///
/// Foundation's encoders differ between macOS and Linux and cannot reproduce Xcode's String
/// Catalog layout, so exports use this writer for byte-stable output everywhere.
public indirect enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let s): hasher.combine(s)
        case .number(let n): hasher.combine(n)
        case .bool(let b): hasher.combine(b)
        case .null: hasher.combine(0)
        case .array(let a): hasher.combine(a)
        case .object(let o): for (k, v) in o { hasher.combine(k); hasher.combine(v) }
        }
    }

    public enum Style: Sendable {
        /// `"key" : value`, empty objects as `{\n\n}`, no trailing newline. Matches Xcode's String Catalogs.
        case xcode
        /// `"key": value`, `{}` for empty objects, trailing newline. Matches Prettier and most web tooling.
        case standard
    }

    public func serialized(style: Style) -> String {
        var output = ""
        write(into: &output, indent: 0, style: style)
        if style == .standard { output += "\n" }
        return output
    }

    private func write(into output: inout String, indent: Int, style: Style) {
        let pad = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let string): output += Self.quote(string)
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { output += String(Int64(number)) } else { output += String(number) }
        case .bool(let bool): output += bool ? "true" : "false"
        case .null: output += "null"
        case .array(let items):
            if items.isEmpty {
                output += "[]"
                return
            }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += innerPad
                item.write(into: &output, indent: indent + 1, style: style)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += pad + "]"
        case .object(let members):
            if members.isEmpty {
                output += style == .xcode ? "{\n\n\(pad)}" : "{}"
                return
            }
            output += "{\n"
            let separator = style == .xcode ? " : " : ": "
            for (index, member) in members.enumerated() {
                output += innerPad + Self.quote(member.0) + separator
                member.1.write(into: &output, indent: indent + 1, style: style)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += pad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    /// Sorted by Unicode code point, which is how Xcode orders String Catalog keys.
    public static func sortedObject(_ members: [String: JSONValue]) -> JSONValue {
        .object(members.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }.map { ($0.key, $0.value) })
    }

    // MARK: Parsing

    /// Parses JSON, keeping object members in file order.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectMembers: [(String, JSONValue)]? {
        if case .object(let members) = self { return members }
        return nil
    }
}

public struct JSONParseError: Error, LocalizedError, Sendable {
    public var offset: Int
    public var message: String
    public var errorDescription: String? { "Invalid JSON at byte \(offset): \(message)" }
}

struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected content after the JSON value") }
        return value
    }

    func error(_ message: String) -> JSONParseError { JSONParseError(offset: index, message: message) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count, Array(bytes[index..<index + literalBytes.count]) == literalBytes
        else { throw error("Expected \(literal)") }
        index += literalBytes.count
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1
        var members: [(String, JSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a member name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            members.append((key, try parseValue()))
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            throw error("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalarValue), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                        bytes[index + 1] == UInt8(ascii: "u")
                    {
                        index += 2
                        let low = try parseHex4()
                        scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw error("Invalid escape")
                }
            } else {
                buffer.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("Invalid unicode escape") }
        index += 4
        return value
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        guard index > start, let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw error("Invalid value")
        }
        return .number(number)
    }
}
