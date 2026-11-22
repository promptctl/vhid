import CoreGraphics
import ScreenSpace

/// What only the readers ask of a box: whether two meet, how far apart they sit, and the one
/// conversion from a captured image's space. The box itself, its spelling and where it is
/// pressed are ScreenSpace's, which both halves speak. [LAW:decomposition]
public extension ScreenRect {
    /// Whether the two share any area, which is how a merged reading tells one thing seen
    /// twice from two things seen once.
    func intersects(_ other: ScreenRect) -> Bool { intersection(other) != nil }

    /// The area two boxes share, zero when they do not meet - on `intersection`, so the two
    /// cannot disagree about what touching means.
    func overlap(_ other: ScreenRect) -> Double { intersection(other)?.area ?? 0 }

    /// How far this box sits from `other`, the space between their edges: across lines
    /// first, then along one, then whether it starts before `other` does. So a button in a
    /// row is nearer the row's own text than the rows above and below it, however wide the
    /// row; a field is nearer the label just above it than one a line further down; and of
    /// two links touching one label, the one after it is nearer, as a label comes before
    /// what it names in left-to-right reading - measured in Safari, whose " · Pricing " run
    /// touches the "More" before it and the one after.
    ///
    /// Across is negative where the two share lines, by how much they share: rows packed
    /// edge to edge touch the row above as well as their own, and the row's own shares more.
    internal func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(maxY, other.maxY),
            along: max(0, max(x, other.x) - min(maxX, other.maxX)),
            leads: x < other.x)
    }

    /// The one conversion from image space into screen space; it and its inverse,
    /// `normalized(in:)`, below it, are the only places the flip and the capture's origin
    /// are applied. [LAW:single-enforcer]
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized
    /// box is a fraction of the image, and the same fraction of the captured rectangle's
    /// point size, so the pixels divide out before anything here runs: a 2x capture and a
    /// 1x capture of the same screen produce the same answer. A value nobody passes is a
    /// value nobody can pass wrongly. [LAW:types-are-the-program]
    ///
    /// Refused, by name, when Vision's fractions make no box: one that is not a number, or
    /// a side under zero. [LAW:no-silent-failure]
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - capture: where the captured rectangle sits in the global space, top-left origin,
    ///     in points. Often at a negative origin on a display that is not the main one.
    static func fromImageSpace(normalized: CGRect, on capture: ScreenRect) throws(NotABox) -> ScreenRect {
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        try ScreenRect(x: capture.x + normalized.origin.x * capture.width,
                       y: capture.y + (1 - normalized.origin.y - normalized.height) * capture.height,
                       width: normalized.width * capture.width,
                       height: normalized.height * capture.height)
    }

    /// The inverse of `fromImageSpace`: where this box sits in an image of `capture`, as a
    /// unit rectangle with the origin at the bottom-left - the space Vision's region of
    /// interest is given in. Beside its inverse so the flip is written in one file and
    /// tested as a round trip. [LAW:single-enforcer]
    func normalized(in capture: ScreenRect) -> CGRect {
        CGRect(x: (x - capture.x) / capture.width,
               y: 1 - (y - capture.y + height) / capture.height,
               width: width / capture.width,
               height: height / capture.height)
    }
}

/// The space between two boxes, ordered across lines first. See `ScreenRect.gap`.
struct Gap: Comparable {
    let across: Double
    let along: Double
    let leads: Bool

    static func < (a: Gap, b: Gap) -> Bool { (a.across, a.along, a.leads ? 1 : 0) < (b.across, b.along, b.leads ? 1 : 0) }
}
