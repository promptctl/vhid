/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward, negative on a display left of or above the main one.
///
/// The space the window server reports the cursor in and the accessibility tree reports
/// frames in, so a point the readers found is a point the pointer is sent to with no
/// conversion between. [LAW:one-source-of-truth] One type for both halves, so a point read
/// with eyes and pressed with the devices is held to one rule.
public struct ScreenPoint: Hashable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two doubles become a place on the screen,
    /// and the one place a pair that is not a place is refused.
    ///
    /// **A NaN is the refusal that matters**, and it is not a hypothetical: every
    /// comparison against a NaN is false, so a NaN target passes the pointer's
    /// "am I within half a point" test on both axes at once. The move then reports
    /// instant arrival having posted nothing, and the click that follows presses wherever
    /// the cursor happened to be sitting. [LAW:no-silent-failure] Infinities go the same
    /// way for the same reason: no report brings the cursor any nearer to one.
    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.init(finite: x, y)
    }

    /// Two numbers given as a place on the screen - by a caller, or by the window server
    /// as where the cursor or an event is - or the refusal every door says it with: a place
    /// is a point some display could show, inside `ScreenRect.displaySpace`.
    /// [LAW:single-enforcer]
    public static func at(_ x: Double, _ y: Double) throws(NotAPlace) -> ScreenPoint {
        guard let point = ScreenPoint(x: x, y: y), ScreenRect.displaySpace.contains(point) else { throw NotAPlace(x: x, y: y) }
        return point
    }

    /// For what this module derives from points and boxes it already holds, each finite.
    init(finite x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// The point with each coordinate rounded by `rule`: a whole number of a finite one is
    /// finite, so this cannot fail.
    public func rounded(_ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> ScreenPoint {
        ScreenPoint(finite: x.rounded(rule), y.rounded(rule))
    }

    /// `x,y`, each in positional notation.
    public var description: String { "\(x.positional),\(y.positional)" }
}

/// Two numbers given as a place that are not one: either is NaN or infinite, or the point
/// is past where any display can be.
public struct NotAPlace: Error, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String { "\(x.positional),\(y.positional) is not a place on the screen" }
}
