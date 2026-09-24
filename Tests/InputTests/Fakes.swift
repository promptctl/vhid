import AppKit
import Input
import Keystrokes
import Pointing
import Synchronization

/// A keyboard that records what it was asked to do and refuses after a given number of
/// calls, so a run can be stopped at any point inside a character.
///
/// One knob and not three: every call goes through the same counter, so "throw on the
/// second key-down of a two-keystroke character" and "throw on the release after it" are
/// the same test with a different number. [LAW:no-mode-explosion]
///
/// Not isolated to an actor, because `Keyboard` is not: the device is reached from
/// whatever task a caller runs on, so the log sits behind a lock the way a real device's
/// held set does.
final class RefusingKeyboard: Keyboard {
    private let state = Mutex<(log: [String], allow: Int)>(([], .max))

    var log: [String] { state.withLock { $0.log } }

    /// How many calls to let through before refusing every one after.
    var allow: Int {
        get { state.withLock { $0.allow } }
        set { state.withLock { $0.allow = newValue } }
    }

    private func record(_ what: String) throws {
        try state.withLock {
            guard $0.log.count < $0.allow else { throw Refused() }
            $0.log.append(what)
        }
    }

    func down(_ usage: Usage) throws { try record("down \(String(usage.rawValue, radix: 16))") }
    func releaseAll() throws { try record("up") }
}

/// A keyboard whose keys will not go down but whose release still answers: the daemon
/// that refuses a report and acknowledges the release after it.
final class StuckKeyboard: Keyboard {
    private let recorded = Mutex<[String]>([])

    var log: [String] { recorded.withLock { $0 } }

    func down(_ usage: Usage) throws {
        recorded.withLock { $0.append("down \(String(usage.rawValue, radix: 16))") }
        throw Refused()
    }

    func releaseAll() throws { recorded.withLock { $0.append("up") } }
}

struct Refused: Error {}

/// A pointing device that records every report reaching it. Where `FakeMouse` stands in
/// for the whole mouse, this stands under one - so a test can ask not only whether a
/// failure was raised but whether anything reached the device before it.
final class RecordingPointing: Pointing {
    private let recorded = Mutex<[String]>([])

    var log: [String] { recorded.withLock { $0 } }

    func down(_ button: Button) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
    func releaseAll() throws { recorded.withLock { $0.append("up") } }
    func move(by delta: Move) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
    func scroll(by delta: Scroll) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
}

/// A keystroke device that records every report reaching it, the keyboard's mirror of
/// `RecordingPointing`.
final class RecordingKeyPress: KeyPress {
    private let recorded = Mutex<[String]>([])

    var log: [String] { recorded.withLock { $0 } }

    func down(_ usage: Usage) throws { recorded.withLock { $0.append("down \(String(usage.rawValue, radix: 16))") } }
    func releaseAll() throws { recorded.withLock { $0.append("up") } }
}

/// A mouse on a screen of its own, recording every report. The cursor moves by what a
/// report asks times a curve standing in for the OS's acceleration - three points a
/// count when the report is fast, one when it is slow - so the pointer's loop is tested
/// against the thing it exists for, and its steps can be read back one by one.
///
/// The refusal logs the call and then refuses it: the daemon takes the report and
/// answers no, and the log says what was posted before it did. [LAW:no-silent-failure]
final class FakeMouse: Mouse {
    private let state: Mutex<State>

    private struct State {
        var log: [String] = []
        var allow = Int.max
        var position: ScreenPoint
        var stuck = false
    }

    init(at position: ScreenPoint) { state = Mutex(State(position: position)) }

    var log: [String] { state.withLock { $0.log } }
    var position: ScreenPoint { state.withLock { $0.position } }

    /// How many calls to accept before every one after is logged and refused.
    var allow: Int {
        get { state.withLock { $0.allow } }
        set { state.withLock { $0.allow = newValue } }
    }

    /// A cursor pinned in place: every report is posted and moves nothing.
    var stuck: Bool {
        get { state.withLock { $0.stuck } }
        set { state.withLock { $0.stuck = newValue } }
    }

    private func record(_ state: inout State, _ what: String) throws {
        state.log.append(what)
        guard state.log.count <= state.allow else { throw Refused() }
    }

    func down(_ button: Button) throws { try state.withLock { try record(&$0, "down \(button.rawValue)") } }
    func releaseAll() throws { try state.withLock { try record(&$0, "up") } }

    func move(by delta: Move) throws {
        try state.withLock {
            try record(&$0, "move \(delta.x.value) \(delta.y.value)")
            let gain = Self.gain(of: delta, stuck: $0.stuck)
            $0.position = ScreenPoint(x: $0.position.x + Double(delta.x.value) * gain, y: $0.position.y + Double(delta.y.value) * gain)!
        }
    }

    /// Points per count for one report: the curve's knee is at ten counts.
    private static func gain(of delta: Move, stuck: Bool) -> Double {
        guard !stuck else { return 0 }
        return max(abs(Int(delta.x.value)), abs(Int(delta.y.value))) > 10 ? 3 : 1
    }

    func scroll(by delta: Scroll) throws { try state.withLock { try record(&$0, "scroll \(delta.vertical.value) \(delta.horizontal.value)") } }

    func cursor() throws -> ScreenPoint { position }

    /// The pointer over this mouse, reading this screen.
    var pointer: Pointer { Pointer(mouse: self, cursor: cursor) }
}

/// A keyboard that cancels the run it is part of once `afterKeys` keys have gone down, so
/// a cancellation can be aimed between two reports of one character.
///
/// The task is handed over after it is made rather than taken at init, because the task
/// and the keyboard each need the other: the run types on this keyboard, and this keyboard
/// stops that run. Aiming before the first `await` is what makes it deterministic - a task
/// made on an actor does not begin until that actor suspends.
final class CancellingKeyboard: Keyboard {
    private let state = Mutex<(log: [String], run: Task<Void, any Error>?)>(([], nil))
    private let afterKeys: Int

    init(afterKeys: Int) { self.afterKeys = afterKeys }

    var log: [String] { state.withLock { $0.log } }

    func aim(at run: Task<Void, any Error>) { state.withLock { $0.run = run } }

    func down(_ usage: Usage) throws {
        state.withLock {
            $0.log.append("down \(String(usage.rawValue, radix: 16))")
            if $0.log.count >= afterKeys { $0.run?.cancel() }
        }
    }

    func releaseAll() throws { state.withLock { $0.log.append("up") } }
}

/// A mouse whose acceleration curve is one number, whatever the report asks for.
///
/// `FakeMouse`'s curve is one a Mac at default settings has - a slow report moves about a
/// point a count - which is exactly the curve under which the pointer's last step is
/// never the awkward one. A Mac with tracking speed turned up moves several points for a
/// single count, and that is the case this stands in for.
final class SteadyGainMouse: Mouse {
    private let state: Mutex<(log: [String], position: ScreenPoint)>
    private let gain: Double

    init(at position: ScreenPoint, gain: Double) {
        state = Mutex(([], position))
        self.gain = gain
    }

    var log: [String] { state.withLock { $0.log } }
    var position: ScreenPoint { state.withLock { $0.position } }

    func down(_ button: Button) throws { state.withLock { $0.log.append("down \(button.rawValue)") } }
    func releaseAll() throws { state.withLock { $0.log.append("up") } }
    func scroll(by delta: Scroll) throws { state.withLock { $0.log.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }

    func move(by delta: Move) throws {
        state.withLock {
            $0.log.append("move \(delta.x.value) \(delta.y.value)")
            $0.position = ScreenPoint(x: $0.position.x + Double(delta.x.value) * gain, y: $0.position.y + Double(delta.y.value) * gain)!
        }
    }

    var pointer: Pointer { Pointer(mouse: self) { self.position } }
}

/// A pasteboard of the test's own, so a test never writes to the one the person at this
/// Mac is using. The caller releases it.
func scratch() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("ai.promptctl.vhid.tests.\(UUID().uuidString)")) }
