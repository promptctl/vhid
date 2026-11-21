import CoreGraphics
import Foundation

/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points.
///
/// The frame eyes reads a window, an element or a word at, and the box a pointer verb is
/// aimed at. It may be empty, as a window or a Vision box can be; a box a press can land
/// inside is `Target.Box`, parsed from one of these where a press is aimed.
/// [LAW:types-are-the-program]
///
/// The geometry of boxes is here, beside the box, as plain arithmetic: every edge lies
/// within `ScreenPoint.farthest`, so the part two boxes share, the box holding both, a box
/// rounded out to whole points and the point of a box nearest a place are all boxes and
/// points again, and none of it can fail. [LAW:one-source-of-truth]
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD. This is the axis that gets flipped by mistake.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box, and the one place
    /// four that are not one are refused: an edge past `ScreenPoint.farthest`, its far edges
    /// included, which no NaN or infinity is within, or a side under zero.
    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, x + width, y + height].allSatisfy({ abs($0) <= ScreenPoint.farthest }), width >= 0, height >= 0 else { return nil }
        self.init(left: x, top: y, right: x + width, bottom: y + height)
    }

    /// A CoreGraphics rectangle as it was given, or none for one that is no box: CGRect's
    /// null, whose origin is infinite, a frame an app claims that is not finite, or one
    /// with a side under zero. Its origin and size are read as they are, never standardized
    /// as `CGRect.width` is, so a size under zero is refused here and not moved to the
    /// other side of its origin.
    public init?(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// A box from edges that already lie within the space and in order: those of boxes, and
    /// points of boxes, that the arithmetic below derives. [LAW:types-are-the-program]
    private init(left: Double, top: Double, right: Double, bottom: Double) {
        x = left
        y = top
        width = right - left
        height = bottom - top
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var right: Double { x + width }
    var bottom: Double { y + height }

    /// Where a press aimed at this box lands on average, and what a reading reports its
    /// point as. Derived rather than carried, so it cannot disagree with the box it came from.
    public var centre: ScreenPoint { ScreenPoint(within: x + width / 2, y + height / 2) }

    public var isEmpty: Bool { width == 0 || height == 0 }

    public var area: Double { width * height }

    /// Half-open, as a pixel grid is: a point on the right or bottom edge is in the box beside.
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x < right && point.y >= y && point.y < bottom
    }

    /// Whether all of `other` lies inside this box.
    public func contains(_ other: ScreenRect) -> Bool {
        other.x >= x && other.right <= right && other.y >= y && other.bottom <= bottom
    }

    /// The part two boxes share, or none when they share no area: apart, touching at an
    /// edge, or either empty. The one rule for whether two boxes meet, which `intersects`
    /// and `overlap` read. [LAW:single-enforcer]
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        let (left, top) = (max(x, other.x), max(y, other.y))
        let (far, low) = (min(right, other.right), min(bottom, other.bottom))
        guard left < far, top < low else { return nil }
        return ScreenRect(left: left, top: top, right: far, bottom: low)
    }

    /// Whether the two share any area, which is how a merged reading tells one thing seen
    /// twice from two things seen once.
    public func intersects(_ other: ScreenRect) -> Bool { intersection(other) != nil }

    /// The area two boxes share, zero when they share none.
    public func overlap(_ other: ScreenRect) -> Double { intersection(other)?.area ?? 0 }

    /// The smallest box holding both.
    public func union(_ other: ScreenRect) -> ScreenRect {
        ScreenRect(left: min(x, other.x), top: min(y, other.y), right: max(right, other.right), bottom: max(bottom, other.bottom))
    }

    /// The smallest box in whole points holding this one: rounded outward, as
    /// `CGRect.integral` rounds, so it still holds every point of this one, and a negative
    /// coordinate is not moved toward zero.
    public var integral: ScreenRect {
        ScreenRect(left: x.rounded(.down), top: y.rounded(.down), right: right.rounded(.up), bottom: bottom.rounded(.up))
    }

    /// The point of this box, its edges included, nearest `x, y`: the place itself when it
    /// is in the box. A NaN is near nothing, and a caller handing one in has a bug that is
    /// stopped here rather than becoming a point. [LAW:no-silent-failure]
    public func nearest(x px: Double, y py: Double) -> ScreenPoint {
        precondition(!px.isNaN && !py.isNaN, "no point of a box is nearest (\(px), \(py))")
        return ScreenPoint(within: min(max(px, x), right), min(max(py, y), bottom))
    }

    /// The box with these two points at opposite corners, in either order.
    public static func spanning(_ a: ScreenPoint, _ b: ScreenPoint) -> ScreenRect {
        ScreenRect(left: min(a.x, b.x), top: min(a.y, b.y), right: max(a.x, b.x), bottom: max(a.y, b.y))
    }

    /// The farthest from the origin any edge of a spelled box may be, in points. An app's
    /// claimed frame - a document's text area, taller than any screen - prints past it, and
    /// is refused when read back: a capture is cut in whole points.
    public static let limit = 1_000_000.0

    /// What a refusal names as the form wanted, which a reader of a box with its own
    /// minimum size goes on from.
    public static let spelling = "x,y,width,height in points, no edge past \(Int(limit))"

    /// `x,y,width,height` of `integral`: whole points, so what is printed still holds every
    /// point of what was found. The one spelling every box is printed in, and the one
    /// `init(spelled:)` reads. [LAW:one-source-of-truth]
    public var description: String {
        let whole = integral
        return [whole.x, whole.y, whole.width, whole.height].map(ScreenPoint.spelled).joined(separator: ",")
    }

    /// A box as `description` spells it, or none for anything that is not one within
    /// `limit`. [LAW:single-enforcer] Every command line and MCP server reads a box through
    /// here; a reader that needs more of a box than that, such as a size, asks it of the box.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              [x, y, x + w, y + h].allSatisfy({ abs($0) <= Self.limit })
        else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
}

extension ScreenPoint {
    /// A point from coordinates that already lie within the space: the points of boxes the
    /// geometry derives. [LAW:types-are-the-program]
    init(within x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}
