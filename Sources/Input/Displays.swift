import CoreGraphics
import ScreenSpace

/// The displays: the rectangles of screen space they show, in `ScreenPoint`'s space. The
/// cursor goes nowhere else, and macOS acts on it at their edges - an auto-hidden Dock
/// rises, a hot corner fires - so a path that means to touch nothing has to know where
/// they are.
public struct Displays: Sendable, Equatable {
    public let frames: [ScreenRect]

    /// [LAW:parse-dont-validate] The one reading of the window server's display bounds, in
    /// the order it listed them: each display's by `ScreenRect(displayBounds:)`, the rule
    /// eyes reads them by too, so one with no area is a display showing nothing, kept, and
    /// on it no point is; and at least one with area, without which there is no screen to
    /// keep a path on.
    public init(bounds: [CGRect]) throws(DisplaysUnreadable) {
        let frames = try bounds.enumerated().map { (index, read) throws(DisplaysUnreadable) in
            guard let frame = ScreenRect(displayBounds: read) else { throw .bounds(display: index + 1, of: bounds.count, read) }
            return frame
        }
        guard frames.contains(where: { !$0.isEmpty }) else { throw .noArea(bounds) }
        self.frames = frames
    }

    /// Whether `point` is on a display.
    public func holds(_ point: ScreenPoint) -> Bool { covers(point.x, point.y, by: 0) }

    /// Whether the square of half-side `reach` about `x, y` lies on the displays: each of its
    /// corners on one, which for rectangles hundreds of points across is the whole square. A
    /// reach of zero asks whether the point itself is on one. On numbers, as a path's
    /// arithmetic holds them: one that is no number is on no display, because no display's
    /// edges hold it.
    ///
    /// **Corners, not each display alone**, because a square astride the seam between two
    /// displays side by side is on the screen though it is on neither display entirely; a
    /// test against one display at a time would see an edge at every seam.
    func covers(_ x: Double, _ y: Double, by reach: Double) -> Bool {
        [(-reach, -reach), (-reach, reach), (reach, -reach), (reach, reach)].allSatisfy { corner in
            frames.contains { $0.contains(x: x + corner.0, y: y + corner.1) }
        }
    }

    func covers(_ point: Submovement.Point, by reach: Double) -> Bool { covers(point.x, point.y, by: reach) }

    /// Whether `point` is on a display and within a point of where the displays end: where
    /// the window server stops motion short. A seam between two displays side by side is
    /// no edge, by `covers`' rule.
    public func edge(at point: ScreenPoint) -> Bool {
        covers(point.x, point.y, by: 0) && !covers(point.x, point.y, by: 1)
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

/// The window server's displays that are no layout a path can be kept on: a list it would
/// not give, a display whose bounds are no place a display can be, or none with area.
public enum DisplaysUnreadable: Error, CustomStringConvertible, Equatable {
    case list(CGError)
    case bounds(display: Int, of: Int, CGRect)
    case noArea([CGRect])

    public var description: String {
        switch self {
        case .list(let error):
            "the window server would not list the displays: CGError \(error.rawValue)"
        case .bounds(let display, let count, let read):
            "the window server gave display \(display) of \(count) the bounds \(Self.spelled(read)), which are no place a display can be"
        case .noArea(let read):
            "the window server listed no display with area for a path to be kept on: \(read.isEmpty ? "none at all" : read.map(Self.spelled).joined(separator: "; "))"
        }
    }

    private static func spelled(_ rect: CGRect) -> String {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { Double($0).positional }.joined(separator: ",")
    }
}
