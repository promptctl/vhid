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

    /// A point between finite edges, which is finite: a box's middle, or the point a part
    /// of a box is pressed at.
    init(between point: (x: Double, y: Double)) {
        (x, y) = point
    }

    /// A point as `x,y` spells it. [LAW:single-enforcer] The command line and the MCP server
    /// both read a point here, as they read a box at `ScreenRect(spelled:)`.
    public init(spelled: String) throws(Misspelled) {
        let numbers = try Coordinate.numbers(spelled, count: 2, of: Self.spelling)
        do {
            try self.init(x: numbers[0], y: numbers[1])
        } catch {
            throw .notAPlace(spelled, error)
        }
    }

    /// What a refusal names as the form wanted.
    public static let spelling = "x,y in points"

    /// `x,y`. [LAW:one-source-of-truth] The one spelling of a point, which every verb prints
    /// and `init(spelled:)` reads back, so a point any verb prints can be passed back.
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

    /// `count` numbers, comma separated, as a point or a box spells them, or the refusal that
    /// names the form wanted.
    static func numbers(_ spelled: String, count: Int, of spelling: String) throws(Misspelled) -> [Double] {
        let words = spelled.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = words.compactMap { Double(String($0.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())) }
        guard words.count == count, numbers.count == count else { throw .form(spelled, wanted: spelling) }
        return numbers
    }
}

/// Text that does not spell the point or box it was read as, and why.
public enum Misspelled: Error, Equatable, CustomStringConvertible {
    /// Not that many numbers: the text, and the form wanted.
    case form(String, wanted: String)
    /// Two numbers that are not a place on the screen.
    case notAPlace(String, NotAPlace)
    /// Four numbers that are not a box.
    case notABox(String, NotABox)

    public var description: String {
        switch self {
        case .form(let spelled, let wanted): "\(spelled) is not \(wanted)"
        case .notAPlace(_, let cause): cause.description
        case .notABox(_, let cause): cause.description
        }
    }
}
