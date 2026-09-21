import Foundation
import Pointing

/// A script of raw mouse reports at fixed times, for a harness that needs the same input
/// to reach macOS on every run: one absolute starting point, then reports at offsets from
/// a clock started once the cursor is there.
///
/// Raw and not corrected, because the point of a replay is that acceleration sees
/// identical input each time; a path the pointer's loop corrected would ask for different
/// counts on every run. The start is the one place the loop is used, before the clock.
///
/// [LAW:parse-dont-validate] A `Play` that exists is a script that can be played whole:
/// at least one report, times that never go backwards, and no button left held at the
/// end. Nothing downstream asks any of that again.
public struct Play: Hashable, Sendable {
    public let start: ScreenPoint
    public let events: [Timed]

    /// The latest a report may be due, in milliseconds: an hour, far past any measurement
    /// and far short of the nanoseconds an `Int64` holds, so a mistyped exponent is
    /// refused by name rather than trapping the conversion.
    public static let longest = 3_600_000.0

    /// One report and when it is due, as an offset from the clock's start.
    public struct Timed: Hashable, Sendable {
        public let at: Duration
        public let report: Report
    }

    /// The four acts `Pointing` performs, as data. [LAW:one-type-per-behavior]
    public enum Report: Hashable, Sendable {
        case move(Move)
        case wheel(Scroll)
        case down(Button)
        case up
    }

    /// Parses JSON Lines: `{"to":{"x":800,"y":500}}` first, then one report a line -
    /// `{"t_ms":0,"down":"left"}`, `{"t_ms":8.3,"move":{"dx":4,"dy":0}}`,
    /// `{"t_ms":16.7,"wheel":{"v":-1,"h":0}}`, `{"t_ms":1000,"up":true}`. Blank lines are
    /// skipped. A key a line does not take is refused, so a misspelt report is never
    /// played as something else. [LAW:no-silent-failure]
    public static func parse(_ text: String) throws -> Play {
        // Any newline, because "\r\n" is one Character and a split on "\n" never finds it.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            .map { (number: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
        guard let first = lines.first, let last = lines.last, lines.count > 1 else {
            throw ScriptInvalid(line: lines.first?.number ?? 1, reason: "a script is a {\"to\":{\"x\":…,\"y\":…}} line and at least one report after it")
        }
        let start = try decode(StartLine.self, first).to
        let events = try lines.dropFirst().map { try decode(ReportLine.self, $0).timed }
        for (line, (previous, next)) in zip(lines.dropFirst(2), zip(events, events.dropFirst())) where next.at < previous.at {
            throw ScriptInvalid(line: line.number, reason: "t_ms goes backwards: \(next.at) after \(previous.at)")
        }
        let held = events.reduce(into: Set<Button>()) { held, event in
            switch event.report {
            case .down(let button): held.insert(button)
            case .up: held.removeAll()
            case .move, .wheel: break
            }
        }
        guard held.isEmpty else {
            throw ScriptInvalid(line: last.number, reason: "the script ends with button \(held.sorted().map { "\($0.rawValue)" }.joined(separator: ", ")) held: end it with {\"t_ms\":…,\"up\":true}")
        }
        return Play(start: start, events: events)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: (number: Int, text: String)) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(line.text.utf8))
        } catch let refused as Refusal {
            throw ScriptInvalid(line: line.number, reason: refused.reason)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ScriptInvalid(line: line.number, reason: "\(key.stringValue.debugDescription) is missing")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context), let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ScriptInvalid(line: line.number, reason: (path.isEmpty ? "" : "\(path): ") + context.debugDescription)
        }
    }

    /// A script line that is not what a script says, or reports that cannot be played whole.
    public struct ScriptInvalid: Error, CustomStringConvertible {
        public let line: Int
        public let reason: String

        public var description: String { "line \(line) of the script: \(reason)" }
    }
}

/// What a line's own decoding refuses, before anyone knows which line it was.
private struct Refusal: Error {
    let reason: String
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A line's keys, refusing any it does not take by name.
private func container(_ decoder: Decoder, taking allowed: Set<String>) throws -> KeyedDecodingContainer<AnyKey> {
    let container = try decoder.container(keyedBy: AnyKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        throw Refusal(reason: "unknown key \(unknown.map(\.debugDescription).joined(separator: ", ")): this line takes \(allowed.sorted().joined(separator: ", "))")
    }
    return container
}

private struct StartLine: Decodable {
    let to: ScreenPoint

    /// The start's own keys are checked the way a report's are. [LAW:single-enforcer] The
    /// file's promise is that a key a line does not take is refused, and it used to stop
    /// at the outer brace: `{"to":{"x":1,"y":2,"dx":99}}` parsed, while the identical
    /// mistake one line later was refused by name. A misspelt key in a script is a report
    /// that does not do what it says, wherever in the line it sits.
    init(from decoder: Decoder) throws {
        let line = try container(decoder, taking: ["to"])
        let start = try container(line.superDecoder(forKey: AnyKey("to")), taking: ["x", "y"])
        let x = try start.decode(Double.self, forKey: AnyKey("x"))
        let y = try start.decode(Double.self, forKey: AnyKey("y"))
        guard let point = ScreenPoint(x: x, y: y) else {
            throw Refusal(reason: "to is (\(x.clean), \(y.clean)), which is not a place on the screen")
        }
        to = point
    }
}

private extension Double {
    /// This number as a script would have written it: no trailing `.0` on a whole one, so
    /// a refusal about `300` does not say `300.0` at somebody who never typed that.
    var clean: String { self == rounded(.towardZero) && abs(self) < 1e15 ? String(Int(self)) : String(self) }
}

/// `t_ms` and exactly one of the four reports.
private struct ReportLine: Decodable {
    static let reports: Set<String> = ["down", "move", "up", "wheel"]
    let timed: Play.Timed

    init(from decoder: Decoder) throws {
        let line = try container(decoder, taking: Self.reports.union(["t_ms"]))
        let named = line.allKeys.map(\.stringValue).filter(Self.reports.contains).sorted()
        guard named.count == 1, let report = named.first else {
            throw Refusal(reason: "a line carries exactly one of \(Self.reports.sorted().joined(separator: ", ")), and this one has \(named.isEmpty ? "none" : named.joined(separator: " and "))")
        }
        let milliseconds = try line.decode(Double.self, forKey: AnyKey("t_ms"))
        guard (0...Play.longest).contains(milliseconds) else {
            throw Refusal(reason: "t_ms is \(milliseconds), and it is milliseconds from the start, 0 through \(Int(Play.longest)), an hour")
        }
        let key = AnyKey(report)
        let decoded: Play.Report
        switch report {
        case "move":
            let (x, y) = try axes(line, key, "dx", "dy")
            decoded = .move(Move(x: x, y: y))
        case "wheel":
            let (vertical, horizontal) = try axes(line, key, "v", "h")
            decoded = .wheel(Scroll(vertical: vertical, horizontal: horizontal))
        case "down":
            decoded = .down(try button(line, key))
        default:
            guard try line.decode(Bool.self, forKey: key) else { throw Refusal(reason: "up releases every button and is written \"up\":true") }
            decoded = .up
        }
        timed = Play.Timed(at: .nanoseconds(Int64((milliseconds * 1e6).rounded())), report: decoded)
    }
}

/// The button a `down` line names, by word or by number.
///
/// Both spellings, because the device has thirty-two buttons and only three of them have a
/// word. A script written for a mouse with a thumb button says `{"down":8}`; one a person
/// wrote by hand says `{"down":"left"}`. [LAW:no-silent-failure] A word that names no
/// button and a number outside 1...32 are each refused by name rather than defaulted to
/// the left button, which would replay a different gesture than the script describes.
private func button(_ line: KeyedDecodingContainer<AnyKey>, _ key: AnyKey) throws -> Button {
    if let name = try? line.decode(String.self, forKey: key) {
        guard let button = Button(name: name) else {
            throw Refusal(reason: "\(key.stringValue) is \(name.debugDescription), which names no button: use \(Button.named.keys.sorted().joined(separator: ", ")), or a number from 1 to 32")
        }
        return button
    }
    // Read as a Double and judged here, not read as the UInt8 a button is. Measured: a
    // script saying 300, 256, -3 or 1.5 fails `decode(UInt8.self)` inside JSONDecoder,
    // which reports "The given data was not valid JSON" - true of none of them, and no
    // help at all to whoever wrote the line. A Double takes every one of them, so the
    // refusal below is the one that knows what the mistake was. [LAW:no-silent-failure]
    let number = try line.decode(Double.self, forKey: key)
    guard number == number.rounded(.towardZero), number >= 1, number <= 32, let button = Button(rawValue: UInt8(number)) else {
        throw Refusal(reason: "\(key.stringValue) is \(number.clean), and a button is a whole number from 1 to 32, or one of \(Button.named.keys.sorted().joined(separator: ", "))")
    }
    return button
}

/// A report's two axes, each refused rather than clamped when the device cannot carry it:
/// a replay that quietly sent 127 for 200 would not be the script. [LAW:no-silent-failure]
private func axes(_ line: KeyedDecodingContainer<AnyKey>, _ report: AnyKey, _ first: String, _ second: String) throws -> (Count, Count) {
    let axes = try container(line.superDecoder(forKey: report), taking: [first, second])
    /// Read as a Double and judged here for the reason the button is: an `Int` decode
    /// turns `1.5` and `1e300` into "The given data was not valid JSON" rather than into
    /// the sentence that says what a report can carry.
    func count(_ axis: String) throws -> Count {
        let value = try axes.decode(Double.self, forKey: AnyKey(axis))
        guard value == value.rounded(.towardZero), abs(value) <= Double(Count.limit) else {
            throw Refusal(reason: "\(report.stringValue).\(axis) is \(value.clean), and a report carries whole counts, -\(Count.limit) through \(Count.limit)")
        }
        return Count(clamping: Int(value))
    }
    return try (count(first), count(second))
}
