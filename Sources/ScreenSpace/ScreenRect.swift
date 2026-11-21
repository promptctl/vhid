import Foundation

/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points.
///
/// The frame eyes reads a window, an element or a word at, and the box a pointer verb is
/// aimed at. It may be empty, as a window or a Vision box can be; a box a press can land
/// inside is `Target.Box`, parsed from one of these where a press is aimed.
/// [LAW:types-are-the-program]
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    /// Leftmost point, increasing to the right. Negative on a display left of the main one.
    public let x: Double
    /// Topmost point, increasing DOWNWARD. This is the axis that gets flipped by mistake.
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box, and the one place
    /// four that are not one are refused: a coordinate that is not finite, for the reason
    /// `ScreenPoint` refuses it, its far corners included, or a side under zero. CGRect's
    /// null, whose origin is infinite, is no box and is refused here.
    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite), width >= 0, height >= 0 else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Where a press aimed at this box lands on average, and what a reading reports its
    /// point as. Derived rather than carried, so it cannot disagree with the box it came from.
    public var centre: ScreenPoint { ScreenPoint(x: x + width / 2, y: y + height / 2)! }

    public var isEmpty: Bool { width == 0 || height == 0 }

    /// The farthest from the origin any edge or size of a spelled box may be, in points. An
    /// app's claimed frame - a document's text area, taller than any screen - prints past it,
    /// and is refused when read back: a capture is cut in whole points.
    public static let limit = 1_000_000.0

    /// What a refusal names as the form wanted.
    public static let spelling = "x,y,width,height in points - a positive size, nothing past \(Int(limit))"

    /// `x,y,width,height` in whole points: the smallest whole-point box covering this one,
    /// rounded outward as `CGRect.integral` rounds, so what is printed still holds every point
    /// of what was found, and a negative coordinate is not moved toward zero. The one spelling
    /// every box is printed in, and the one `init(spelled:)` reads. [LAW:one-source-of-truth]
    public var description: String {
        let (left, top) = (x.rounded(.down), y.rounded(.down))
        return [left, top, (x + width).rounded(.up) - left, (y + height).rounded(.up) - top].map(Self.whole).joined(separator: ",")
    }

    /// A whole number of points in figures, however large: a document's frame can run past
    /// what an `Int` holds, and printing one never traps.
    static func whole(_ v: Double) -> String { Int(exactly: v).map(String.init) ?? String(format: "%.0f", v) }

    /// A box as `description` spells it, or none for anything that is not one with a size.
    /// [LAW:single-enforcer] Every command line and MCP server reads a box through here.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              [x, y, w, h].allSatisfy({ abs($0) <= Self.limit }), w > 0, h > 0
        else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
}
