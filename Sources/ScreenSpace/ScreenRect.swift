import CoreGraphics

/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points, each stored exactly as given.
///
/// [LAW:types-are-the-program] Four finite numbers with no side under zero, and its far
/// edges finite: the strongest theorem true of every frame the accessibility tree, the
/// window server and Vision report. Apps claim document frames 1e20 points wide and a
/// window or a Vision box can have no area, so any tighter bound would refuse frames that
/// are real. What a box is for adds its own rule where that use parses it: a press needs a
/// box a point a side, `Target.Box`; a capture needs area and a size it can cut.
///
/// The geometry is Double arithmetic on the numbers as given, one axis at a time, never a
/// round trip through `CGRect`: in floating point `(x + w) - x` is not `w`, so a size is
/// never rebuilt from edges where one was given, and each operation's result type says
/// whether it can fail on finite input.
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box: refused when a
    /// number is not finite, a far edge is not, or a side is under zero.
    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard let across = Span(x, width), let down = Span(y, height) else { return nil }
        self.init(across, down)
    }

    /// A `CGRect` read as given, origin and size, never standardized: a frame claiming a
    /// negative size is no box, not a box somewhere else.
    public init?(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    init(_ across: Span, _ down: Span) {
        (x, width, y, height) = (across.origin, across.length, down.origin, down.length)
    }

    var across: Span { Span(finite: x, width) }
    var down: Span { Span(finite: y, height) }

    public var maxX: Double { across.end }
    public var maxY: Double { down.end }

    /// A box with no area: a side of zero.
    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Infinite for a box too large for its area to be a Double, which still compares
    /// above every finite one.
    public var area: Double { width * height }

    /// Total: `x + w/2` lies between `x` and `x + w`, both finite.
    public var centre: ScreenPoint { ScreenPoint(finite: x + width / 2, y + height / 2) }

    /// Half-open, as every answer of a point of a box is: the left and top edges are in the
    /// box, the right and bottom edges are in the next one.
    public func contains(_ point: ScreenPoint) -> Bool {
        across.holds(point.x) && down.holds(point.y)
    }

    /// Whether `other` lies wholly inside this box, edges included.
    public func contains(_ other: ScreenRect) -> Bool {
        across.covers(other.across) && down.covers(other.down)
    }

    /// The part two boxes share: a sub-box of both, built from their own numbers, so it
    /// cannot fail. None exactly when they share no area - boxes that touch at an edge share
    /// none.
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        guard let across = across.shared(with: other.across), let down = down.shared(with: other.down) else { return nil }
        return ScreenRect(across, down)
    }

    /// Whether the two share any area. [LAW:one-source-of-truth] Derived from `intersection`,
    /// so the two cannot disagree about what meeting means.
    public func intersects(_ other: ScreenRect) -> Bool { intersection(other) != nil }

    /// The area the two share, zero when they share none.
    public func overlap(_ other: ScreenRect) -> Double { intersection(other)?.area ?? 0 }

    /// The smallest box holding both, or none when its span is past what a Double holds.
    public func union(_ other: ScreenRect) -> ScreenRect? {
        guard let across = across.spanning(other.across), let down = down.spanning(other.down) else { return nil }
        return ScreenRect(across, down)
    }

    /// The smallest box of whole points holding this one: each origin rounded down, each
    /// size rounded up past it. Total: a whole origin keeps its size rounded up, and the far
    /// edge moves out by under two points, which no finite edge rounds past the largest
    /// Double by.
    public var integral: ScreenRect { ScreenRect(across.integral, down.integral) }

    /// The point of this box nearest `place`, by `contains`' half-open rule: none for a box
    /// that holds no point, one with no area or too far out for a Double to step inside it.
    public func nearest(to place: ScreenPoint) -> ScreenPoint? {
        guard let x = across.nearest(to: place.x), let y = down.nearest(to: place.y) else { return nil }
        return ScreenPoint(finite: x, y)
    }

    /// What a refusal names as the form a box is read in.
    public static let spelling = "x,y,width,height in whole points"

    /// `x,y,width,height`: the box rounded out to whole points, so what is printed still
    /// holds every point of what was found and reads back through `init?(spelled:)`.
    public var description: String {
        let whole = integral
        return [whole.x, whole.y, whole.width, whole.height].map(\.positional).joined(separator: ",")
    }

    /// A box as `description` spells it, and nothing more: four whole numbers, each in
    /// figures with an optional minus, then the rule every box is held to.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            (part.first == "-" ? part.dropFirst() : part).allSatisfy(\.isASCIIDigit) ? Double(part) : nil
        }
        guard parts.count == 4, numbers.count == 4 else { return nil }
        self.init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// One axis of a box: where it starts and how long it is, as given.
struct Span: Hashable {
    let origin: Double
    let length: Double

    init?(_ origin: Double, _ length: Double) {
        guard origin.isFinite, length.isFinite, length >= 0, (origin + length).isFinite else { return nil }
        self.init(finite: origin, length)
    }

    init(finite origin: Double, _ length: Double) {
        self.origin = origin
        self.length = length
    }

    var end: Double { origin + length }

    func holds(_ value: Double) -> Bool { value >= origin && value < end }

    func covers(_ other: Span) -> Bool { other.origin >= origin && other.end <= end }

    /// The stretch both cover. When one span lies within the other it is that span, as
    /// given; otherwise it starts where the later one starts and runs to where the earlier
    /// one ends, no longer than either, which is what the exact difference is and what keeps
    /// a rounded one finite.
    func shared(with other: Span) -> Span? {
        let later = origin >= other.origin ? self : other
        let earlier = end <= other.end ? self : other
        let length = later == earlier ? later.length : min(earlier.end - later.origin, later.length, earlier.length)
        return length > 0 ? Span(finite: later.origin, length) : nil
    }

    /// The stretch covering both: the one that covers the other, as given, or from the first
    /// start to the last end, when that is a span.
    func spanning(_ other: Span) -> Span? {
        let first = origin <= other.origin ? self : other
        let last = end >= other.end ? self : other
        return first == last ? first : Span(first.origin, last.end - first.origin)
    }

    var integral: Span {
        let start = origin.rounded(.down)
        // Exact: a double less its own floor loses no digits.
        return Span(finite: start, (length + (origin - start)).rounded(.up))
    }

    func nearest(to value: Double) -> Double? {
        let last = end.nextDown
        return last >= origin ? min(max(value, origin), last) : nil
    }
}
