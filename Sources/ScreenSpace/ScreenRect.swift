/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points, stored exactly as given.
///
/// [LAW:types-are-the-program] Finite numbers with no side under zero, and far edges a Double
/// holds, is the strongest theorem true of every frame the accessibility tree, the window
/// server and Vision report. A box whose far edge no Double holds has no far edge, so it is no
/// box; that is the arithmetic's own limit, not a bound on how far a box reaches: an app
/// claims a document's frame 1e20 points wide, and a reader keeps it as it is. Where on the
/// displays a box is pressed is `Displays.place`'s to say, never a clamp here.
///
/// Every operation below is Double arithmetic on the four numbers, and its result type says
/// whether it can fail: each edge and the middle lie between two finite edges, so `contains`,
/// `intersection` and `centre` cannot; a size summed from two boxes' edges, or rounded out to
/// whole points, can pass what a Double holds, so `union` and `integral` can.
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    /// Leftmost point, increasing to the right.
    public let x: Double
    /// Topmost point, increasing downward.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box, and the one place
    /// four that are not one are refused.
    public init(x: Double, y: Double, width: Double, height: Double) throws(NotABox) {
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite), width >= 0, height >= 0 else {
            throw NotABox(x: x, y: y, width: width, height: height)
        }
        self.init(edges: (x, y, width, height))
    }

    /// Four numbers the theorem already holds of: a part of a box this file has cut, whose
    /// edges lie between that box's.
    private init(edges box: (x: Double, y: Double, width: Double, height: Double)) {
        (x, y, width, height) = box
    }

    /// A box as `x,y,width,height` spells it. [LAW:single-enforcer] The command line and the
    /// MCP server both read a box here, and say why a spelling is not one by the same words.
    public init(spelled: String) throws(Misspelled) {
        let numbers = try Coordinate.numbers(spelled, count: 4, of: Self.spelling)
        do {
            try self.init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        } catch {
            throw .notABox(spelled, error)
        }
    }

    /// What a refusal names as the form wanted.
    public static let spelling = "x,y,width,height in points, no side under zero"

    /// Whether the box holds no point: a side of zero, by `contains`' rule.
    public var isEmpty: Bool { width == 0 || height == 0 }

    public var area: Double { width * height }

    /// Half-open: the left and top edges are in the box, the right and bottom are not, so two
    /// boxes edge to edge never both hold a point. The rule every point of a box answered
    /// below keeps to.
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x - x < width && point.y >= y && point.y - y < height
    }

    /// The box both hold, nil when they share no area. Each side is taken from the nearer
    /// edge's distance into each box, so the part's edges lie between each box's own.
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        let (left, top) = (max(x, other.x), max(y, other.y))
        let width = min(width - (left - x), other.width - (left - other.x))
        let height = min(height - (top - y), other.height - (top - other.y))
        guard width > 0, height > 0 else { return nil }
        return ScreenRect(edges: (left, top, width, height))
    }

    /// Whether the two share any area.
    public func intersects(_ other: ScreenRect) -> Bool { intersection(other) != nil }

    /// The smallest box holding both, refused when its size is past what a Double holds.
    public func union(_ other: ScreenRect) throws(NotABox) -> ScreenRect {
        let (left, top) = (min(x, other.x), min(y, other.y))
        let width = max(x + width, other.x + other.width) - left
        let height = max(y + height, other.y + other.height) - top
        return try ScreenRect(x: left, y: top, width: width, height: height)
    }

    /// The point at the middle, which lies between the box's finite edges.
    public var centre: ScreenPoint { ScreenPoint(between: (x + width / 2, y + height / 2)) }

    /// The smallest box of whole points holding this one: rounded out, so it holds every point
    /// of this one, and a negative coordinate is not moved toward zero. Refused when the
    /// rounded size is past what a Double holds.
    public var integral: ScreenRect {
        get throws(NotABox) {
            let (left, top) = (x.rounded(.down), y.rounded(.down))
            return try ScreenRect(x: left, y: top, width: (x + width).rounded(.up) - left, height: (y + height).rounded(.up) - top)
        }
    }

    /// `x,y,width,height`, each number as given. [LAW:one-source-of-truth] The one spelling of
    /// a box, which `init(spelled:)` reads back as this box.
    public var description: String {
        [x, y, width, height].map(Coordinate.spelled).joined(separator: ",")
    }
}

/// Four numbers that are not a box: one is not finite, a side is under zero, or a far edge is
/// past what a Double holds.
public struct NotABox: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var description: String {
        [x, y, width, height].map(Coordinate.spelled).joined(separator: ",")
            + " is not a box on the screen: a number is not finite, a side is under zero, or a far edge is past what a Double holds"
    }
}
