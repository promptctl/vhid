/// The displays a point or a box is placed on: a layout's online ones, where the devices
/// press, or its active ones, where the readers read. `DisplayLayout.online`, `.active`.
///
/// **The one pressing rule.** A point is pressed where it is, if a display holds it. A box
/// is pressed in the largest part of it one display shows that is at least a point a side,
/// at the whole point nearest that part's middle. Both halves place by this and nothing
/// else, and a `Placed` value is made nowhere but here, so a point a reader prints and the
/// point a device presses for it are one rule's answer. [LAW:single-enforcer]
public struct Displays: Hashable, Sendable {
    public let displays: [OnlineDisplay]

    init(_ displays: [OnlineDisplay]) {
        self.displays = displays
    }

    public var frames: [ScreenRect] { displays.map(\.frame) }

    /// `point`, where a display holds it.
    public func place(_ point: ScreenPoint) throws(Unplaced) -> Placed<ScreenPoint> {
        guard frames.contains(where: { $0.contains(point) }) else { throw Unplaced(.point(point), .onNoDisplay, on: self) }
        return Placed(point, on: self)
    }

    /// `box`, drawn within nothing but itself: a box a caller gave.
    public func place(_ box: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        try place(box, within: box, asked: .box(box))
    }

    /// `box`, cut to `bound` - what it is drawn within - and pressed in the largest part one
    /// display shows that is at least a point a side.
    public func place(_ box: ScreenRect, within bound: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        try place(box, within: bound, asked: .drawn(box, within: bound))
    }

    private func place(_ box: ScreenRect, within bound: ScreenRect, asked: Unplaced.Asked) throws(Unplaced) -> Placed<Shown> {
        guard let drawn = box.intersection(bound) else { throw Unplaced(asked, .noArea, on: self) }
        guard let part = Self.largest(parts(of: drawn).map(\.part)) else { throw Unplaced(asked, .onNoDisplay, on: self) }
        return Placed(Shown(box: box, bound: bound, part: part), on: self)
    }

    /// The parts of `box` the displays show that are at least a point a side, one per frame,
    /// with the first display listed at that frame, in the layout's order. A mirror set's
    /// members share a frame and so show a box once. [LAW:single-enforcer] The one statement
    /// of what the displays show of a box, which placement, a region's check and a capture's
    /// cut all ask.
    public func parts(of box: ScreenRect) -> [(display: OnlineDisplay, part: ScreenRect)] {
        var frames: Set<ScreenRect> = []
        return displays.filter { frames.insert($0.frame).inserted }
            .compactMap { display in box.intersection(display.frame).map { (display, $0) } }
            .filter { $0.part.width >= 1 && $0.part.height >= 1 }
    }

    /// The largest of `parts` by area, and of equals the first the layout lists, whatever
    /// order a sort or `max` would leave equals in.
    private static func largest(_ parts: [ScreenRect]) -> ScreenRect? {
        parts.indices.min { (-parts[$0].area, $0) < (-parts[$1].area, $1) }.map { parts[$0] }
    }

    /// Whether `other` presses every point and box as this does: the same frames in the same
    /// order, whatever is asleep. [LAW:one-source-of-truth] The one rule for "the layout
    /// changed", which a play and a recording both ask.
    public func pressesAlike(_ other: Displays) -> Bool { frames == other.frames }
}

/// A point or a box once the pressing rule has placed it, with the displays it was placed
/// on. Made only by `Displays.place`, so holding one is the proof the rule was asked.
/// [LAW:parse-dont-validate]
public struct Placed<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let displays: Displays

    fileprivate init(_ value: Value, on displays: Displays) {
        self.value = value
        self.displays = displays
    }
}

/// Where a box is pressed: the box as given, the bound it was placed within, and the part of
/// it one display shows inside that bound.
public struct Shown: Hashable, Sendable {
    public let box: ScreenRect
    public let bound: ScreenRect
    public let part: ScreenRect

    /// The whole point nearest the part's middle: the point a reader prints beside the box,
    /// which a click given that point presses exactly. A click given the box lands on a
    /// point drawn inside the part, as a person's clicks scatter on a button.
    /// [LAW:one-source-of-truth] Derived from the part, so the two cannot disagree.
    public var press: ScreenPoint {
        ScreenPoint(finite: Self.whole(nearest: part.centre.x, in: part.x, part.maxX), Self.whole(nearest: part.centre.y, in: part.y, part.maxY))
    }

    /// The whole number nearest `middle` in the half-open `[low, high)`, which holds one
    /// since a part is at least a point long.
    private static func whole(nearest middle: Double, in low: Double, _ high: Double) -> Double {
        min(max(middle.rounded(), low.rounded(.up)), high.rounded(.up) - 1)
    }
}

/// A point or a box that was not placed, and why.
public struct Unplaced: Error, Hashable, CustomStringConvertible {
    public enum Asked: Hashable, Sendable {
        case point(ScreenPoint)
        /// A box a caller gave, drawn within nothing but itself.
        case box(ScreenRect)
        /// A box drawn within a bound.
        case drawn(ScreenRect, within: ScreenRect)
    }

    public enum Why: Hashable, Sendable {
        /// No display holds the point, or shows a part of the box a point a side.
        case onNoDisplay
        /// The box shares no area with what it is drawn within: wholly outside it, or, for a
        /// box drawn within itself, a side of zero.
        case noArea
    }

    public let asked: Asked
    public let why: Why
    public let displays: Displays

    init(_ asked: Asked, _ why: Why, on displays: Displays) {
        self.asked = asked
        self.why = why
        self.displays = displays
    }

    public var description: String {
        let listed = displays.displays.isEmpty ? "no display is awake" : "the displays are \(displays.frames.map(\.description).joined(separator: "; "))"
        return switch (asked, why) {
        case (.point(let point), _): "\(point) is on no display: \(listed)"
        case (.box(let box), .noArea): "the box \(box) has a side of zero"
        case (.drawn(let box, let bound), .noArea): "the box \(box) is outside \(bound), which it is drawn within"
        case (.box(let box), .onNoDisplay), (.drawn(let box, _), .onNoDisplay):
            "the box \(box) is on no display, none showing a part of it a point a side: \(listed)"
        }
    }
}
