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

    /// Where on the screen a click from `start` is aimed: a point inside the box's aimable
    /// part. A person's clicks scatter over a target about its centre, each axis's spread its
    /// aimable width over `spreads`; a hand coming in from outside the box also keeps to its
    /// line of travel, from `start` to the nearest aimable point, straying across it only by
    /// its directional error over the distance. The aim is drawn from the scatter held to
    /// that line, as a Kalman update holds an estimate to one noisy observation: where the
    /// hand's error is small next to the box's spread, the scatter is pulled onto the start's
    /// line and narrowed across it, and still spreads about the centre along it, so a hand
    /// moving down onto a wide menu row comes straight down; where it is large, as on a long
    /// move to a small button, the scatter is left about the centre. A start over the box,
    /// its margin included, has no line of travel and aims
    /// at the scatter alone. Drawn again outside the aimable part. A point has no aimable
    /// width and is aimed at exactly. [LAW:dataflow-not-control-flow]
    func aim(from start: ScreenPoint, drawing generator: inout some RandomNumberGenerator) -> ScreenPoint {
        let (centre, reach, half) = extent
        let scatter = Scatter(mean: (centre.x, centre.y), covariance: (pow(2 * half.x / Self.spreads, 2), 0, pow(2 * half.y / Self.spreads, 2)))
        let nearest = (x: min(max(start.x, centre.x - half.x), centre.x + half.x), y: min(max(start.y, centre.y - half.y), centre.y + half.y))
        let (dx, dy) = (nearest.x - start.x, nearest.y - start.y)
        let distance = hypot(dx, dy)
        let over = abs(start.x - centre.x) <= reach.x && abs(start.y - centre.y) <= reach.y
        let held = over ? scatter : scatter.held(to: (start.x, start.y), across: (-dy / distance, dx / distance), straying: Self.directionalError * distance)
        let (x, y) = held.draw(within: (centre.x - half.x ... centre.x + half.x, centre.y - half.y ... centre.y + half.y), using: &generator)
        return ScreenPoint(x: x, y: y)!
    }

    /// The centre, how far either side of it on each axis the target reaches, and how far a
    /// click may land: a box less its margin, none at all for a box too small to have any,
    /// and none for a point.
    private var extent: (centre: ScreenPoint, reach: (x: Double, y: Double), aimable: (x: Double, y: Double)) {
        switch self {
        case .point(let point): (point, (0, 0), (0, 0))
        case .box(let box): (box.centre, (box.width / 2, box.height / 2), (max(0, box.width / 2 - Self.margin), max(0, box.height / 2 - Self.margin)))
        }
    }

    /// A two-dimensional normal: where a person's clicks fall, before the box's edges cut it.
    private struct Scatter {
        let mean: (x: Double, y: Double)
        let covariance: (xx: Double, xy: Double, yy: Double)

        /// This scatter held to the line through `point` whose unit normal is `across`, which
        /// the hand strays from with a standard deviation of `straying`: the Kalman update by
        /// one observation of the distance across the line, observed as zero.
        func held(to point: (x: Double, y: Double), across: (x: Double, y: Double), straying: Double) -> Scatter {
            let gain = (x: covariance.xx * across.x + covariance.xy * across.y, y: covariance.xy * across.x + covariance.yy * across.y)
            let innovation = across.x * gain.x + across.y * gain.y + straying * straying
            let off = across.x * (point.x - mean.x) + across.y * (point.y - mean.y)
            return Scatter(mean: (mean.x + gain.x * off / innovation, mean.y + gain.y * off / innovation),
                           covariance: (covariance.xx - gain.x * gain.x / innovation, covariance.xy - gain.x * gain.y / innovation, covariance.yy - gain.y * gain.y / innovation))
        }

        /// One draw, by the Cholesky factor of the covariance, redrawn until it is inside
        /// `bounds`, as `Normal` is. The mean is always inside: it lies between the centre and
        /// the scatter's nearest point on the hand's line, which enters the box.
        func draw(within bounds: (x: ClosedRange<Double>, y: ClosedRange<Double>), using generator: inout some RandomNumberGenerator) -> (x: Double, y: Double) {
            let l11 = max(0, covariance.xx).squareRoot()
            let l21 = l11 > 0 ? covariance.xy / l11 : 0
            let l22 = max(0, covariance.yy - l21 * l21).squareRoot()
            while true {
                let (z1, z2) = (Normal.standard(using: &generator), Normal.standard(using: &generator))
                let drawn = (x: mean.x + l11 * z1, y: mean.y + l21 * z1 + l22 * z2)
                if bounds.x.contains(drawn.x), bounds.y.contains(drawn.y) { return drawn }
            }
        }
    }

    public var description: String {
        switch self {
        case .point(let point): "\(point)"
        case .box(let box): "the box \(box)"
        }
    }
}
