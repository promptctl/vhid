import Foundation

/// What a pointer verb is aimed at: a point, pressed exactly, or a box, pressed at a point
/// drawn inside it. `docs/design/human.md`, "Where a click lands".
///
/// [LAW:types-are-the-program] The two differ in what is known of the target's size, which
/// is what Fitts' law and the spread of a person's clicks are both read from, so each is a
/// case rather than a box with a flag saying whether its size means anything.
public enum Target: Hashable, Sendable, CustomStringConvertible {
    case point(ScreenPoint)
    case box(ScreenRect)

    /// About a button's height or a line of text's, in points: the size taken for a target
    /// vhid is not told the size of, and the room a path keeps from an edge.
    static let button = 20.0

    /// Fitts' W, the target's width along the move: for a box, the smaller of its sides, as
    /// MacKenzie and Buxton's "smaller-of" model takes it for a two-dimensional target; for
    /// a point, whose size vhid is not told, `button`.
    var width: Double {
        switch self {
        case .point: Self.button
        case .box(let box): min(box.width, box.height)
        }
    }

    /// How far inside a box's edge every drawn point stays, in points. eyes rounds a box out
    /// to whole points, up to a point bigger on each side than what it found, and the cursor
    /// lands within half a point of where it is sent wherever one count moves it less than
    /// that; two points is clear of both. A Mac whose tracking speed carries the cursor
    /// further a count lands further off, which `Click.at` reports.
    public static let margin = 2.0

    /// How many standard deviations of a person's click spread fit across a target they
    /// hit 96% of the time: the effective width W_e = 4.133 σ (MacKenzie 1992; ISO 9241-9).
    static let spreads = 4.133

    /// The standard deviation of where a hand ends up across its line of travel, as a share
    /// of the distance travelled: about 3° of directional error. Directional error stays
    /// near constant in angle whatever the movement's extent (Gordon, Ghilardi and Ghez
    /// 1994); the figure itself is this design's own.
    static let directionalError = 0.05

    /// Where on the screen a click from `start` is aimed: a point inside the box, redrawn
    /// outside its aimable part, each axis weighted by how much of the line of travel lies
    /// along it, the line running from `start` to the nearest aimable point. Along the line
    /// of travel, the axis is drawn about the box's centre with a spread of its aimable width
    /// over `spreads`, as a person's clicks scatter over a target they move toward. Across it,
    /// the axis is drawn about the start, kept inside the box, with the hand's directional
    /// error over the distance, so a hand moving down onto a wide menu row comes straight
    /// down rather than swinging across to the row's middle. A point has no aimable width
    /// and is aimed at exactly; so is a box the start is already inside, which is no
    /// distance from it. One code path for all of them. [LAW:dataflow-not-control-flow]
    func aim(from start: ScreenPoint, drawing generator: inout some RandomNumberGenerator) -> ScreenPoint {
        let (centre, half) = aimable
        let nearest = (x: min(max(start.x, centre.x - half.x), centre.x + half.x), y: min(max(start.y, centre.y - half.y), centre.y + half.y))
        let (dx, dy) = (nearest.x - start.x, nearest.y - start.y)
        let distance = hypot(dx, dy)
        // The share of the line of travel along each axis; no travel at all is all across.
        let along = distance > 0 ? (x: dx * dx / (distance * distance), y: dy * dy / (distance * distance)) : (x: 0, y: 0)
        func axis(along: Double, centre: Double, half: Double, nearest: Double) -> Double {
            let spread = 2 * half / Self.spreads
            return Normal(nearest + along * (centre - nearest),
                          along * spread + (1 - along) * min(spread, Self.directionalError * distance),
                          within: centre - half ... centre + half).draw(using: &generator)
        }
        return ScreenPoint(x: axis(along: along.x, centre: centre.x, half: half.x, nearest: nearest.x),
                           y: axis(along: along.y, centre: centre.y, half: half.y, nearest: nearest.y))!
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
