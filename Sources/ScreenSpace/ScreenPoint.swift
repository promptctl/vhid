/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward.
///
/// The space the window server reports the cursor in, the accessibility tree reports frames
/// in, and every point the readers print and the devices press is in. [FRAMING:representation]
/// One space, named once for both halves, rather than a pair of doubles whose meaning each
/// caller remembers. [LAW:one-source-of-truth]
public struct ScreenPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    /// [LAW:parse-dont-validate] The one place two doubles become a place in the space, and
    /// the one place a pair that is not one is refused.
    ///
    /// **A NaN is the refusal that matters**, and it is not a hypothetical: every comparison
    /// against a NaN is false, so a NaN target passes the pointer's "am I within half a
    /// point" test on both axes at once. The move then reports instant arrival having posted
    /// nothing, and the click that follows presses wherever the cursor happened to be. An
    /// infinity goes the same way: no report brings the cursor any nearer to one.
    /// [LAW:no-silent-failure]
    public init(x: Double, y: Double) throws(NotAPlace) {
        guard x.isFinite, y.isFinite else { throw NotAPlace(x: x, y: y) }
        self.init(finite: x, y)
    }

    /// For arithmetic on finite values whose result is finite by construction: a box's
    /// middle, a whole point inside a part. Not public, so nothing outside the space makes a
    /// point without the crossing.
    init(finite x: Double, _ y: Double) {
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
        do {
            try self.init(x: x, y: y)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .x, in: container, debugDescription: error.description)
        }
    }

    /// `x,y`, each coordinate in `Coordinate.spelled`: the one text spelling of a point, which
    /// `init(spelled:)` reads back as this point.
    public var description: String { "\(Coordinate.spelled(x)),\(Coordinate.spelled(y))" }

    /// A point as `description` spells it. [LAW:single-enforcer] Every door that takes a
    /// point as text reads it here.
    public init(spelled: String) throws(Misspelled) {
        let numbers = try Coordinate.numbers(in: spelled, count: 2, form: Self.form)
        do {
            try self.init(x: numbers[0], y: numbers[1])
        } catch {
            throw Misspelled(spelled, form: Self.form, because: error.description)
        }
    }

    /// What a refusal names as the form wanted.
    public static let form = "x,y in points"
}

/// Two numbers that are not a place in the space: one of them is not finite.
public struct NotAPlace: Error, Hashable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public var description: String { "(\(x), \(y)) is not a place on the screen: each coordinate must be finite" }
}

/// One coordinate or length of the space, as text.
public enum Coordinate {
    /// The shortest digits that read back as `value`, a whole number without its `.0`: what a
    /// point and a box are printed in, so whatever is printed is passed on as it was.
    public static func spelled(_ value: Double) -> String {
        let digits = "\(value)"
        return digits.hasSuffix(".0") ? String(digits.dropLast(2)) : digits
    }

    /// `count` numbers separated by commas, or the refusal naming `form`.
    static func numbers(in spelled: String, count: Int, form: String) throws(Misspelled) -> [Double] {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let numbers = parts.compactMap { $0 }
        guard parts.count == count, numbers.count == count else { throw Misspelled(spelled, form: form, because: nil) }
        return numbers
    }
}

/// Text that does not spell what it was read as: not the form, or the form but not a place
/// or a box in the space.
public struct Misspelled: Error, Hashable, CustomStringConvertible {
    public let text: String
    public let form: String
    /// What the numbers are refused for, when they are the form's numbers.
    public let because: String?

    init(_ text: String, form: String, because: String?) {
        self.text = text
        self.form = form
        self.because = because
    }

    public var description: String {
        because.map { "\(text) is not \(form): \($0)" } ?? "\(text) is not \(form)"
    }
}
