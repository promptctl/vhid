/// A box on the screen, in `ScreenPoint`'s space: its top-left corner, then its size, in
/// points.
///
/// The box `eyes find` prints beside each point, and named as eyes names it: the two
/// packages share no code, so each states the shape it speaks, as `ScreenPoint` explains.
public struct ScreenRect: Hashable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// [LAW:parse-dont-validate] The one place four doubles become a box, and the one place
    /// four that are not one are refused: a coordinate that is not finite, for the reason
    /// `ScreenPoint` refuses it, its far corners included, or a side under a point: the
    /// closing loop lands within half a point, so a narrower box is not one the cursor can be
    /// put inside, and Fitts' law read off it would take a move without end.
    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite), width >= 1, height >= 1 else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A box as eyes prints it and its `rect` takes it: `x,y,width,height`.
    /// [LAW:single-enforcer] The command line and the MCP server both read a box through here.
    public init?(spelled: String) {
        let parts = spelled.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3] else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }

    public var centre: ScreenPoint { ScreenPoint(x: x + width / 2, y: y + height / 2)! }

    /// Spelled as eyes prints it, so a box read back is a box that can be passed on.
    public var description: String { [x, y, width, height].map { String(format: "%g", $0) }.joined(separator: ",") }
}
