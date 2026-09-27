import Foundation
import Keystrokes
import Pointing

/// One event as the session tap delivered it, reduced to what a recording reads: when,
/// from which device, where the cursor was, and what happened.
///
/// [LAW:effects-at-boundaries] The tap is the effect and this is its value, so the
/// `Recorder` that reads these runs in a test on events a test made.
public struct TapEvent: Hashable, Sendable {
    /// Since the recording started.
    public let at: Duration
    /// The event's tap field 87: the registry ID of the pqrs service that sent it, or 0
    /// for an event from a device of the person's own.
    public let sender: UInt64
    /// Where the cursor was, which every event carries.
    public let location: ScreenPoint
    public let kind: Kind

    public enum Kind: Hashable, Sendable {
        case keyDown(keyCode: UInt16, autorepeat: Bool)
        case keyUp(keyCode: UInt16)
        /// A modifier or Caps Lock changed; `flags` is every modifier bit after it.
        case flagsChanged(keyCode: UInt16, flags: UInt64)
        /// The cursor moved, with or without a button held.
        case motion
        case buttonDown(Button)
        case buttonUp(Button)
    }

    public init(at: Duration, sender: UInt64, location: ScreenPoint, kind: Kind) {
        self.at = at
        self.sender = sender
        self.location = location
        self.kind = kind
    }
}

/// Tap events in, a `vhid play` script out. `docs/design/replay.md` is the design:
/// "Where recording reads from", "Keeping vhid out of its own recording" and "Stopping
/// without recording the stop".
///
/// Every line states a whole held set, so every line the recorder writes is read off the
/// sets it keeps, never off the event that changed them. [LAW:one-source-of-truth]
public struct Recorder {
    /// The registry IDs of the pqrs services vhid posts through: an event from one of
    /// them is vhid's, not the person's.
    public var vhid: Set<UInt64>
    public let start: ScreenPoint
    /// Whether a point is on a screen's edge, where motion can be stopped short.
    private let atEdge: @Sendable (ScreenPoint) -> Bool

    private var lines: [Line]
    /// Keys the person holds, modifiers apart.
    private var keys: Set<Usage> = []
    /// Modifiers down in the session, from the device bits of the last flags seen: the
    /// person's and vhid's together.
    private var session: Set<Usage>
    /// Modifiers vhid holds, from vhid's own flag events.
    private var vhidModifiers: Set<Usage> = []
    private var buttons: Set<Button> = []
    /// How far vhid's motion has carried the cursor, which the person's points are
    /// written without.
    private var offset = (x: 0.0, y: 0.0)
    /// Where the cursor was at the last event from anyone.
    private var last: ScreenPoint

    /// Key presses with no usage, fn above all, left out of the recording.
    public private(set) var unmapped = 0
    /// Motion of vhid's that ended on a screen edge, after which the offset may be wrong.
    public private(set) var vhidAtEdge = 0

    private enum Line {
        case keys(Duration, Set<Usage>)
        case buttons(Duration, Set<Button>)
        case at(Duration, ScreenPoint)

        var at: Duration {
            switch self {
            case .keys(let at, _), .buttons(let at, _), .at(let at, _): at
            }
        }
    }

    /// A recording from `start`, with the session's modifier `flags` as they were then:
    /// the first keys line, at 0, is the modifiers already down. vhid holds nothing then,
    /// because recording refuses to start while it holds the devices.
    public init(start: ScreenPoint, flags: UInt64, vhid: Set<UInt64>, atEdge: @escaping @Sendable (ScreenPoint) -> Bool) {
        self.start = start
        self.vhid = vhid
        self.atEdge = atEdge
        session = Self.modifiers(in: flags)
        last = start
        lines = [.keys(.zero, session)]
    }

    /// Takes one event, writing a line when it changed what the person holds or where
    /// they put the cursor.
    public mutating func take(_ event: TapEvent) {
        // Never before the line before it: the tap can hand two devices' events over a
        // hair out of order, and a script's times may not go backwards.
        let event = TapEvent(at: max(event.at, lines.last?.at ?? .zero), sender: event.sender, location: event.location, kind: event.kind)
        let held = self.held
        if vhid.contains(event.sender) {
            takeVhid(event)
        } else {
            takePerson(event)
        }
        // A modifier vhid let go of while the person held it stays down in the session;
        // once its bit clears it is nobody's, and the person's next press of it is theirs.
        vhidModifiers.formIntersection(session)
        last = event.location
        if self.held != held { lines.append(.keys(event.at, self.held)) }
    }

    /// What the person holds: their keys, and the session's modifiers less vhid's.
    private var held: Set<Usage> { keys.union(session.subtracting(vhidModifiers)) }

    private mutating func takeVhid(_ event: TapEvent) {
        switch event.kind {
        case .motion:
            offset = (offset.x + event.location.x - last.x, offset.y + event.location.y - last.y)
            vhidAtEdge += atEdge(event.location) ? 1 : 0
        case .flagsChanged(let code, let flags):
            session = Self.modifiers(in: flags)
            if let modifier = Usage(virtualKeyCode: code), let bit = Self.deviceBits[modifier] {
                if flags & bit != 0 { vhidModifiers.insert(modifier) } else { vhidModifiers.remove(modifier) }
            }
        case .keyDown, .keyUp, .buttonDown, .buttonUp:
            break
        }
    }

    private mutating func takePerson(_ event: TapEvent) {
        switch event.kind {
        case .keyDown(_, autorepeat: true):
            break
        case .keyDown(let code, autorepeat: false):
            if let usage = Usage(virtualKeyCode: code) { keys.insert(usage) } else { unmapped += 1 }
        case .keyUp(let code):
            _ = Usage(virtualKeyCode: code).map { keys.remove($0) }
        case .flagsChanged(Self.capsLockCode, let flags):
            // Caps Lock toggles and never comes up, so it is written as a press: the set
            // with it, then the set without it.
            session = Self.modifiers(in: flags)
            lines.append(.keys(event.at, held.union([Self.capsLock])))
            lines.append(.keys(event.at, held))
        case .flagsChanged(Self.fnCode, let flags):
            // fn has no usage, so it is left out, and counted as it goes down.
            unmapped += flags & Self.fnBit != 0 ? 1 : 0
            session = Self.modifiers(in: flags)
        case .flagsChanged(_, let flags):
            session = Self.modifiers(in: flags)
        case .motion:
            lines.append(.at(event.at, ScreenPoint(x: event.location.x - offset.x, y: event.location.y - offset.y) ?? event.location))
        case .buttonDown(let button):
            buttons.insert(button)
            lines.append(.buttons(event.at, buttons))
        case .buttonUp(let button):
            buttons.remove(button)
            lines.append(.buttons(event.at, buttons))
        }
    }

    /// The script, stopped at `stop`.
    ///
    /// The keys lines at the end that hold nothing but `stopKeys` - the Control keys and the
    /// key that types `c` - are dropped, since they are the chord that stopped the
    /// recording, pressed and let go. A line holding any other key was not the stop, and
    /// the run ends there. Then every key and button comes up, at the stop or the last line,
    /// whichever is later, as a script has to end.
    public func script(stoppedAt stop: Duration, stopKeys: Set<Usage>) -> String {
        // The stop chord is the run of keys lines at the end holding nothing but stop keys,
        // its releases included, back to the last buttons line or keys line holding
        // anything else. Pointer lines inside it are the person's and stay.
        let chord = lines.indices.reversed().prefix { index in
            switch lines[index] {
            case .keys(_, let held): held.isSubset(of: stopKeys)
            case .at: true
            case .buttons: false
            }
        }
        // The run's first keys line, when it holds nothing, is the release before the chord
        // began, not part of it: dropped, the key before it would stay held to the stop.
        let before = chord.last { index in if case .keys = lines[index] { true } else { false } }
        let released = before.flatMap { index in if case .keys(_, let held) = lines[index], held.isEmpty { index } else { nil } }
        let kept = lines.enumerated().filter { index, line in
            guard chord.contains(index), case .keys = line else { return true }
            return index == 0 || index == released
        }.map(\.element)
        let end = max(stop, kept.last?.at ?? .zero)
        let written = kept + [.keys(end, []), .buttons(end, [])]
        return ([#"{"to":\#(Self.point(start))}"#] + written.map(Self.render)).joined(separator: "\n") + "\n"
    }

    private static func render(_ line: Line) -> String {
        switch line {
        case .keys(let at, let held):
            return #"{"t_ms":\#(milliseconds(at)),"keys":[\#(held.sorted().map { $0.written }.joined(separator: ","))]}"#
        case .buttons(let at, let held):
            return #"{"t_ms":\#(milliseconds(at)),"buttons":[\#(held.sorted().map { $0.name.map { "\"\($0)\"" } ?? "\($0.rawValue)" }.joined(separator: ","))]}"#
        case .at(let at, let place):
            return #"{"t_ms":\#(milliseconds(at)),"at":\#(point(place))}"#
        }
    }

    private static func point(_ point: ScreenPoint) -> String {
        #"{"x":\#(number(point.x)),"y":\#(number(point.y))}"#
    }

    private static func milliseconds(_ duration: Duration) -> String {
        number(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    /// Three decimals at most, and no trailing zeros: a microsecond, or a thousandth of a
    /// point, is finer than anything the tap reports.
    private static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static let capsLockCode: UInt16 = 0x39
    static let capsLock = Usage(virtualKeyCode: capsLockCode)!
    static let fnCode: UInt16 = 63
    /// `NX_SECONDARYFNMASK`: fn is down.
    static let fnBit: UInt64 = 0x800000

    /// Each side's modifier bit in an event's flags, `NX_DEVICE*KEYMASK`. The side a
    /// modifier is on is only in these, never in the side-blind bits beside them.
    static let deviceBits: [Usage: UInt64] = [
        .leftControl: 0x1, .leftShift: 0x2, .rightShift: 0x4, .leftCommand: 0x8,
        .rightCommand: 0x10, .leftOption: 0x20, .rightOption: 0x40, .rightControl: 0x2000,
    ]

    /// The modifiers whose device bits are set in `flags`. Read whole on every event
    /// rather than toggled on one, so a modifier already down when recording started
    /// is released when it comes up rather than held forever.
    static func modifiers(in flags: UInt64) -> Set<Usage> {
        Set(deviceBits.filter { flags & $0.value != 0 }.keys)
    }
}
