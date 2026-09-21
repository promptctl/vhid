/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward.
///
/// The space the window server reports the cursor in, so a target read off the screen is
/// a target the pointer can be sent to with no conversion between. [FRAMING:representation]
/// One space, named, rather than a pair of doubles whose meaning each caller remembers.
///
/// The same space `eyes` reports text and window frames in, and said twice on purpose:
/// the two packages share no code by design, so each states the space it speaks rather
/// than one depending on the other to define it. A shared definition would be the
/// dependency this separation exists to avoid; two definitions of one fixed system
/// coordinate space cannot drift, because neither is free to choose.
public struct ScreenPoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two doubles become a place on the screen,
    /// and the one place a pair that is not a place is refused.
    ///
    /// **A NaN is the refusal that matters**, and it is not a hypothetical: every
    /// comparison against a NaN is false, so a NaN target passes the pointer's
    /// "am I within half a point" test on both axes at once. The move then reports
    /// instant arrival having posted nothing, and the click that follows presses wherever
    /// the cursor happened to be sitting - a button pressed somewhere nobody asked for,
    /// with nothing anywhere saying so. [LAW:no-silent-failure] Infinities go the same way
    /// for the same reason: no report brings the cursor any nearer to one.
    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }

    /// Decoded through the same crossing, so a script or a request carrying `1e400` is
    /// refused where it is read rather than becoming an infinity downstream.
    /// [LAW:single-enforcer]
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard let point = ScreenPoint(x: x, y: y) else {
            throw DecodingError.dataCorruptedError(forKey: .x, in: container, debugDescription: "(\(x), \(y)) is not a place on the screen")
        }
        self = point
    }

    public var description: String { String(format: "(%g, %g)", x, y) }
}
