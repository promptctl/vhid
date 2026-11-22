import CoreGraphics

/// A box in `ScreenPoint`'s space: its top-left corner, then its size, in points.
///
/// **Stored as given.** An app may claim a frame 1e20 points wide - a document's text area,
/// taller than any screen - and a box keeps it, since the frame is what finds the element
/// again; where a box is pressed is `Displays.place`'s to say, not the box's. So no constant
/// bounds a coordinate here. What a box refuses is what no arithmetic on it could hold.
/// [LAW:types-are-the-program]
///
/// Geometry sits beside the type, as Double arithmetic with the half-open rule `contains`
/// uses, and each operation's result says whether it can fail on finite input: `centre` and
/// `integral` cannot, `intersection` has nothing to answer when no area is shared, and
/// `union` can run past what a Double holds.
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box, and the one place
    /// four that are not one are refused: a number that is not finite, a side under zero, or
    /// a far edge past what a Double holds, which every question about the box would read as
    /// an infinity. An empty box - a side of zero - is a box: windows and Vision answer them.
    public init(x: Double, y: Double, width: Double, height: Double) throws(NotABox) {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { throw NotABox(x: x, y: y, width: width, height: height, why: .notFinite) }
        guard width >= 0, height >= 0 else { throw NotABox(x: x, y: y, width: width, height: height, why: .negativeSide) }
        guard (x + width).isFinite, (y + height).isFinite else { throw NotABox(x: x, y: y, width: width, height: height, why: .farEdge) }
        self.init(finite: x, y, width, height)
    }

    /// For arithmetic whose result is a box by construction. Not public, for the reason
    /// `ScreenPoint.init(finite:_:)` is not.
    init(finite x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) throws(NotABox) {
        try self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// The right edge and the bottom edge, which the crossing proved finite.
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public var isEmpty: Bool { width == 0 || height == 0 }

    public var area: Double { width * height }

    /// The middle of the box: between its edges, so finite whenever they are.
    public var centre: ScreenPoint { ScreenPoint(finite: x + width / 2, y + height / 2) }

    /// Whether a point is in the box, half-open: the left and top edges in, the right and
    /// bottom out, so two boxes edge to edge never both hold one point.
    public func contains(_ point: ScreenPoint) -> Bool { contains(x: point.x, y: point.y) }

    /// The same, on two coordinates the caller has not made a point of: a corner of a square
    /// about a point, which a non-finite one is simply not in.
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// The area the two share, or nil when they share none: two boxes edge to edge share an
    /// edge and no area.
    ///
    /// On each axis, a box that gives both of the shared edges gives its own side, as given:
    /// a box cut on one axis alone keeps the other side exactly, where `right - left` would
    /// say 9.999999999999998 for a side of 10 at 10.9. [LAW:one-source-of-truth]
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        guard let across = Self.shared((x, width, maxX), (other.x, other.width, other.maxX)),
              let down = Self.shared((y, height, maxY), (other.y, other.height, other.maxY)) else { return nil }
        return ScreenRect(finite: across.start, down.start, across.length, down.length)
    }

    /// What two spans on one axis share, each as its start, its length and its end: nil
    /// when they share no length.
    private static func shared(_ a: (start: Double, length: Double, end: Double), _ b: (start: Double, length: Double, end: Double)) -> (start: Double, length: Double)? {
        let (start, end) = (max(a.start, b.start), min(a.end, b.end))
        guard end > start else { return nil }
        if start == a.start, end == a.end { return (start, a.length) }
        if start == b.start, end == b.end { return (start, b.length) }
        return (start, end - start)
    }

    /// The smallest box holding both, refused when it is wider or taller than a Double holds.
    ///
    /// On each axis, a box that gives both of the outer edges gives its own side, as given,
    /// as `intersection` keeps one. [LAW:one-source-of-truth]
    public func union(_ other: ScreenRect) throws(NotABox) -> ScreenRect {
        let across = Self.spanned((x, width, maxX), (other.x, other.width, other.maxX))
        let down = Self.spanned((y, height, maxY), (other.y, other.height, other.maxY))
        return try ScreenRect(x: across.start, y: down.start, width: across.length, height: down.length)
    }

    /// The span on one axis holding both, as its start and its length.
    private static func spanned(_ a: (start: Double, length: Double, end: Double), _ b: (start: Double, length: Double, end: Double)) -> (start: Double, length: Double) {
        let (start, end) = (min(a.start, b.start), max(a.end, b.end))
        if start == a.start, end == a.end { return (start, a.length) }
        if start == b.start, end == b.end { return (start, b.length) }
        return (start, end - start)
    }

    /// The smallest box of whole points holding this one: rounded outward, as
    /// `CGRect.integral` rounds, so a negative coordinate is not moved toward zero. Its far
    /// edges are whole numbers no further out than a point past finite ones, so finite.
    public var integral: ScreenRect {
        let (left, top) = (x.rounded(.down), y.rounded(.down))
        return ScreenRect(finite: left, top, maxX.rounded(.up) - left, maxY.rounded(.up) - top)
    }

    /// `x,y,width,height`, each in `Coordinate.spelled`: the one text spelling of a box,
    /// printed as given, which `init(spelled:)` reads back as this box.
    public var description: String { [x, y, width, height].map(Coordinate.spelled).joined(separator: ",") }

    /// A box as `description` spells it. [LAW:single-enforcer] Every door that takes a box as
    /// text reads it here.
    public init(spelled: String) throws(Misspelled) {
        let numbers = try Coordinate.numbers(in: spelled, count: 4, form: Self.form)
        do {
            try self.init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        } catch {
            throw Misspelled(spelled, form: Self.form, because: error.description)
        }
    }

    /// What a refusal names as the form wanted.
    public static let form = "x,y,width,height in points"
}

/// Four numbers that are not a box, and which of the three things a box is they miss.
public struct NotABox: Error, Hashable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let why: Why

    public enum Why: Hashable, Sendable {
        case notFinite, negativeSide, farEdge
    }

    public var description: String {
        let numbers = [x, y, width, height].map { "\($0)" }.joined(separator: ",")
        return switch why {
        case .notFinite: "\(numbers) is not a box: each number must be finite"
        case .negativeSide: "\(numbers) is not a box: no side may be under zero"
        case .farEdge: "\(numbers) is not a box: its far edge is past what a Double holds"
        }
    }
}
