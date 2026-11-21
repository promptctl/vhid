/// A point in the one screen space both halves speak: global coordinates, in points, origin
/// at the top left of the main display, y growing downward, negative on a display left of
/// or above it.
///
/// The space the window server reports the cursor in, the accessibility tree reports frames
/// in, and a capture is cut in, so a point read off the screen is a point the pointer is
/// sent to with no conversion between. [FRAMING:representation] [LAW:one-source-of-truth]
public struct ScreenPoint: Hashable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two numbers become a place on the screen, and
    /// the one refusal of two that are not one.
    ///
    /// **A NaN is the refusal that matters.** Every comparison against a NaN is false, so a
    /// NaN target passes the pointer's "within half a point" test on both axes at once: the
    /// move reports arriving having posted nothing, and the click after it presses wherever
    /// the cursor was. [LAW:no-silent-failure] An infinity goes the same way, since no report
    /// brings the cursor any nearer one.
    public static func at(_ x: Double, _ y: Double) throws(NotAPlace) -> ScreenPoint {
        guard x.isFinite, y.isFinite else { throw NotAPlace(x: x, y: y) }
        return ScreenPoint(x, y)
    }

    /// For the geometry here, whose every answer is finite by its own construction.
    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// `x,y`, each as `Coordinate.spelled` spells it: the form `look` prints and `click` takes.
    public var description: String { "\(Coordinate.spelled(x)),\(Coordinate.spelled(y))" }
}

/// Two numbers that are not a place on the screen. Every door that takes a place - a command
/// line, a tool's arguments, a script line, the cursor read back - words its refusal with this.
/// [LAW:single-enforcer]
public struct NotAPlace: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String { "\(Coordinate.spelled(x)),\(Coordinate.spelled(y)) is not a place on the screen" }
}
