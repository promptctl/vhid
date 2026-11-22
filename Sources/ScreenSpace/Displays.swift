/// One display the window server lists online: its id, where it sits in the screen space,
/// and whether it is active. A display asleep is online and not active: the cursor moves on
/// it and its Dock rises, and a capture of it shows nothing.
///
/// The record both wires carry it as, the reader child's line and the helper's reply, is
/// `fields`, read back by `init(fields:)`. [LAW:one-source-of-truth]
public struct OnlineDisplay: Hashable, Sendable {
    public let id: UInt32
    public let bounds: ScreenRect
    public let active: Bool

    public init(id: UInt32, bounds: ScreenRect, active: Bool) {
        self.id = id
        self.bounds = bounds
        self.active = active
    }

    /// How many numbers one display is on a wire.
    public static let width = 6

    /// The id, the four numbers of the bounds, and 1 for active or 0.
    public var fields: [Double] { [Double(id), bounds.x, bounds.y, bounds.width, bounds.height, active ? 1 : 0] }

    /// One display read back from `fields`. [LAW:parse-dont-validate]
    public init(fields: ArraySlice<Double>) throws(LayoutUnreadable) {
        let numbers = Array(fields)
        guard numbers.count == Self.width, let id = UInt32(exactly: numbers[0]), [0, 1].contains(numbers[5]) else {
            throw .notARecord(numbers)
        }
        do {
            bounds = try ScreenRect(x: numbers[1], y: numbers[2], width: numbers[3], height: numbers[4])
        } catch {
            throw .notADisplay(id, error)
        }
        self.id = id
        active = numbers[5] == 1
    }
}

/// The online displays, each listed whole: where every point an act takes or a look reads
/// can be.
///
/// [LAW:parse-dont-validate] At least one display, each with area, and an extent - the box
/// holding them all - whose size a Double holds, so every difference of two points placed on
/// it is finite. Read once by an act or a look and passed on as a value.
/// [LAW:no-ambient-temporal-coupling]
public struct DisplayLayout: Hashable, Sendable {
    public let displays: [OnlineDisplay]

    public init(_ displays: [OnlineDisplay]) throws(LayoutUnreadable) {
        guard let first = displays.first else { throw .noDisplay }
        for display in displays where display.bounds.isEmpty { throw .arealess(display) }
        do {
            _ = try displays.dropFirst().reduce(first.bounds) { try $0.union($1.bounds) }
        } catch {
            throw .unbounded(displays.map(\.bounds))
        }
        self.displays = displays
    }

    /// The layout as one wire record: each display's `fields`, one after another.
    public var fields: [Double] { displays.flatMap(\.fields) }

    public init(fields: [Double]) throws(LayoutUnreadable) {
        guard fields.count % OnlineDisplay.width == 0 else { throw .notARecord(fields) }
        var displays: [OnlineDisplay] = []
        for start in stride(from: 0, to: fields.count, by: OnlineDisplay.width) {
            displays.append(try OnlineDisplay(fields: fields[start ..< start + OnlineDisplay.width]))
        }
        try self.init(displays)
    }

    /// Every online display: where the cursor can go, so where an act is placed.
    public var online: Displays { Displays(displays) }

    /// The active ones: what a capture can show, so where a look is placed. None on a Mac
    /// whose only display is asleep.
    public var active: Displays { Displays(displays.filter(\.active)) }
}

/// A display list that is no layout.
public enum LayoutUnreadable: Error, Equatable, CustomStringConvertible {
    case noDisplay
    case arealess(OnlineDisplay)
    case unbounded([ScreenRect])
    case notARecord([Double])
    /// A display listed at bounds that are no box.
    case notADisplay(UInt32, NotABox)
    /// The window server's own refusal, as its reader said it.
    case refused(String)

    public var description: String {
        switch self {
        case .noDisplay: "the window server listed no online display"
        case .arealess(let display): "display \(display.id) is listed at \(display.bounds), which has no area"
        case .unbounded(let bounds): "the displays at \(bounds.map(\.description).joined(separator: " ")) lie further apart than a Double holds"
        case .notARecord(let numbers): "\(numbers.map(Coordinate.spelled).joined(separator: " ")) is not a display list: \(OnlineDisplay.width) numbers a display, id, x, y, width, height and 1 or 0 for active"
        case .notADisplay(let id, let box): "display \(id) is listed at bounds that are no box: \(box)"
        case .refused(let why): why
        }
    }
}

/// Some displays of a layout - its online ones or its active ones - and the one rule for
/// where on them a point or a box is pressed.
///
/// [LAW:single-enforcer] The devices press and the readers print by this rule and no other:
/// a rule only one half linked would grow a second version in the other, and the two would
/// disagree on what is pressable and where.
public struct Displays: Hashable, Sendable {
    /// In the order the window server listed them, which settles a tie.
    public let displays: [OnlineDisplay]

    init(_ displays: [OnlineDisplay]) { self.displays = displays }

    /// Where each display sits, in the same order.
    public var frames: [ScreenRect] { displays.map(\.bounds) }

    /// Whether `other` presses every point and box where these do: the same frames in the
    /// same order, whatever is asleep. [LAW:single-enforcer] What "the layout changed" means
    /// to the devices, a play's and a recording's alike.
    public func pressesAlike(_ other: Displays) -> Bool { frames == other.frames }

    /// A point is pressed where it is, when a display holds it, on the first that does.
    public func place(_ point: ScreenPoint) throws(Unplaced) -> Placed<ScreenPoint> {
        guard let display = displays.first(where: { $0.bounds.contains(point) }) else { throw .point(point) }
        return Placed(value: point, on: display, of: self)
    }

    /// A box is pressed in the largest part of it one display shows that is at least a point a
    /// side, the first display's on a tie, at the whole point nearest that part's middle that
    /// the part holds. A part a point a side always holds a whole point, since every half-open
    /// span a point long holds one, and that point lies between the part's finite edges.
    public func place(_ box: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        guard let shown = parts(of: box).max(by: { $0.part.area < $1.part.area }) else { throw .box(box) }
        func nearest(_ start: Double, _ length: Double) -> Double {
            min(max((start + length / 2).rounded(), start.rounded(.up)), (start + length).rounded(.up) - 1)
        }
        let part = shown.part
        let press = ScreenPoint(between: (nearest(part.x, part.width), nearest(part.y, part.height)))
        return Placed(value: Shown(box: box, part: part, press: press), on: shown.display, of: self)
    }

    /// A box drawn only inside `clip` - a row in its list's viewport - pressed by the same rule
    /// in the part of it `clip` lets show, and kept as given, so what it was is still known.
    public func place(_ box: ScreenRect, clippedTo clip: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        guard let drawn = box.intersection(clip) else { throw .box(box) }
        do throws(Unplaced) {
            let placed = try place(drawn)
            return Placed(value: Shown(box: box, part: placed.value.part, press: placed.value.press), on: placed.display, of: self)
        } catch {
            throw .box(box)
        }
    }

    /// Each part of `box` a display shows that is at least a point a side, with that display,
    /// in the order the displays are listed: what `place` chooses from, and what a capture
    /// asks to know whether a box lies on one display.
    public func parts(of box: ScreenRect) -> [(display: OnlineDisplay, part: ScreenRect)] {
        displays.compactMap { display in display.bounds.intersection(box).map { (display: display, part: $0) } }
            .filter { $0.part.width >= 1 && $0.part.height >= 1 }
    }
}

/// A value placed on displays: the display that shows it, and the displays it was placed
/// among. Made only by `Displays.place`, so holding one is the proof a display shows it.
/// [LAW:parse-dont-validate]
public struct Placed<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let display: OnlineDisplay
    public let displays: Displays

    init(value: Value, on display: OnlineDisplay, of displays: Displays) {
        self.value = value
        self.display = display
        self.displays = displays
    }
}

/// A box as placed: the box as given, the part of it a display shows, and the point it is
/// pressed at, inside that part.
public struct Shown: Hashable, Sendable {
    public let box: ScreenRect
    public let part: ScreenRect
    public let press: ScreenPoint
}

/// What no display shows: a point no display holds, or a box no display shows a part of a
/// point or more a side.
public enum Unplaced: Error, Hashable, CustomStringConvertible {
    case point(ScreenPoint)
    case box(ScreenRect)

    public var description: String {
        switch self {
        case .point(let point): "\(point) is on no display"
        case .box(let box): "no display shows a part of the box \(box) a point or more a side"
        }
    }
}
