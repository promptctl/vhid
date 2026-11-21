import ScreenSpace

extension ScreenRect {
    /// How far this rectangle sits from `other`, the space between their edges: across
    /// lines first, then along one, then whether it starts before `other` does. So a
    /// button in a row is nearer the row's own text than the rows above and below it,
    /// however wide the row; a field is nearer the label just above it than one a line
    /// further down; and of two links touching one label, the one after it is nearer, as
    /// a label comes before what it names in left-to-right reading - measured in Safari,
    /// whose " · Pricing " run touches the "More" before it and the one after.
    ///
    /// Across is negative where the two share lines, by how much they share: rows packed
    /// edge to edge touch the row above as well as their own, and the row's own shares more.
    func gap(to other: ScreenRect) -> Gap {
        Gap(across: max(y, other.y) - min(maxY, other.maxY),
            along: max(0, max(x, other.x) - min(maxX, other.maxX)),
            leads: x < other.x)
    }
}

/// The space between two rectangles, ordered across lines first. See `ScreenRect.gap`.
struct Gap: Comparable {
    let across: Double
    let along: Double
    let leads: Bool

    static func < (a: Gap, b: Gap) -> Bool { (a.across, a.along, a.leads ? 1 : 0) < (b.across, b.along, b.leads ? 1 : 0) }
}
