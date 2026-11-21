/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points, stored exactly as given.
///
/// [LAW:types-are-the-program] Four finite numbers with no side under zero is the strongest
/// theorem true of every frame the accessibility tree, the window server and Vision report.
/// There is no bound on how far a box reaches: an app claims a document's frame 1e20 points
/// wide, and a reader keeps it as it is. Where on the displays a box is pressed is
/// `Displays.place`'s to say, never a clamp here.
///
/// Every operation below is Double arithmetic on the four numbers, and its result type says
/// whether it can fail on finite input: a far edge is never formed where its sum could pass
/// what a Double holds, so `contains` and `intersection` cannot, and `union` and `centre` can.
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
        guard [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else {
            throw NotABox(x: x, y: y, width: width, height: height)
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Four numbers this file has already shown are a box.
    init(finite box: (x: Double, y: Double, width: Double, height: Double)) {
        (x, y, width, height) = box
    }

    /// A box as `x,y,width,height` spells it, or nil for text that is not four numbers making
    /// one. [LAW:single-enforcer] The command line and the MCP server both read a box here.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false).map { Double(String($0.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3],
              let box = try? ScreenRect(x: x, y: y, width: width, height: height)
        else { return nil }
        self = box
    }

    /// What a refusal names as the form wanted.
    public static let spelling = "x,y,width,height in points, no side under zero"

    /// Whether the box holds no point: a side of zero, by `contains`' rule.
    public var isEmpty: Bool { width == 0 || height == 0 }

    public var area: Double { width * height }

    /// Half-open: the left and top edges are in the box, the right and bottom are not, so two
    /// boxes edge to edge never both hold a point. The rule every point of a box answered
    /// below keeps to. Measured from the corner, so no far edge is summed.
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x - x < width && point.y >= y && point.y - y < height
    }

    /// The box both hold, nil when they share no area. Each side is taken from the nearer
    /// edge's distance into each box, which a Double always holds: two boxes too far apart for
    /// their gap to be one share nothing.
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        let (left, top) = (max(x, other.x), max(y, other.y))
        let width = min(width - (left - x), other.width - (left - other.x))
        let height = min(height - (top - y), other.height - (top - other.y))
        guard width > 0, height > 0 else { return nil }
        return ScreenRect(finite: (left, top, width, height))
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

    /// The point at the middle, refused when the box reaches past what a Double holds.
    public var centre: ScreenPoint {
        get throws(NotAPlace) { try ScreenPoint(x: x + width / 2, y: y + height / 2) }
    }

    /// The smallest box of whole points holding this one: rounded out, so it holds every point
    /// of this one, and a negative coordinate is not moved toward zero. Refused when its far
    /// edge is past what a Double holds.
    public var integral: ScreenRect {
        get throws(NotABox) {
            let (left, top, width, height) = outward
            return try ScreenRect(x: left, y: top, width: width, height: height)
        }
    }

    private var outward: (x: Double, y: Double, width: Double, height: Double) {
        let (left, top) = (x.rounded(.down), y.rounded(.down))
        return (left, top, (x + width).rounded(.up) - left, (y + height).rounded(.up) - top)
    }

    /// `integral` as `x,y,width,height`, so what is printed holds every point of what was
    /// found. [LAW:one-source-of-truth] The one spelling of a box, which `init(spelled:)`
    /// reads back.
    public var description: String {
        let (left, top, width, height) = outward
        return [left, top, width, height].map(Coordinate.spelled).joined(separator: ",")
    }
}

/// Four numbers that are not a box: one is not finite, or a side is under zero.
public struct NotABox: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var description: String {
        [x, y, width, height].map(Coordinate.spelled).joined(separator: ",") + " is not a box on the screen: a number is not finite, or a side is under zero"
    }
}
