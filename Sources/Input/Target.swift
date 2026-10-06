/// What a pointer verb is aimed at: a point, pressed exactly, or a box, pressed at a point
/// drawn inside it. `docs/design/human.md`, "Where a click lands".
///
/// [LAW:types-are-the-program] The two differ in what is known of the target's size, which
/// is what Fitts' law and the spread of a person's clicks are both read from, so each is a
/// case rather than a box with a flag saying whether its size means anything.
public enum Target: Hashable, Sendable, CustomStringConvertible {
    case point(ScreenPoint)
    case box(ScreenRect)

    /// Fitts' W, the target's width along the move: for a box, the smaller of its sides, as
    /// MacKenzie and Buxton's "smaller-of" model takes it for a two-dimensional target; for
    /// a point, whose size vhid is not told, 20 points, about a button's height or a line of
    /// text's.
    var width: Double {
        switch self {
        case .point: 20
        case .box(let box): min(box.width, box.height)
        }
    }

    /// How far inside a box's edge every drawn point stays, in points. eyes rounds a box out
    /// to whole points, up to a point bigger on each side than what it found, and the cursor
    /// lands within half a point of where it is sent; two points is clear of both.
    public static let margin = 2.0

    /// How many standard deviations of a person's click spread fit across a target they
    /// hit 96% of the time: the effective width W_e = 4.133 σ (MacKenzie 1992; ISO 9241-9).
    static let spreads = 4.133

    /// Where on the screen the click is aimed: a point inside the box, each axis drawn from a
    /// normal around the centre whose spread is that axis's aimable width over `spreads`,
    /// redrawn outside it; the point itself, whose aimable width is zero. One code path for
    /// both, so a point is the box the hand cannot stray in. [LAW:dataflow-not-control-flow]
    func aim(drawing generator: inout some RandomNumberGenerator) -> ScreenPoint {
        let (centre, half) = aimable
        let x = Normal(centre.x, 2 * half.x / Self.spreads, within: centre.x - half.x ... centre.x + half.x).draw(using: &generator)
        let y = Normal(centre.y, 2 * half.y / Self.spreads, within: centre.y - half.y ... centre.y + half.y).draw(using: &generator)
        return ScreenPoint(x: x, y: y)!
    }

    /// The centre aimed about, and how far either side of it on each axis a click may land:
    /// a box less its margin, none at all for a box too small to have any, and none for a point.
    private var aimable: (centre: ScreenPoint, half: (x: Double, y: Double)) {
        switch self {
        case .point(let point): (point, (0, 0))
        case .box(let box): (box.centre, (max(0, box.width / 2 - Self.margin), max(0, box.height / 2 - Self.margin)))
        }
    }

    public var description: String {
        switch self {
        case .point(let point): "\(point)"
        case .box(let box): "the box \(box)"
        }
    }
}
