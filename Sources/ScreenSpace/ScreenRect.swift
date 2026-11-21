import CoreGraphics

/// A box in `ScreenPoint`'s space: its top-left corner, then its size, in points.
///
/// [LAW:types-are-the-program] The strongest theorem true of every frame the accessibility
/// tree, the window server and Vision report: four finite numbers, finite far edges, and no
/// side under zero, stored exactly as given. Nothing bounds how large it is - an app claims
/// a document frame 1e20 points wide, and that is a frame a reader keeps - so a box says
/// nothing of where the displays are. What the devices need of a place, that the cursor can
/// be there, only the display layout an act read knows, and the devices ask it.
public struct ScreenRect: Hashable, Sendable {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD. This is the axis that gets flipped by mistake.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four numbers become a box, and the one refusal
    /// of four that are not one.
    public init(x: Double, y: Double, width: Double, height: Double) throws(NotABox) {
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite), width >= 0, height >= 0 else {
            throw NotABox(x: x, y: y, width: width, height: height)
        }
        self.init(checked: x, y, width, height)
    }

    /// A rectangle as CoreGraphics gave it: origin and size read as given, never standardized,
    /// so a negative size is refused rather than turned round into another box.
    public init(_ rect: CGRect) throws(NotABox) {
        try self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// For the geometry here, whose every answer meets the rules above by its own construction.
    private init(checked x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The right edge: the first x past the box.
    public var maxX: Double { x + width }
    /// The bottom edge: the first y past the box.
    public var maxY: Double { y + height }

    /// Whether the box holds no point: a side of zero, as a window or a Vision box can have.
    public var isEmpty: Bool { width == 0 || height == 0 }

    public var area: Double { width * height }

    /// Where a caller clicks to hit this. Total: half a side from an edge lies between the two
    /// finite edges. [LAW:one-source-of-truth] Derived, so it cannot disagree with the box.
    public var centre: ScreenPoint { ScreenPoint(x + width / 2, y + height / 2) }

    /// Half-open, as CoreGraphics has it: the left and top edges in, the right and bottom out,
    /// so boxes edge to edge share no point.
    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    /// Whether every point of `box` is a point of this one.
    public func contains(_ box: ScreenRect) -> Bool {
        box.x >= x && box.maxX <= maxX && box.y >= y && box.maxY <= maxY
    }

    /// The part the two share, nil exactly when they share no area: boxes that only touch
    /// share an edge, which is no point of either. Total, since each edge it answers is an
    /// edge of one of the two.
    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        let (left, right) = (max(x, other.x), min(maxX, other.maxX))
        let (top, bottom) = (max(y, other.y), min(maxY, other.maxY))
        guard right > left, bottom > top else { return nil }
        return ScreenRect(checked: left, top, right - left, bottom - top)
    }

    /// Whether the two share any area - `intersection`'s answer, so the two cannot disagree
    /// about what touching means.
    public func intersects(_ other: ScreenRect) -> Bool { intersection(other) != nil }

    /// The area the two share, zero when they do not meet.
    public func overlap(_ other: ScreenRect) -> Double { intersection(other)?.area ?? 0 }

    /// The smallest box holding this one and every one of `others`: the one bounding-box rule,
    /// for a run's frame and a layout's extent. Nil when that box's span is past what a Double
    /// holds - two finite boxes can lie further apart than any number - which is the honest
    /// type of the answer. [LAW:types-are-the-program]
    public func union(_ others: some Sequence<ScreenRect>) -> ScreenRect? {
        let edges = others.reduce((left: x, top: y, right: maxX, bottom: maxY)) { edges, box in
            (min(edges.left, box.x), min(edges.top, box.y), max(edges.right, box.maxX), max(edges.bottom, box.maxY))
        }
        return try? ScreenRect(x: edges.left, y: edges.top, width: edges.right - edges.left, height: edges.bottom - edges.top)
    }

    public func union(_ other: ScreenRect) -> ScreenRect? { union([other]) }

    /// The point of this box nearest `(x, y)`: each axis held within the box, by the half-open
    /// rule `contains` uses, so the answer is a point the box contains. A box with no area
    /// contains no point, and answers its origin. Total: a coordinate that is not a number
    /// answers the box's nearest edge, as `Double.maximum` takes the number of a pair.
    public func nearest(_ px: Double, _ py: Double) -> ScreenPoint {
        guard !isEmpty else { return ScreenPoint(x, y) }
        return ScreenPoint(Double.minimum(Double.maximum(px, x), maxX.nextDown), Double.minimum(Double.maximum(py, y), maxY.nextDown))
    }

    /// The smallest box of whole points holding this one: its edges rounded outward, so a
    /// negative coordinate is not moved toward zero and every point of this box is one of it.
    public var integral: ScreenRect {
        let (left, top) = (x.rounded(.down), y.rounded(.down))
        // A side past 2^53 rounds when it is taken from its edges, and may round inward; it is
        // let out a step at a time until the box holds the edge it was taken from.
        var (width, height) = (maxX.rounded(.up) - left, maxY.rounded(.up) - top)
        while left + width < maxX { width = width.nextUp }
        while top + height < maxY { height = height.nextUp }
        return ScreenRect(checked: left, top, width, height)
    }
}

/// Four numbers that are not a box on the screen: one is not finite, a far edge is past what a
/// Double holds, or a side is under zero.
public struct NotABox: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var description: String {
        "\([x, y, width, height].map(Coordinate.spelled).joined(separator: ",")) is not a box on the screen"
    }
}

/// `x,y,width,height` in whole points: the one spelling every box is printed in and the one a
/// box is read back from, so a box printed for a place on a screen can be passed on as one.
/// [LAW:one-source-of-truth]
extension ScreenRect: CustomStringConvertible {
    /// What a refusal names as the form wanted.
    public static let spelling = "x,y,width,height in whole points, no side under zero"

    /// The box rounded out to whole points, each spelled as `Coordinate.spelled` spells it.
    public var description: String {
        let whole = integral
        return [whole.x, whole.y, whole.width, whole.height].map(Coordinate.spelled).joined(separator: ",")
    }

    /// A box as `description` spells it - four whole numbers - or none for anything else,
    /// so every box read is one a box could have printed.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3],
              [x, y, width, height].allSatisfy({ $0 == $0.rounded() }),
              let box = try? ScreenRect(x: x, y: y, width: width, height: height)
        else { return nil }
        self = box
    }
}

public extension ScreenRect {
    /// The one conversion from image space into screen space, and the only place the flip
    /// and the display origin are applied. [LAW:single-enforcer] One implementation to get
    /// right and one to test, rather than one per reader.
    ///
    /// **The backing scale factor does not appear, and that is the point.** A normalized box
    /// is a fraction of the image, and the same fraction of the display's point size, so the
    /// pixels divide out before anything here runs: a 2x capture and a 1x capture of the same
    /// screen produce the same answer. [LAW:types-are-the-program]
    ///
    /// Nil for a box Vision gave that lands on no place - a fraction not a number, or a size
    /// under zero - which the reader counts rather than places. [LAW:no-silent-failure]
    ///
    /// - Parameters:
    ///   - normalized: the box as Vision reports it - a unit rectangle whose origin is at
    ///     the BOTTOM-left of the image.
    ///   - display: where the captured piece sits in the global space, top-left origin.
    static func fromImageSpace(normalized: CGRect, on display: ScreenRect) -> ScreenRect? {
        let left = display.x + normalized.origin.x * display.width
        // The flip. Vision measures up from the bottom of the image; the screen measures
        // down from the top. A box's TOP edge is therefore its distance from the bottom
        // plus its own height, taken away from the whole.
        let top = display.y + (1 - normalized.origin.y - normalized.size.height) * display.height
        // The size as Vision gave it: `CGRect.width` is the standardized one, which would read
        // a size under zero as a box reaching the other way.
        return try? ScreenRect(x: left, y: top, width: normalized.size.width * display.width, height: normalized.size.height * display.height)
    }

    /// The inverse of `fromImageSpace`: where this box sits in an image of `display`, as a
    /// unit rectangle with the origin at the bottom-left - the space Vision's region of
    /// interest is given in. Beside its inverse so the flip is written in one file and tested
    /// as a round trip. [LAW:single-enforcer]
    func normalized(in display: ScreenRect) -> CGRect {
        CGRect(
            x: (x - display.x) / display.width,
            y: 1 - (y - display.y + height) / display.height,
            width: width / display.width,
            height: height / display.height
        )
    }
}
