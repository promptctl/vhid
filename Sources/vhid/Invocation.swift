import ArgumentParser
import Foundation
import Input
import Signals
import Synchronization

/// One verb, run once, and the record it leaves: which verb, how it ended, how long it
/// took, and the facts it decided on the way.
///
/// [LAW:nothing-unseen] Opened and closed in the two places every verb is dispatched from -
/// `Vhid.main` for the command line and the MCP server's tool-call handler - and nowhere
/// else. Code inside a verb never emits; it adds a fact to the invocation it is running in,
/// with `count` or `set`, and the dispatcher emits once, however the verb ended.
/// [LAW:single-enforcer]
final class Invocation: Sendable {
    /// The invocation the running task belongs to. Absent outside one: a verb's core called
    /// from a test, or from anything else that is not a dispatcher, has no record to add to.
    @TaskLocal static var current: Invocation?

    /// Which dispatcher it came through.
    enum Entry: String, Sendable {
        case commandLine = "cli"
        case mcp

        /// The words this dispatcher gives its caller for `error`, which is what the
        /// record carries: what the operator was told, and nothing they were not. None, for
        /// a verb that said everything on its way out and then exited nonzero, as `doctor`
        /// does. [LAW:one-source-of-truth]
        ///
        /// Except refused arguments, whose words quote them back - and an argument can hold
        /// text meant for a password field, on the command line missing the `--` that would
        /// have let a leading dash through. The caller saw them; the record, which outlives
        /// the terminal and the conversation, says only that the arguments were refused.
        func told(_ error: any Error) -> String? {
            let words = switch self {
            case .commandLine where Vhid.exitCode(for: error) == .validationFailure: Self.refusedArguments
            case .commandLine: Vhid.said(for: error)
            case .mcp where error is ArgumentRefused: Self.refusedArguments
            case .mcp: error.reported
            }
            return words.isEmpty ? nil : words
        }

        static let refusedArguments = "the arguments were refused; what they said is not recorded"
    }

    let entry: Entry
    /// The signals that stop it, for a verb run from the command line: the one taken, if
    /// one was, is on its record, and is what `record` answers.
    let signals: FirstSignal?
    /// W3C trace ID: 16 random bytes as 32 lowercase hex digits.
    let traceID = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    private let state: Mutex<(event: String, counts: [Tally: Int], attributes: [Attribute: JSON], lists: [Attribute: [JSON]], pauses: [Pause.Kind: (count: Int, slept: Duration)], typesText: Bool)>

    private init(_ event: String, via entry: Entry, stoppedBy signals: FirstSignal?) {
        self.entry = entry
        self.signals = signals
        state = Mutex((event, [:], [:], [:], [:], false))
    }

    /// Runs `body` as one invocation of `event`, and hands its record to `hand` however
    /// `body` ends - returned, thrown or cancelled - before passing that ending on.
    static func record<T>(_ event: String, via entry: Entry, stoppedBy signals: FirstSignal? = nil,
                          to hand: @escaping @Sendable (InvocationRecord) async -> Void,
                          _ body: (Invocation) async throws -> T) async throws -> T {
        let invocation = Invocation(event, via: entry, stoppedBy: signals)
        let startedAt = Date(), started = ContinuousClock.now
        let ending: Result<T, any Error>
        do {
            ending = .success(try await $current.withValue(invocation) { try await body(invocation) })
        } catch {
            ending = .failure(error)
        }
        let record = invocation.record(startedAt: startedAt, duration: .now - started, ending: ending.map { _ in () })
        // In a task of its own, which the cancellation that may have ended `body` does not
        // reach: a cancelled invocation's record is the one most worth delivering, and
        // URLSession would give it up at once.
        await Task { await hand(record) }.value
        return try ending.get()
    }

    /// The command line learns which verb it is running only once argv is parsed, inside
    /// the invocation that parsing belongs to.
    func named(_ event: String) {
        state.withLock { $0.event = event }
    }

    /// Adds `by` to `tally` on the running invocation.
    ///
    /// [LAW:no-defensive-null-guards] The one place `current`'s absence is handled, and it
    /// is the domain's: outside a dispatcher there is no unit of work whose record could be
    /// missing the fact.
    static func count(_ tally: Tally, by amount: Int = 1) {
        current?.state.withLock { $0.counts[tally, default: 0] += amount }
    }

    static func set(_ attribute: Attribute, _ value: JSON) {
        current?.state.withLock { $0.attributes[attribute] = value }
    }

    /// Adds `value` to the end of `attribute`'s list on the running invocation; the list is
    /// absent from the record until something is added to it.
    static func append(_ value: JSON, to attribute: Attribute) {
        current?.state.withLock { $0.lists[attribute, default: []].append(value) }
    }

    /// Says the running invocation types text it was given, which can be meant for a
    /// password field. Its record then names the error's kinds rather than quoting its
    /// words, which can quote the text: the characters the layout has no keys for, a dead
    /// key left half typed.
    static func typesText() {
        current?.state.withLock { $0.typesText = true }
    }

    private func record(startedAt: Date, duration: Duration, ending: Result<Void, any Error>) -> InvocationRecord {
        let (event, counts, decided, lists, pauses, typesText) = state.withLock { ($0.event, $0.counts, $0.attributes, $0.lists, $0.pauses, $0.typesText) }
        var attributes = decided.merging(lists.mapValues(JSON.array)) { $1 }
        attributes[.pauses] = pauses.isEmpty ? nil : .object(Dictionary(uniqueKeysWithValues: pauses.map { kind, total in
            (kind.name, .object(["count": .int(total.count), "ms": .double(total.slept / .milliseconds(1))]))
        }))
        attributes[.signal] = signals?.taken.map { .string(Attribute.name(ofSignal: $0)) }
        func told(_ failure: any Error) -> String? {
            typesText ? failure.causes.map { "\(type(of: $0))" }.joined(separator: ": ") : entry.told(failure)
        }
        let outcome: Outcome, error: String?
        switch ending {
        case .success:
            (outcome, error) = (.ok, nil)
        // What the verb threw says how it ended, not whether a cancel arrived meanwhile: a
        // verb the daemon refused as the cancel landed failed.
        case .failure(let failure) where failure.isCancellation:
            (outcome, error) = (.cancelled, told(failure))
        // `--help` and `--version` arrive as errors that exit 0: the invocation did what
        // it was asked.
        case .failure(let failure) where Vhid.exitCode(for: failure) == .success:
            (outcome, error) = (.ok, nil)
        case .failure(let failure):
            (outcome, error) = (.failed, told(failure))
        }
        return InvocationRecord(event: event, entry: entry, traceID: traceID, startedAt: startedAt, duration: duration,
                                outcome: outcome, error: error, counts: counts, attributes: attributes)
    }
}

/// What an invocation sent the devices, counted as each report is acknowledged.
/// `Devices.using` writes every one of these as zero when it opens the devices, so a verb
/// that opened them and sent nothing reads zero, and a verb that never opened them carries
/// none. Opening is not reaching: the connection is lazy, and a daemon that never answered
/// shows in the outcome and the error, not here.
enum Tally: String, CaseIterable, Sendable {
    case keyboardReports = "keyboard_reports"
    case mouseReports = "mouse_reports"
    /// Wheel reports with a count on the vertical axis: notches, since macOS takes a
    /// report as one notch whatever count it carries (`Pointer.scroll`).
    case verticalNotches = "scroll_notches_vertical"
    case horizontalNotches = "scroll_notches_horizontal"
}

/// A fact a verb decided that is not a count.
enum Attribute: String, Sendable {
    /// The double-click interval the pointer's hand was fitted to, as the HID system holds it.
    /// Absent when the devices were never opened.
    case doubleClickMilliseconds = "double_click_ms"
    /// The delay until a held key repeats that the typist's key holds were fitted to, as the
    /// HID system holds it. Absent when the devices were never opened.
    case keyRepeatDelayMilliseconds = "key_repeat_delay_ms"
    /// How far behind its drawn timing the typist's last report went out, in milliseconds:
    /// what slow acknowledgements and late wakes added to the run, every key after them
    /// moved rather than shortened. Zero for a run that sent nothing, and
    /// absent for a verb that never typed.
    case keysLateMilliseconds = "keys_late_ms"
    /// The pauses the pointer and the typist made between reports, the one it stopped in
    /// too, by kind - the pointer's `rest`, `hold`, `gap`, `drag_hold`, `notch`, and the
    /// typist's waits named for the report they end in, `modifier_down`, `key_down`,
    /// `key_up`, `modifier_up`: how many and how long they slept in all. By kind, not one
    /// by one, so a roll or a text of any length is a record of bounded size; the seed draws
    /// each one again. Absent for a verb that made none.
    case pauses
    /// What the devices' random source was seeded with, as hex: what draws the pointer's
    /// moves and pauses and the typist's key timings again. Absent when the devices were never opened.
    case seed
    /// Each pointer move the verb made, in order, the one it stopped in too: how long its
    /// trajectory was drawn to take, how many reports steered it and then closed onto the
    /// target, and how many steered reports the cursor never showed. Absent for a verb that
    /// made none.
    case paths
    /// How long an MCP tool call waited behind the calls before it, which its
    /// `duration_ms` includes.
    case queuedMilliseconds = "queued_ms"
    /// The signal that landed while a command-line verb ran: `SIGINT`, which Control-C
    /// sends, or `SIGTERM`, a supervisor's. Absent when none did.
    case signal
    /// The commands a cancelled reading's stop ended, each as it was run: empty when the
    /// cancel landed while the reading waited on no command. Absent when no reading was
    /// cancelled.
    case stopped

    static func name(ofSignal number: Int32) -> String {
        switch number {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        default: "signal \(number)"
        }
    }
}

/// How an invocation ended.
enum Outcome: String, Sendable {
    case ok, failed, cancelled
}

/// One invocation's record, as the type its rendering is made from. [LAW:types-are-the-program]
struct InvocationRecord: Sendable, Equatable {
    static let service = "vhid"

    let event: String
    let entry: Invocation.Entry
    let traceID: String
    let startedAt: Date
    let duration: Duration
    let outcome: Outcome
    let error: String?
    let counts: [Tally: Int]
    let attributes: [Attribute: JSON]

    /// Where a record went: to the collector, or to the file - because no collector is
    /// configured, or because the one configured could not take it.
    enum Sink: Sendable, Equatable {
        case otlp
        case file
        case fileAfter(collectorFailure: String)
    }

    /// The record as named fields, the one rendering both the file's line and the
    /// collector's attributes are made from. [LAW:one-source-of-truth]
    func fields(sink: Sink) -> [String: JSON] {
        var fields: [String: JSON] = [
            "event": .string(event),
            "entry": .string(entry.rawValue),
            "trace_id": .string(traceID),
            "service": .string(Self.service),
            "started_at": .string(startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
            "duration_ms": .double(duration / .milliseconds(1)),
            "outcome": .string(outcome.rawValue),
            "counts": .object(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, .int($0.value)) })),
            "attributes": .object(Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.rawValue, $0.value) })),
        ]
        fields["error"] = error.map(JSON.string)
        switch sink {
        case .otlp: fields["sink"] = .string("otlp")
        case .file: fields["sink"] = .string("file")
        case .fileAfter(let failure): (fields["sink"], fields["sink_error"]) = (.string("file"), .string(failure))
        }
        return fields
    }
}

/// A JSON value: what a record's fields are made of.
enum JSON: Sendable, Equatable, Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case array([JSON])
    case object([String: JSON])

    func encode(to encoder: any Encoder) throws {
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
    var line: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self) + Data("\n".utf8)
        }
    }
}

extension Invocation {
    /// Adds what a pointer traced to the running invocation: a move to `paths`, a pause to
    /// its kind's total in `pauses`. `Devices` hands every pointer it opens this, so no verb
    /// records its own. [LAW:single-enforcer]
    @Sendable static func traced(_ traced: Pointer.Traced) {
        switch traced {
        case .moved(let move): moved(move)
        case .paused(let pause): paused(pause)
        }
    }

    /// Adds what a typist traced to the running invocation: a pause to its kind's total in
    /// `pauses`, and how late its run went to `keys_late_ms`. `Devices` hands every typist
    /// it opens this. [LAW:single-enforcer]
    @Sendable static func typed(_ traced: Typist.Traced) {
        switch traced {
        case .paused(let pause): paused(pause)
        case .ran(let late): set(.keysLateMilliseconds, .double(late / .milliseconds(1)))
        }
    }

    /// Adds a pause to its kind's total in `pauses`, a pointer's or a typist's.
    private static func paused(_ pause: Pause) {
        current?.state.withLock {
            let total = $0.pauses[pause.kind, default: (0, .zero)]
            $0.pauses[pause.kind] = (total.count + 1, total.slept + pause.length)
        }
    }

    private static func moved(_ move: Pointer.Moved) {
        append(.object(["planned_ms": .double(move.planned / .milliseconds(1)),
                        "displays": .array(move.displays.frames.map { frame in .array([frame.minX, frame.minY, frame.width, frame.height].map { .double(Double($0)) }) }),
                        "bow_kept": .double(move.kept),
                        "steered_reports": .int(move.steered),
                        "closing_reports": .int(move.closing),
                        "lost_reports": .int(move.lost)]), to: .paths)
    }
}
