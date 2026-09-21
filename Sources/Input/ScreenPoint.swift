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

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { String(format: "(%g, %g)", x, y) }
}
