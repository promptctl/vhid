import ScreenSpace

/// How near the displays' edges a path runs. The cursor goes nowhere else, and macOS acts on
/// it at their edges - an auto-hidden Dock rises, a hot corner fires - so a path that means
/// to touch nothing keeps to them.
extension Displays {
    /// Whether the square of half-side `reach` about `point` lies on the displays: each of
    /// its corners on one, which for rectangles hundreds of points across is the whole
    /// square. A reach of zero asks whether the point itself is on one.
    ///
    /// **Corners, not each display alone**, because a square astride the seam between two
    /// displays side by side is on the screen though it is on neither display entirely; a
    /// test against one display at a time would see an edge at every seam.
    func covers(_ point: Submovement.Point, by reach: Double) -> Bool {
        [(-reach, -reach), (-reach, reach), (reach, -reach), (reach, reach)].allSatisfy { corner in
            (try? ScreenPoint(x: point.x + corner.0, y: point.y + corner.1)).map { corner in frames.contains { $0.contains(corner) } } ?? false
        }
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
