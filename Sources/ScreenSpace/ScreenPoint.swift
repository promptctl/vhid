/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward, negative on a display left of or above the main one.
///
/// The space the window server reports the cursor, the windows and the displays in, and
/// the accessibility tree its frames, so a point read off the screen is a point the
/// pointer is sent to with no conversion between. One type for the devices and the
/// readers alike. [LAW:one-source-of-truth]
public struct ScreenPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two doubles become a point, and the one place
    /// a pair that is not one is refused.
    ///
    /// **A NaN is the refusal that matters**: every comparison against one is false, so a
    /// NaN target passes the pointer's "within half a point" test on both axes at once, the
    /// move reports arrival having posted nothing, and the click presses wherever the
    /// cursor sat. [LAW:no-silent-failure] Infinities go the same way: no report brings the
    /// cursor nearer one.
    public init(x: Double, y: Double) throws(NotAPlace) {
        guard x.isFinite, y.isFinite else { throw NotAPlace(x: x, y: y) }
        self.x = x
        self.y = y
    }

    /// Decoded through the same crossing, so a script or a request carrying `1e400` is
    /// refused where it is read. [LAW:single-enforcer]
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let (x, y) = (try container.decode(Double.self, forKey: .x), try container.decode(Double.self, forKey: .y))
        do {
            try self.init(x: x, y: y)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .x, in: container, debugDescription: error.description)
        }
    }

    /// `x,y`, the form `click` takes, so a point any verb prints can be passed back.
    public var description: String { "\(Coordinate.spelled(x)),\(Coordinate.spelled(y))" }
}

/// Two numbers that are not a place on the screen: one of them is not finite.
public struct NotAPlace: Error, Equatable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String { "\(Coordinate.spelled(x)),\(Coordinate.spelled(y)) is not a place on the screen: a coordinate is not finite" }
}

/// How one coordinate is written wherever a point or a box is printed.
public enum Coordinate {
    /// The shortest digits that read back as `value`, a whole number without its `.0`.
    /// [LAW:one-source-of-truth] Every point and box spelling goes through here.
    public static func spelled(_ value: Double) -> String {
        let digits = "\(value)"
        return digits.hasSuffix(".0") ? String(digits.dropLast(2)) : digits
    }
}
