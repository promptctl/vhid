import Foundation
import ScreenSpace

/// The displays the cursor can be on: every online display of the one layout, a sleeping one
/// included, since the cursor still moves on it and macOS still acts at its edges - an
/// auto-hidden Dock rises, a hot corner fires - so a path that means to touch nothing has to
/// know where they are.
///
/// [LAW:parse-dont-validate] This is the one door into the pointer's arithmetic: what it
/// places is on a display of a layout whose extent's diagonal is finite, so every difference
/// and distance between two placed points is a finite number, with no bound of its own.
public struct Displays: Sendable, Hashable {
    /// Each online display's bounds, a display with no area included: it holds no point.
    public let frames: [ScreenRect]

    public init(_ layout: DisplayLayout) {
        frames = layout.displays.map(\.bounds)
    }

    /// `point`, when a display holds it.
    public func place(_ point: ScreenPoint) throws(OffDisplays) -> Placed<ScreenPoint> {
        guard frames.contains(where: { $0.contains(point) }) else { throw OffDisplays(target: .point(point)) }
        return Placed(point)
    }

    /// `target` as a click presses it: a point a display holds, or the part of a box the
    /// display showing most of it shows, when that part is itself a box a press can land in.
    /// A document frame far wider than any screen is pressed where it is seen.
    public func place(_ target: Target) throws(OffDisplays) -> Placed<Target> {
        switch target {
        case .point(let point): return Placed(.point(try place(point).value))
        case .box(let box):
            let shown = frames.compactMap { $0.intersection(box.rect) }.max { $0.area < $1.area }
            guard let part = shown.flatMap(Target.Box.init) else { throw OffDisplays(target: target) }
            return Placed(.box(part))
        }
    }

    /// Whether the square of half-side `reach` about `point` lies on the displays: each of
    /// its corners on one, which for rectangles hundreds of points across is the whole
    /// square. A reach of zero asks whether the point itself is on one. A corner that is no
    /// place - a path drawn past a Double - is on none.
    ///
    /// **Corners, not each display alone**, because a square astride the seam between two
    /// displays side by side is on the screen though it is on neither display entirely; a
    /// test against one display at a time would see an edge at every seam.
    func covers(_ point: Submovement.Point, by reach: Double) -> Bool {
        [(-reach, -reach), (-reach, reach), (reach, -reach), (reach, reach)].allSatisfy { corner in
            guard let at = try? ScreenPoint.at(point.x + corner.0, point.y + corner.1) else { return false }
            return frames.contains { $0.contains(at) }
        }
    }

    /// Whether `point` is on a display and within a point of where the displays end, where
    /// macOS stops motion short. A seam between two displays side by side is no edge: the
    /// rule is `covers`, the one the trajectory keeps its path by. [LAW:single-enforcer]
    public func isAtEdge(_ point: ScreenPoint) -> Bool {
        covers((point.x, point.y), by: 0) && !covers((point.x, point.y), by: 1)
    }

    /// How far inside the displays `point` is, up to `limit`: the half-side of the largest
    /// square about it that `covers` finds on them, to a few hundredths of a point and
    /// never more than it found. Nil for a point on no display, which has no depth to keep.
    func depth(of point: Submovement.Point, upTo limit: Double) -> Double? {
        guard covers(point, by: 0) else { return nil }
        guard !covers(point, by: limit) else { return limit }
        var (inside, outside) = (0.0, limit)
        for _ in 0 ..< 10 {
            let middle = (inside + outside) / 2
            (inside, outside) = covers(point, by: middle) ? (middle, outside) : (inside, middle)
        }
        return inside
    }
}

/// A value on the displays an act read: made only by `Displays.place`, and by aiming inside
/// what it placed. Steering, aiming and pressing take nothing else, so their arithmetic runs
/// on numbers the layout bounds. [LAW:types-are-the-program]
public struct Placed<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value

    fileprivate init(_ value: Value) { self.value = value }
}

extension Placed where Value == Target {
    /// Where a click from `start` is aimed: `Target.aim`, a point of the placed target, so on
    /// the displays itself.
    func aim(from start: Placed<ScreenPoint>, drawing generator: inout some RandomNumberGenerator) -> Placed<ScreenPoint> {
        Placed<ScreenPoint>(value.aim(from: start.value, drawing: &generator))
    }
}

/// A place an act was given that no display shows: a point no display holds, or a box no
/// display shows a point a side of. Refused by name, never moved to an edge.
/// [LAW:no-silent-failure]
public struct OffDisplays: Error, Equatable, CustomStringConvertible {
    public let target: Target

    public var description: String {
        switch target {
        case .point: "\(target) is on no display"
        case .box: "\(target) is on no display, or shows less than a point a side on each it meets"
        }
    }
}
