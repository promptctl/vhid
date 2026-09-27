import Foundation
import Keystrokes
import Pointing

/// A script of keyboard and mouse acts at fixed times on one clock: one absolute starting
/// point, then acts at offsets from a clock started once the cursor is there.
/// `docs/design/replay.md` is the design this follows.
///
/// Keys and buttons are stated as the whole set held from that moment, never as a change,
/// because a held set is what the device sends and a line that says it is true on its own.
///
/// Motion is `move`, raw counts that acceleration sees identically on every run, or `at`,
/// a point the player steers to, which is what a recording can say. Never both in one
/// script: a raw count is only the same input twice if nothing steered in between.
///
/// [LAW:parse-dont-validate] A `Play` that exists is a script that can be played whole:
/// at least one act, times that never go backwards, no more keys at once than a report
/// carries, and nothing held at the end. Nothing downstream asks any of that again.
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
        /// The script line it was written on, so a refusal made after parsing still names
        /// the line a person can find.
        public let line: Int
    }

    /// One act, as data. [LAW:one-type-per-behavior]
    public enum Report: Hashable, Sendable {
        /// Exactly these keys are down from now.
        case keys(HeldKeys)
        /// Exactly these buttons are down from now.
        case buttons(Set<Button>)
        case move(Move)
        /// The cursor should be here now.
        case at(ScreenPoint)
        case wheel(Scroll)
    }

    /// Parses JSON Lines: `{"to":{"x":800,"y":500}}` first, then one act a line -
    /// `{"t_ms":0,"keys":["leftShift",4]}`, `{"t_ms":0,"buttons":["left"]}`,
    /// `{"t_ms":8.3,"move":{"dx":4,"dy":0}}`, `{"t_ms":8.3,"at":{"x":810,"y":500}}`,
    /// `{"t_ms":16.7,"wheel":{"v":-1,"h":0}}`. Blank lines are
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
        let events = try lines.dropFirst().map { line in try decode(ReportLine.self, line).timed(on: line.number) }
        for (previous, next) in zip(events, events.dropFirst()) where next.at < previous.at {
            throw ScriptInvalid(line: next.line, reason: "t_ms goes backwards: \(next.at) after \(previous.at)")
        }
        if let firstMove = events.first(where: { if case .move = $0.report { true } else { false } }),
           let firstAt = events.first(where: { if case .at = $0.report { true } else { false } }) {
            throw ScriptInvalid(line: max(firstMove.line, firstAt.line), reason: "a script moves the pointer with move lines or with at lines, and this one has both (move on line \(firstMove.line), at on line \(firstAt.line))")
        }
        // What each held set is at the end: the last line that states it, or nothing held
        // when no line ever did.
        var keys = HeldKeys.none
        var buttons: Set<Button> = []
        for event in events {
            switch event.report {
            case .keys(let held): keys = held
            case .buttons(let held): buttons = held
            case .move, .at, .wheel: break
            }
        }
        guard keys.usages.isEmpty else {
            throw ScriptInvalid(line: last.number, reason: "the script ends with \(keys.usages.sorted().map(\.spelled).joined(separator: ", ")) held: end it with {\"t_ms\":…,\"keys\":[]}")
        }
        guard buttons.isEmpty else {
            throw ScriptInvalid(line: last.number, reason: "the script ends with button \(buttons.sorted().map { "\($0.rawValue)" }.joined(separator: ", ")) held: end it with {\"t_ms\":…,\"buttons\":[]}")
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
        to = try point(try container(decoder, taking: ["to"]), AnyKey("to"))
    }
}

/// A place on the screen, as the start line and an `at` line both write one.
private func point(_ line: KeyedDecodingContainer<AnyKey>, _ key: AnyKey) throws -> ScreenPoint {
    let place = try container(line.superDecoder(forKey: key), taking: ["x", "y"])
    let x = try place.decode(Double.self, forKey: AnyKey("x"))
    let y = try place.decode(Double.self, forKey: AnyKey("y"))
    guard let point = ScreenPoint(x: x, y: y) else {
        throw Refusal(reason: "\(key.stringValue) is (\(x.clean), \(y.clean)), which is not a place on the screen")
    }
    return point
}

private extension Double {
    /// This number as a script would have written it: no trailing `.0` on a whole one, so
    /// a refusal about `300` does not say `300.0` at somebody who never typed that.
    var clean: String { self == rounded(.towardZero) && abs(self) < 1e15 ? String(Int(self)) : String(self) }
}

/// `t_ms` and exactly one act.
private struct ReportLine: Decodable {
    static let reports: Set<String> = ["at", "buttons", "keys", "move", "wheel"]
    let at: Duration
    let report: Play.Report

    func timed(on line: Int) -> Play.Timed { Play.Timed(at: at, report: report, line: line) }

    init(from decoder: Decoder) throws {
        let line = try container(decoder, taking: Self.reports.union(["t_ms"]))
        let named = line.allKeys.map(\.stringValue).filter(Self.reports.contains).sorted()
        guard named.count == 1, let kind = named.first else {
            throw Refusal(reason: "a line carries exactly one of \(Self.reports.sorted().joined(separator: ", ")), and this one has \(named.isEmpty ? "none" : named.joined(separator: " and "))")
        }
        let milliseconds = try line.decode(Double.self, forKey: AnyKey("t_ms"))
        guard (0...Play.longest).contains(milliseconds) else {
            throw Refusal(reason: "t_ms is \(milliseconds), and it is milliseconds from the start, 0 through \(Int(Play.longest)), an hour")
        }
        let key = AnyKey(kind)
        let decoded: Play.Report
        switch kind {
        case "move":
            let (x, y) = try axes(line, key, "dx", "dy")
            decoded = .move(Move(x: x, y: y))
        case "wheel":
            let (vertical, horizontal) = try axes(line, key, "v", "h")
            decoded = .wheel(Scroll(vertical: vertical, horizontal: horizontal))
        case "at":
            decoded = .at(try point(line, key))
        case "buttons":
            decoded = .buttons(Set(try heldSet(line, key, button)))
        default:
            let usages = try heldSet(line, key, usage)
            do {
                decoded = .keys(try HeldKeys(Set(usages)))
            } catch {
                throw Refusal(reason: "keys holds \(error.held) keys besides the modifiers, and one report carries \(HeldKeys.capacity)")
            }
        }
        at = .nanoseconds(Int64((milliseconds * 1e6).rounded()))
        report = decoded
    }
}

/// A held-set line's list, each entry read by `one`, with an entry named twice refused:
/// a set written with a repeat is a script that says something other than it means.
private func heldSet<T: Hashable>(_ line: KeyedDecodingContainer<AnyKey>, _ key: AnyKey, _ one: (inout UnkeyedDecodingContainer, String) throws -> T) throws -> [T] {
    var list = try line.nestedUnkeyedContainer(forKey: key)
    var held: [T] = []
    while !list.isAtEnd {
        let entry = try one(&list, key.stringValue)
        guard !held.contains(entry) else { throw Refusal(reason: "\(key.stringValue) names one entry twice") }
        held.append(entry)
    }
    return held
}

/// One button of a `buttons` list, by word or by number.
///
/// Both spellings, because the device has thirty-two buttons and only three of them have a
/// word. A script written for a mouse with a thumb button says `[8]`; one a person wrote by
/// hand says `["left"]`. [LAW:no-silent-failure] A word that names no button and a number
/// outside 1...32 are each refused by name rather than defaulted to the left button, which
/// would replay a different gesture than the script describes.
private func button(_ list: inout UnkeyedDecodingContainer, _ key: String) throws -> Button {
    if let name = try? list.decode(String.self) {
        guard let button = Button(name: name) else {
            throw Refusal(reason: "\(key) has \(name.debugDescription), which names no button: use \(Button.named.keys.sorted().joined(separator: ", ")), or a number from 1 to 32")
        }
        return button
    }
    // Read as a Double and judged here, not read as the UInt8 a button is. Measured: a
    // script saying 300, 256, -3 or 1.5 fails `decode(UInt8.self)` inside JSONDecoder,
    // which reports "The given data was not valid JSON" - true of none of them, and no
    // help at all to whoever wrote the line. A Double takes every one of them, so the
    // refusal below is the one that knows what the mistake was. [LAW:no-silent-failure]
    let number = try list.decode(Double.self)
    guard number == number.rounded(.towardZero), number >= 1, number <= 32, let button = Button(rawValue: UInt8(number)) else {
        throw Refusal(reason: "\(key) has \(number.clean), and a button is a whole number from 1 to 32, or one of \(Button.named.keys.sorted().joined(separator: ", "))")
    }
    return button
}

/// The words a `keys` line may name a key by: a holdable modifier, or a key a chord names
/// by name. [LAW:one-source-of-truth] Read both ways, so a refusal spells a key the way the
/// script could have written it.
private let keyWords: [String: Usage] = {
    let modifiers = Modifier.holdable.compactMap { modifier in modifier.usage.map { (modifier.rawValue, $0) } }
    let named = KeyChord.namedKeys.compactMap { name, key in Usage(virtualKeyCode: key.rawValue).map { (name, $0) } }
    return Dictionary(uniqueKeysWithValues: modifiers + named)
}()

private extension Usage {
    /// This key as a script would write it: its word when it has one, else its number.
    var spelled: String { keyWords.first { $0.value == self }?.key ?? "\(rawValue)" }
}

/// One key of a `keys` list: a key by its HID usage, never by the character a layout puts
/// on it, since a held set spelled in characters could name a different key on each line
/// and on each layout. A name is a holdable modifier or a key a chord names by name; a
/// number is any keyboard-page usage from 4 through 231, the range that names keys.
private func usage(_ list: inout UnkeyedDecodingContainer, _ key: String) throws -> Usage {
    if let name = try? list.decode(String.self) {
        guard let usage = keyWords[name] else {
            throw Refusal(reason: "\(key) has \(name.debugDescription), which names no key: use a modifier (\(Modifier.holdableNames)), one of \(KeyChord.keyNameList), or a usage number from \(Usage.keys.lowerBound) to \(Usage.keys.upperBound)")
        }
        return usage
    }
    let number = try list.decode(Double.self)
    guard number == number.rounded(.towardZero), Double(Usage.keys.lowerBound) <= number, number <= Double(Usage.keys.upperBound) else {
        throw Refusal(reason: "\(key) has \(number.clean), and a key is a usage number from \(Usage.keys.lowerBound) to \(Usage.keys.upperBound), or a name")
    }
    return Usage(rawValue: UInt16(number))
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
