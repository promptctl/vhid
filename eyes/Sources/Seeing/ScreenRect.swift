import CoreGraphics
import ScreenSpace

/// What the readers do with a box in the one screen space: bridge it to CoreGraphics, cut,
/// compare and merge it, and convert into it from Vision's image space.
///
/// [LAW:types-are-the-program] The image-space conversion is the failure this file exists to
/// prevent. Vision hands back normalized boxes in image space with the origin at the
/// bottom-left; a display has a backing scale factor; a second display sits at its own
/// origin in the global space, which is often negative. A reader that misses the flip, or
/// the scale, or the display origin produces numbers that are still four plausible Doubles
/// in the right order of magnitude, and clicking one lands somewhere else entirely. Nothing
/// downstream can tell the two apart, so the conversion lives in one named place -
/// `fromImageSpace` - rather than being a step each reader is trusted to have remembered.
///
/// What that does and does not buy, stated plainly because the difference is where a bug
/// would live: there is exactly one *conversion* from image space, so there is one
/// implementation to get right and one to test. There is not a locked door. `ScreenRect`'s
/// init is public and a reader that skips the conversion can hand it an unflipped Vision
/// box and get four plausible Doubles. That is a review boundary rather than a compiler one,
/// and calling it a compiler one would be the comment lying about the code.
public extension ScreenRect {
    /// A CoreGraphics rectangle in global, top-left, point coordinates - which the
    /// accessibility tree and the window server answer in, and pixels do not - or none for
    /// one that is no place: CGRect's null, or a frame an app claims that is not finite.
    init?(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// The part two boxes share, or none when they do not meet.
    func intersection(_ other: ScreenRect) -> ScreenRect? { ScreenRect(cgRect.intersection(other.cgRect)) }

    /// Whether any part of the two overlap, which is how a merged reading tells one thing
    /// seen twice from two things seen once.
    func intersects(_ other: ScreenRect) -> Bool {
        x < other.x + other.width && other.x < x + width
            && y < other.y + other.height && other.y < y + height
    }

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
    internal func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(y + height, other.y + other.height),
            along: max(0, max(x, other.x) - min(x + width, other.x + other.width)),
            leads: x < other.x)
    }

    var area: Double { width * height }

    /// The area two rectangles share, zero when they do not meet - beside `intersects`, so
    /// the two cannot disagree about what touching means.
    func overlap(_ other: ScreenRect) -> Double {
        guard intersects(other), let shared = intersection(other) else { return 0 }
        return shared.area
    }

    /// The one conversion from image space into screen space, and the only place the flip
    /// and the display origin are applied. [LAW:single-enforcer] One implementation to
    /// get right and one to test, rather than one per reader - see this file's header for
    /// what this enforces and what it only encourages.
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized
    /// box is a fraction of the image, and the same fraction of the display's point size,
    /// so the pixels divide out before anything here runs: a 2x capture and a 1x capture
    /// of the same screen produce the same answer. The scale can only be gotten wrong by
    /// a reader that converts to pixels first, which is why nothing here takes a pixel
    /// size - a value nobody passes is a value nobody can pass wrongly.
    /// [LAW:types-are-the-program]
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - display: where the captured display sits in the global space, top-left origin,
    ///     in points. Often at a negative origin when it is not the main one.
    static func fromImageSpace(normalized: CGRect, on display: ScreenRect) -> ScreenRect {
        let left = display.x + normalized.origin.x * display.width
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        let top = display.y + (1 - normalized.origin.y - normalized.height) * display.height
        // A unit box on a finite display is a finite box with a size, so none is refused.
        return ScreenRect(
            x: left,
            y: top,
            width: normalized.width * display.width,
            height: normalized.height * display.height
        )!
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

/// The space between two rectangles, ordered across lines first. See `ScreenRect.gap`.
struct Gap: Comparable {
    let across: Double
    let along: Double
    let leads: Bool

    static func < (a: Gap, b: Gap) -> Bool { (a.across, a.along, a.leads ? 1 : 0) < (b.across, b.along, b.leads ? 1 : 0) }
}
