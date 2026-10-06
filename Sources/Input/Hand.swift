/// How long a person's hand waits around a press: on the target before the button goes
/// down, with the button held, between the clicks of a double click, and between notches
/// of a wheel. `docs/design/human.md`, "Clicks" and "Scrolling".
///
/// [LAW:one-source-of-truth] Every pause a pointer makes is drawn from here, by its kind.
public struct Hand: Sendable, Equatable {
    /// On the target before a press, a drag's release, or a scroll's first notch.
    public let rest: Normal
    /// A click's button held down.
    public let hold: Normal
    /// From one click's release to the next click's press.
    public let gap: Normal
    /// A drag's button held on the start point before it is carried.
    public let dragHold: Normal
    /// After each notch of the wheel.
    public let notch: Normal

    /// The share of the double-click interval a press may come within of the one before,
    /// and the shortest a hold or gap is scaled to however short the interval is.
    static let withinInterval = 0.8
    static let pressFloor = 60.0

    /// The hand for a Mac whose double-click interval is `doubleClickInterval`.
    ///
    /// A click's hold and gap are scaled down together until the longest of each, back to
    /// back, is within 80% of the interval, so a double click is one double click to macOS;
    /// never below their 60 ms floor. At macOS's default 0.5 s they are not scaled.
    ///
    /// The scale is the largest under which max(hold·s, f) + max(gap·s, f) fits the budget
    /// B, and since max(a, f) + max(b, f) = max(a + b, a + f, f + b, 2f), that is the least
    /// of B / (hold + gap), (B − f) / hold and (B − f) / gap. Under a 150 ms interval even
    /// two floors do not fit, and the floors win.
    public init(doubleClickInterval: Duration) {
        let hold = Normal(110, 30, within: Self.pressFloor ... 200)
        let gap = Normal(120, 30, within: Self.pressFloor ... 180)
        let budget = Self.withinInterval * (doubleClickInterval / .milliseconds(1))
        let (longestHold, longestGap) = (hold.bounds.upperBound, gap.bounds.upperBound)
        let scale = min(1, budget / (longestHold + longestGap), (budget - Self.pressFloor) / longestHold, (budget - Self.pressFloor) / longestGap)
        rest = Normal(250, 80, within: 120 ... 500)
        self.hold = hold.scaled(by: scale, floor: Self.pressFloor)
        self.gap = gap.scaled(by: scale, floor: Self.pressFloor)
        dragHold = Normal(100, 25, within: 50 ... 200)
        // [LAW:one-source-of-truth] The floor is the notch spacing below which Safari and
        // TextEdit were measured accelerating notches, a third clear. `Pointer.scroll`.
        notch = Normal(230, 20, within: 200 ... 300)
    }

    /// The distribution a pause of `kind` is drawn from.
    public func spread(of kind: Pause.Kind) -> Normal {
        switch kind {
        case .rest: rest
        case .hold: hold
        case .gap: gap
        case .dragHold: dragHold
        case .notch: notch
        }
    }
}

/// One pause a pointer made, as drawn: what it was for and how long.
public struct Pause: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case rest, hold, gap
        case dragHold = "drag_hold"
        case notch
    }

    public let kind: Kind
    public let length: Duration

    public init(kind: Kind, length: Duration) {
        self.kind = kind
        self.length = length
    }
}

extension Normal {
    /// This distribution shrunk by `scale`, its bounds kept at or above `floor` and its
    /// mean inside them. Bounds that close to a single point are that point, drawn every
    /// time. [LAW:parse-dont-validate] The result is a distribution `draw` can always end.
    func scaled(by scale: Double, floor: Double) -> Normal {
        let bounds = max(bounds.lowerBound * scale, floor) ... max(bounds.upperBound * scale, floor)
        let mean = min(max(mean * scale, bounds.lowerBound), bounds.upperBound)
        return Normal(mean, bounds.lowerBound == bounds.upperBound ? 0 : deviation * scale, within: bounds)
    }
}
