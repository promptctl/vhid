import Input
import MCP
import Pointing

/// One argument a tool takes: its name, what it is in words, and how its JSON becomes the
/// value a verb takes.
///
/// [LAW:one-source-of-truth] The tool's input schema, the refusal of an argument it does
/// not take, and the reading of the ones it does are all made from these values, so the
/// schema a client is shown and the arguments the server reads cannot disagree.
///
/// [LAW:parse-dont-validate] This is the JSON crossing, and it reads `MCP.Value` directly
/// rather than re-decoding it through `JSONDecoder`: a decode of `Int` from `1.5` reports
/// "The given data was not valid JSON", which is true of nothing a caller sent. Here each
/// refusal says which argument it was, what it was, and what it has to be.
struct Parameter<Taken: Sendable>: Sendable {
    let name: String
    /// What the argument is, said once and used twice: in the schema's description, and
    /// after "and it is" in a refusal.
    let expected: String
    /// The JSON Schema type this argument takes, for the client to read.
    let schema: [String: Value]
    /// The value when the argument is left out, and nil for one that must be given.
    let absent: Taken?
    /// The value this JSON is, or nil when it is not one. The rule it applies is the
    /// vocabulary's own, never restated here. [LAW:single-enforcer]
    let read: @Sendable (Value) -> Taken?
}

/// A parameter with its type forgotten, which is what a tool's list of them is made of.
protocol DeclaredParameter: Sendable {
    var name: String { get }
    /// This parameter's entry under the schema's `properties`.
    var property: Value { get }
    var required: Bool { get }
}

extension Parameter: DeclaredParameter {
    var property: Value { .object(schema.merging(["description": .string(expected)]) { _, said in said }) }
    var required: Bool { absent == nil }
}

extension Parameter {
    /// This parameter, taking `value` when it is left out.
    func absent(_ value: Taken) -> Self { Self(name: name, expected: expected, schema: schema, absent: value, read: read) }
}

extension Parameter where Taken == Double {
    static func number(_ name: String, _ expected: String) -> Self {
        Self(name: name, expected: expected, schema: ["type": "number"], absent: nil) { $0.number }
    }
}

extension Parameter where Taken == Int {
    static func whole(_ name: String, _ expected: String) -> Self {
        Self(name: name, expected: expected, schema: ["type": "integer"], absent: nil) { $0.whole }
    }
}

extension Parameter where Taken == String {
    static func text(_ name: String, _ expected: String) -> Self {
        Self(name: name, expected: expected, schema: ["type": "string"], absent: nil) { $0.stringValue }
    }
}

extension Parameter where Taken == [String] {
    static func texts(_ name: String, _ expected: String) -> Self {
        Self(name: name, expected: expected, schema: ["type": "array", "items": ["type": "string"], "minItems": 1], absent: nil) {
            guard let items = $0.arrayValue, !items.isEmpty else { return nil }
            let strings = items.compactMap(\.stringValue)
            return strings.count == items.count ? strings : nil
        }
    }
}

extension Parameter where Taken == ScreenPoint {
    /// A place as an object of its own, `{"x": …, "y": …}`, for a tool that takes two.
    static func place(_ name: String, _ expected: String) -> Self {
        Self(name: name, expected: expected + ": {\"x\": …, \"y\": …} in screen points from the top left of the main display",
             schema: ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                      "required": ["x", "y"], "additionalProperties": false],
             absent: nil) {
            guard let object = $0.objectValue, Set(object.keys) == ["x", "y"],
                  let x = object["x"]?.number, let y = object["y"]?.number else { return nil }
            return ScreenPoint(x: x, y: y)
        }
    }
}

extension Parameter where Taken == Button {
    /// A string is read by `Button.init?(_:)`, the rule the command line's `--button` reads
    /// by too, so the two refuse the same spellings. A JSON integer is the number spelled
    /// the way JSON spells a number. [LAW:single-enforcer]
    static func button(_ name: String) -> Self {
        Self(name: name, expected: "which button: left, right, middle, or a number from 1 to 32",
             schema: ["type": ["string", "integer"]], absent: nil) {
            switch $0 {
            case .string(let spelled): Button(spelled)
            case .int(let number): UInt8(exactly: number).flatMap(Button.init(rawValue:))
            default: nil
            }
        }
    }
}

extension Parameter where Taken == Clicks {
    static func clicks(_ name: String) -> Self {
        Self(name: name, expected: "how many presses without moving between them, at least 1",
             schema: ["type": "integer", "minimum": 1], absent: nil) { $0.whole.flatMap(Clicks.init(rawValue:)) }
    }
}

private extension Value {
    /// A JSON number, whichever of the two cases the SDK read it into.
    var number: Double? {
        switch self {
        case .int(let whole): Double(whole)
        case .double(let number): number
        default: nil
        }
    }

    /// This value as the caller wrote it, near enough: `"left"` quoted, `null` spelled
    /// out, where `description` prints a string bare and null as nothing at all.
    var json: String {
        switch self {
        case .null: "null"
        case .string(let text): text.debugDescription
        case .array(let items): "[" + items.map(\.json).joined(separator: ", ") + "]"
        case .object(let fields): "{" + fields.sorted { $0.key < $1.key }.map { "\($0.key.debugDescription): \($0.value.json)" }.joined(separator: ", ") + "}"
        default: description
        }
    }

    /// A JSON number with nothing after the point: `3` and `3.0` are one number.
    var whole: Int? {
        switch self {
        case .int(let whole): whole
        case .double(let number): Int(exactly: number)
        default: nil
        }
    }
}

/// The arguments one call carries, read one parameter at a time.
///
/// Made only by `init(_:for:)`, which refuses an argument the tool does not take: a
/// misspelt `times` for `count` would otherwise click once where three were asked for,
/// and say it had. [LAW:no-silent-failure]
struct Arguments {
    private let given: [String: Value]

    init(_ given: [String: Value], for parameters: [any DeclaredParameter]) throws(ArgumentRefused) {
        let taken = parameters.map(\.name)
        if let unknown = given.keys.sorted().first(where: { !taken.contains($0) }) {
            throw ArgumentRefused(
                "\(unknown) is not an argument this tool takes"
                + (taken.isEmpty ? ", and it takes none" : ": it takes \(taken.joined(separator: ", "))"))
        }
        self.given = given
    }

    subscript<Taken>(_ parameter: Parameter<Taken>) -> Taken {
        get throws(ArgumentRefused) {
            guard let value = given[parameter.name] else {
                guard let absent = parameter.absent else {
                    throw ArgumentRefused("\(parameter.name) is missing, and it is \(parameter.expected)")
                }
                return absent
            }
            // [LAW:no-silent-failure] The SDK reads any string shaped like a `data:` URL
            // into the bytes it encodes, and what it hands over cannot be turned back into
            // the string that was sent: `data:,hi` comes back `data:text/plain;base64,aGk=`.
            // Typing that would type something nobody asked for, so it is refused, with the
            // way round it.
            if case .data = value {
                throw ArgumentRefused(
                    "\(parameter.name) begins data: and reads as a data URL, which the MCP library under this server "
                    + "turns into bytes before vhid sees it, so the string sent cannot be recovered exactly. "
                    + "Send it in two calls, split inside \"data:\"")
            }
            guard let taken = parameter.read(value) else {
                throw ArgumentRefused("\(parameter.name) is \(value.json), and it is \(parameter.expected)")
            }
            return taken
        }
    }
}

/// An argument that is not what its tool takes, named.
struct ArgumentRefused: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
