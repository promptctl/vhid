import Foundation
import Input
import Signals
import Telemetry

// The keys a verb's record is written under: the facts the devices and the verbs decide,
// named once here so a typo is a compile error rather than a second key.
// [LAW:types-are-the-program]

/// What a verb sent the devices, counted as each report is acknowledged.
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
    /// Keys a typist put down while another key was still held.
    case keyRollovers = "key_rollovers"
    /// Words a typist hesitated before.
    case keyHesitations = "key_hesitations"
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
    /// The hesitations a typist drew before the words it hesitated before, in milliseconds
    /// all told: drawn into the waits they precede, which `pauses` totals by the report
    /// each ends in. Zero for a run with none, and absent for a verb that never typed.
    case keyHesitationMilliseconds = "key_hesitation_ms"
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
    /// Each pointer move the verb made, in order, the one it stopped in too: the point it
    /// aimed at (`aimed`), the box it was drawn inside (`box`, absent for a point, which is
    /// `aimed` itself) and the target width its time was read from (`fitts_width`), how long its trajectory was drawn to take, how many reports
    /// steered it and then closed onto the aim, how many steered reports the cursor never
    /// showed, and where the cursor was read when it landed (`landed`, absent for a move that
    /// stopped first). Absent for a verb that made none.
    case paths
    /// How long an MCP tool call waited behind the calls before it, which its
    /// `duration_ms` includes.
    case queuedMilliseconds = "queued_ms"
    /// Which dispatcher the verb came through: `cli` or `mcp`.
    case entry
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

extension Telemetry {
    /// Adds `by` to `tally` on the unit underway.
    static func tally(_ tally: Tally, by amount: Int = 1) { Self.tally(tally.rawValue, by: amount) }

    /// Sets `attribute` on the unit underway.
    static func note(_ attribute: Attribute, _ value: JSON?) { note(attribute.rawValue, value) }
}

extension FirstSignal {
    /// Notes the signal taken, if one was, on the unit underway.
    func noted() {
        if let number = taken { Telemetry.note(.signal, .string(Attribute.name(ofSignal: number))) }
    }
}

extension Telemetry {
    /// Adds what a pointer traced to the unit underway: a move to `paths`, a pause to
    /// its kind's total in `pauses`. `Devices` hands every pointer it opens this, so no verb
    /// records its own. [LAW:single-enforcer]
    @Sendable static func traced(_ traced: Pointer.Traced) {
        switch traced {
        case .moved(let move): moved(move)
        case .paused(let pause): paused(pause)
        }
    }

    /// Adds what a typist traced to the unit underway: a pause to its kind's total in
    /// `pauses`, how late its run went to `keys_late_ms`, its rollovers to `key_rollovers`,
    /// and its hesitations to `key_hesitations` and `key_hesitation_ms`. `Devices` hands
    /// every typist it opens this. [LAW:single-enforcer]
    @Sendable static func typed(_ traced: Typist.Traced) {
        switch traced {
        case .paused(let pause): paused(pause)
        case .ran(let late, let rollovers, let hesitations):
            note(.keysLateMilliseconds, .double(late / .milliseconds(1)))
            tally(.keyRollovers, by: rollovers)
            tally(.keyHesitations, by: hesitations.count)
            note(.keyHesitationMilliseconds, .double(hesitations.reduce(.zero, +) / .milliseconds(1)))
        }
    }

    /// Adds a pause to its kind's total in `pauses`, a pointer's or a typist's.
    private static func paused(_ pause: Pause) {
        revise(Attribute.pauses.rawValue) { pauses in
            var kinds: [String: JSON] = if case .object(let kinds)? = pauses { kinds } else { [:] }
            let (count, ms): (Int, Double) = if case .object(let total)? = kinds[pause.kind.name],
                case .int(let count)? = total["count"], case .double(let ms)? = total["ms"] { (count, ms) } else { (0, 0) }
            kinds[pause.kind.name] = .object(["count": .int(count + 1), "ms": .double(ms + pause.length / .milliseconds(1))])
            return .object(kinds)
        }
    }

    private static func moved(_ move: Pointer.Moved) {
        var path: [String: JSON] = ["from": point(move.from),
                                    "aimed": point(move.aimed),
                                    "fitts_width": .double(move.width),
                                    "planned_ms": .double(move.planned / .milliseconds(1)),
                                    "structure": .string(move.structure.rawValue),
                                    "bow": .double(move.bow),
                                    "halfway": .double(move.halfway),
                                    "displays": .array(move.displays.frames.map { frame in .array([frame.minX, frame.minY, frame.width, frame.height].map { .double(Double($0)) }) }),
                                    "ends_kept": .double(move.kept.ends),
                                    "bow_kept": .double(move.kept.bow),
                                    "steered_reports": .int(move.steered),
                                    "closing_reports": .int(move.closing),
                                    "lost_reports": .int(move.lost)]
        path["landed"] = move.landed.map(point)
        // The box the aim was drawn inside, which with the seed and `from` draws the path
        // again; a point target is `aimed` itself.
        if case .box(let box) = move.toward { path["box"] = .array([box.x, box.y, box.width, box.height].map(JSON.double)) }
        append(.object(path), to: Attribute.paths.rawValue)
    }

    private static func point(_ point: ScreenPoint) -> JSON {
        .array([.double(point.x), .double(point.y)])
    }
}
