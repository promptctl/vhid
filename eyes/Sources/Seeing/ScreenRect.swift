import CoreGraphics
import ScreenSpace

/// The readers' geometry on ScreenSpace's box: what only reading needs - how close two rows
/// are, how much they share, and the one conversion from a capture's image space.
public extension ScreenRect {
    /// A frame a system API answered as a `CGRect`, through the one crossing every box is
    /// made by. [LAW:single-enforcer]
    init(_ rect: CGRect) throws(NotABox) {
        try self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Whether every point of `other` is in this box, by `contains`' half-open rule: measured
    /// from the corner, so no far edge is summed.
    func holds(_ other: ScreenRect) -> Bool {
        other.x >= x && other.y >= y && other.x - x + other.width <= width && other.y - y + other.height <= height
    }

    /// The area two boxes share, zero when they do not meet - from `intersection`, so the
    /// two cannot disagree about what touching means.
    func overlap(_ other: ScreenRect) -> Double { intersection(other)?.area ?? 0 }

    /// The one conversion from image space into screen space, and the only place the flip
    /// and the display origin are applied. [LAW:single-enforcer] Vision hands back
    /// normalized boxes with the origin at the bottom-left, and a reader that missed the flip
    /// or the display origin would produce four plausible numbers that press somewhere else.
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized
    /// box is a fraction of the image, and the same fraction of the display's point size,
    /// so the pixels divide out before anything here runs: a 2x capture and a 1x capture
    /// of the same screen produce the same answer. Nothing here takes a pixel size - a value
    /// nobody passes is a value nobody can pass wrongly. [LAW:types-are-the-program]
    ///
    /// Refused when Vision's numbers make no box - one not finite, or a side under zero.
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - display: where the captured piece sits in the global space, top-left origin,
    ///     in points.
    static func fromImageSpace(normalized: CGRect, on display: ScreenRect) throws(NotABox) -> ScreenRect {
        let left = display.x + normalized.origin.x * display.width
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        let top = display.y + (1 - normalized.origin.y - normalized.height) * display.height
        return try ScreenRect(x: left, y: top, width: normalized.width * display.width, height: normalized.height * display.height)
    }

    /// The inverse of `fromImageSpace`: where this box sits in an image of `display`, as a
    /// unit rectangle with the origin at the bottom-left - the space Vision's region of
    /// interest is given in. Beside its inverse so the flip is written in one file and
    /// tested as a round trip. [LAW:single-enforcer]
    func normalized(in display: ScreenRect) -> CGRect {
        CGRect(
            x: (x - display.x) / display.width,
            y: 1 - (y - display.y + height) / display.height,
            width: width / display.width,
            height: height / display.height
        )
    }

    /// How far this box sits from `other`, the space between their edges: across lines
    /// first, then along one, then whether it starts before `other` does. So a button in a
    /// row is nearer the row's own text than the rows above and below it, however wide the
    /// row; a field is nearer the label just above it than one a line further down; and of
    /// two links touching one label, the one after it is nearer, as a label comes before what
    /// it names in left-to-right reading - measured in Safari, whose " · Pricing " run
    /// touches the "More" before it and the one after.
    ///
    /// Across is negative where the two share lines, by how much they share: rows packed
    /// edge to edge touch the row above as well as their own, and the row's own shares more.
    internal func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(y + height, other.y + other.height),
            along: max(0, max(x, other.x) - min(x + width, other.x + other.width)),
            leads: x < other.x)
    }
}

/// The space between two boxes, ordered across lines first. See `ScreenRect.gap`.
struct Gap: Comparable {
    let across: Double
    let along: Double
    let leads: Bool

    static func < (a: Gap, b: Gap) -> Bool { (a.across, a.along, a.leads ? 1 : 0) < (b.across, b.along, b.leads ? 1 : 0) }
}
