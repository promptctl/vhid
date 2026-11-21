/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward, negative on a display left of or above the main one.
///
/// The space the window server reports the cursor in and the accessibility tree reports
/// frames in, so a point eyes reads off the screen is a point the pointer can be sent to
/// with no conversion between. [FRAMING:representation] One space, named once, for the
/// devices and the readers alike. [LAW:one-source-of-truth]
public struct ScreenPoint: Hashable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two doubles become a place on the screen,
    /// and the one place a pair that is not a place is refused: a coordinate past
    /// `farthest`, which no NaN or infinity is within.
    ///
    /// **A NaN is the refusal that matters**, and it is not a hypothetical: every
    /// comparison against a NaN is false, so a NaN target passes the pointer's
    /// "am I within half a point" test on both axes at once. The move then reports
    /// instant arrival having posted nothing, and the click that follows presses wherever
    /// the cursor happened to be sitting - a button pressed somewhere nobody asked for,
    /// with nothing anywhere saying so. [LAW:no-silent-failure] Infinities go the same way
    /// for the same reason: no report brings the cursor any nearer to one.
    public init?(x: Double, y: Double) {
        guard abs(x) <= Self.farthest, abs(y) <= Self.farthest else { return nil }
        self.x = x
        self.y = y
    }

    /// The pair as a point, or why it is none, in the words every door refuses one with.
    /// [LAW:single-enforcer]
    public static func at(_ x: Double, _ y: Double) throws(NotAPlace) -> ScreenPoint {
        guard let point = ScreenPoint(x: x, y: y) else { throw NotAPlace(x: x, y: y) }
        return point
    }

    /// The farthest from the origin a coordinate may be, in points: 2^53, the last whole
    /// number a Double holds with every whole number below it. Past it a Double skips whole
    /// points, so it is no place a point can be named at; and within it, the arithmetic of
    /// points and boxes - a sum, a span, a square - stays finite, so what is derived from
    /// places is a place. [LAW:types-are-the-program]
    public static let farthest = 9_007_199_254_740_992.0

    /// `x,y`, each in every digit it has.
    public var description: String { "\(Self.spelled(x)),\(Self.spelled(y))" }

    /// A coordinate in every digit it has, a whole one without its `.0`: the one form every
    /// coordinate in this space is printed in, so a value printed is the value passed on,
    /// and a point and a box beside it never spell one number two ways.
    /// [LAW:one-source-of-truth] Within `farthest` a whole number fits an `Int` and a Double
    /// prints in figures, never as an exponent of ten.
    static func spelled(_ coordinate: Double) -> String { Int(exactly: coordinate).map(String.init) ?? "\(coordinate)" }
}

/// Two numbers that are not a place on the screen.
public struct NotAPlace: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String { "(\(ScreenPoint.spelled(x)), \(ScreenPoint.spelled(y))) is not a place on the screen" }
}
