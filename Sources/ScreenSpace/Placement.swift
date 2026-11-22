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
        guard frames.contains(where: { $0.contains(point) }) else { throw Unplaced(.point(point), on: self) }
        return Placed(point, on: self)
    }

    /// `box`, drawn within nothing but itself: a box a caller gave.
    public func place(_ box: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        try place(box, within: box)
    }

    /// `box`, cut to `bound` - what it is drawn within - and pressed in the largest part one
    /// display shows that is at least a point a side.
    public func place(_ box: ScreenRect, within bound: ScreenRect) throws(Unplaced) -> Placed<Shown> {
        guard let drawn = box.intersection(bound) else { throw Unplaced(.box(box, within: bound), on: self) }
        let parts = frames.compactMap { drawn.intersection($0) }.filter { $0.width >= 1 && $0.height >= 1 }
        // The first of the largest, so a mirror set's members, which share a frame, choose one.
        guard let part = parts.reduce(nil, { (best: ScreenRect?, next) in best.map { $0.area >= next.area ? $0 : next } ?? next }) else {
            throw Unplaced(.box(box, within: bound), on: self)
        }
        return Placed(Shown(bound: bound, part: part, press: ScreenPoint(finite: Self.whole(nearest: part.centre.x, in: part.x, part.maxX),
                                                                            Self.whole(nearest: part.centre.y, in: part.y, part.maxY))), on: self)
    }

    /// The whole number nearest `middle` in the half-open `[low, high)`, which holds one
    /// since it is at least a point long.
    private static func whole(nearest middle: Double, in low: Double, _ high: Double) -> Double {
        min(max(middle.rounded(), low.rounded(.up)), high.rounded(.up) - 1)
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

/// Where a box is pressed: the bound it was placed within, the part of it one display shows
/// inside that bound, and the whole point in that part it is pressed at.
public struct Shown: Hashable, Sendable {
    public let bound: ScreenRect
    public let part: ScreenRect
    public let press: ScreenPoint
}

/// A point or a box no display shows, or a box wholly outside what it is drawn within.
public struct Unplaced: Error, Hashable, CustomStringConvertible {
    public enum Asked: Hashable, Sendable {
        case point(ScreenPoint)
        case box(ScreenRect, within: ScreenRect)
    }

    public let asked: Asked
    public let displays: Displays

    init(_ asked: Asked, on displays: Displays) {
        self.asked = asked
        self.displays = displays
    }

    public var description: String {
        let listed = displays.displays.isEmpty ? "no display is awake" : "the displays are \(displays.frames.map(\.description).joined(separator: "; "))"
        return switch asked {
        case .point(let point): "\(point) is on no display: \(listed)"
        case .box(let box, let bound) where box.intersection(bound) == nil: "the box \(box) is outside \(bound), which it is drawn within"
        case .box(let box, _): "the box \(box) is on no display, none showing a part of it a point a side: \(listed)"
        }
    }
}
