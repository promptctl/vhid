import CoreGraphics

/// A rectangle in the one coordinate space every reader answers in: global screen
/// coordinates, top-left origin, points.
///
/// [LAW:types-are-the-program] A named type rather than a bare `CGRect`, because the
/// failure this exists to prevent is one a `CGRect` cannot be checked for. Vision hands
/// back normalized boxes in image space with the origin at the bottom-left; a display has
/// a backing scale factor; a second display sits at its own origin in the global space,
/// which is often negative. A reader that misses the flip, or the scale, or the display
/// origin produces numbers that are still four plausible Doubles in the right order of
/// magnitude, and clicking one lands somewhere else entirely. Nothing downstream can tell
/// the two apart, so the conversion lives in one named place - `fromImageSpace` - rather
/// than being a step each reader is trusted to have remembered.
///
/// What that does and does not buy, stated plainly because the difference is where a bug
/// would live: there is exactly one *conversion* from image space, so there is one
/// implementation to get right and one to test. There is not a locked door. The
/// memberwise `init` below is public and a reader that skips the conversion can hand it
/// an unflipped Vision box and get four plausible Doubles. No type can prevent a producer
/// from supplying wrong numbers in the right shape; what a type can do is make the right
/// way the short way, and make the wrong way visible as a reader that names image-space
/// values without calling the conversion. That is a review boundary rather than a
/// compiler one, and calling it a compiler one would be the comment lying about the code.
///
/// The space is not a choice made here. It is the space `vhid click` consumes and the
/// space the accessibility tree already answers in, so the centre of one of these is a
/// click's target with no conversion at all. [LAW:one-source-of-truth]
public struct ScreenRect: Sendable, Hashable {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD. This is the axis that gets flipped by mistake.
    public let y: Double
    public let width: Double
    public let height: Double

    /// For a reader that already holds global, top-left, point coordinates - which the
    /// accessibility tree does, and pixels do not.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Where a caller clicks to hit this, which is the only reason any of this is
    /// measured. [LAW:one-source-of-truth] Derived rather than carried, so it cannot
    /// disagree with the rectangle it came from.
    public var centre: ScreenPoint { ScreenPoint(x: x + width / 2, y: y + height / 2) }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// Whether any part of the two overlap, which is how a merged reading tells one thing
    /// seen twice from two things seen once.
    public func intersects(_ other: ScreenRect) -> Bool {
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
    func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(y + height, other.y + other.height),
            along: max(0, max(x, other.x) - min(x + width, other.x + other.width)),
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

/// A point in the same space, top-left origin, points.
public struct ScreenPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public extension ScreenRect {
    /// The one conversion from image space into screen space, and the only place the flip
    /// and the display origin are applied. [LAW:single-enforcer] One implementation to
    /// get right and one to test, rather than one per reader - see the type's header for
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
        return ScreenRect(
            x: left,
            y: top,
            width: normalized.width * display.width,
            height: normalized.height * display.height
        )
    }
}

public extension ScreenRect {
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

/// `x,y,width,height` in whole points: the one spelling every rectangle `eyes` prints in
/// and the one `rect` reads, so anything printed as a rectangle can be read back as one.
/// [LAW:one-source-of-truth]
extension ScreenRect: CustomStringConvertible {
    /// What a refusal names as the form wanted.
    public static let spelling = "x,y,width,height in points - a positive size, nothing past a million"

    /// The smallest whole-point rectangle covering this one: rounded outward, as
    /// `CGRect.integral` rounds, so what is printed still holds every point of what was
    /// found, and a negative coordinate is not moved toward zero.
    public var description: String {
        let r = cgRect.integral
        return "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
    }

    /// A rectangle as `description` spells it, or none for anything that is not one.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              [x, y, w, h].allSatisfy({ abs($0) <= 1_000_000 }), w > 0, h > 0
        else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
}

public extension ScreenRect {
    var area: Double { width * height }

    /// The area two rectangles share, zero when they do not meet - beside `intersects`, so
    /// the two cannot disagree about what touching means.
    func overlap(_ other: ScreenRect) -> Double {
        guard intersects(other) else { return 0 }
        return cgRect.intersection(other.cgRect).width * cgRect.intersection(other.cgRect).height
    }
}
