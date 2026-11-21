import CoreGraphics
// Seeing's vocabulary is said in ScreenSpace's points and boxes, so whatever speaks Seeing
// speaks those too. [LAW:one-source-of-truth]
@_exported import ScreenSpace

public extension ScreenRect {
    /// The one conversion from image space into screen space, and the only place the flip
    /// and the display origin are applied. [LAW:single-enforcer] Vision hands back
    /// normalized boxes in image space with the origin at the bottom-left; a reader that
    /// missed the flip or the display origin would produce four plausible numbers that
    /// press somewhere else entirely, so the conversion lives here rather than being a step
    /// each reader is trusted to have remembered. It is a review boundary, not a compiler
    /// one: `ScreenRect`'s own init takes any four numbers that are a box.
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized
    /// box is a fraction of the image, and the same fraction of the display's point size,
    /// so the pixels divide out before anything here runs: a 2x capture and a 1x capture
    /// of the same screen produce the same answer. [LAW:types-are-the-program]
    ///
    /// None for a box that is no place - a size under zero, or a number that is not
    /// finite - which is no box, not one somewhere else.
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - display: where the captured display sits in the global space, top-left origin,
    ///     in points. Often at a negative origin when it is not the main one.
    static func fromImageSpace(normalized: CGRect, on display: ScreenRect) -> ScreenRect? {
        // Its size as given: `CGRect.width` and `height` are standardized, and would read a
        // box claiming a negative size as one reaching back the other way.
        let size = normalized.size
        let left = display.x + normalized.origin.x * display.width
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        let top = display.y + (1 - normalized.origin.y - size.height) * display.height
        return ScreenRect(x: left, y: top, width: size.width * display.width, height: size.height * display.height)
    }

    /// The inverse of `fromImageSpace`: where this rectangle sits in an image of `display`,
    /// as a unit rectangle with the origin at the bottom-left - the space Vision's region
    /// of interest is given in. Beside its inverse so the flip is written in one file and
    /// tested as a round trip. [LAW:single-enforcer]
    func normalized(in display: ScreenRect) -> CGRect {
        CGRect(
            x: (x - display.x) / display.width,
            y: 1 - (y - display.y + height) / display.height,
            width: width / display.width,
            height: height / display.height
        )
    }
}

extension ScreenRect {
    /// How far this rectangle sits from `other`, the space between their edges: across
    /// lines first, then along one, then whether it starts before `other` does. So a
    /// button in a row is nearer the row's own text than the rows above and below it,
    /// however wide the row; a field is nearer the label just above it than one a line
    /// further down; and of two links touching one label, the one after it is nearer, as
    /// a label comes before what it names in left-to-right reading - measured in Safari,
    /// whose " · Pricing " run touches the "More" before it and the one after.
    ///
    /// Across is negative where the two share lines, by how much they share: rows packed
    /// edge to edge touch the row above as well as their own, and the row's own shares more.
    func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(maxY, other.maxY),
            along: max(0, max(x, other.x) - min(maxX, other.maxX)),
            leads: x < other.x)
    }
}

/// The space between two rectangles, ordered across lines first. See `ScreenRect.gap`.
struct Gap: Comparable {
    let across: Double
    let along: Double
    let leads: Bool

    static func < (a: Gap, b: Gap) -> Bool { (a.across, a.along, a.leads ? 1 : 0) < (b.across, b.along, b.leads ? 1 : 0) }
}
