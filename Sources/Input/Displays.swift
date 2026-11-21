import Foundation

/// The displays: the rectangles of screen space they show, in `ScreenPoint`'s space. The
/// cursor goes nowhere else, and macOS acts on it at their edges - an auto-hidden Dock
/// rises, a hot corner fires - so a path that means to touch nothing has to know where
/// they are.
public struct Displays: Sendable, Equatable {
    public let frames: [ScreenRect]

    /// [LAW:parse-dont-validate] At least one display, each with area: a layout with none is
    /// no screen to keep a path on, and a display showing no area is none a cursor can be
    /// on. Each frame is already a box, so a bound that is not finite was refused where it
    /// was read.
    public init?(frames: [ScreenRect]) {
        guard !frames.isEmpty, frames.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.frames = frames
    }

    /// Whether the square of half-side `reach` about `point` lies on the displays: each of
    /// its corners on one, which for rectangles hundreds of points across is the whole
    /// square. A reach of zero asks whether the point itself is on one.
    ///
    /// **Corners, not each display alone**, because a square astride the seam between two
    /// displays side by side is on the screen though it is on neither display entirely; a
    /// test against one display at a time would see an edge at every seam.
    func covers(_ point: Submovement.Point, by reach: Double) -> Bool {
        [(-reach, -reach), (-reach, reach), (reach, -reach), (reach, reach)].allSatisfy { corner in
            ScreenPoint(x: point.x + corner.0, y: point.y + corner.1).map { corner in frames.contains { $0.contains(corner) } } ?? false
        }
    }

    /// Whether `point` is on a display and within a point of where the displays end: where
    /// the window server stops motion short. A seam between two displays side by side is
    /// no edge, by `covers`' rule.
    public func edge(at point: ScreenPoint) -> Bool {
        let at = (x: point.x, y: point.y)
        return covers(at, by: 0) && !covers(at, by: 1)
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
