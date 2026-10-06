import Eyes

/// What one element says of itself for a box to be checked against it.
struct Lineage<Element> {
    let role: Role
    /// Nil when it has no position or no size.
    let frame: ScreenRect?
    /// Nil at the top of its tree.
    let parent: Element?
}

extension Lineage: Sendable where Element: Sendable {}

/// Where a click on a row lands, asked of the accessibility tree: the system's hit test and
/// the reads that place what it hits. Handed in, so every rule a box is cut by is tested
/// with a tree a test wrote. [LAW:effects-at-boundaries]
struct Probe<Element> {
    /// The element a click at a point lands on, by the hit test the system routes clicks
    /// by; nil when there is none.
    let hit: (ScreenPoint) throws -> Heard<Element?>
    let lineage: (Element) throws -> Heard<Lineage<Element>>
    let same: (Element, Element) -> Bool

    /// The most parents climbed from a hit element: far more than a web page nests, and a
    /// bound on an app whose parents run in a loop, past which the check is unanswered.
    static var depth: Int { 64 }

    /// How close a cut edge is found: half a point, finer than the whole points a box
    /// prints in.
    static var resolution: Double { 0.5 }

    /// A row's box, checked against where a click lands on the element the row names.
    ///
    /// A frame is the app's claim, and the hit test is where the click goes: Safari gives a
    /// native-looking `<button>` a frame several points wider than the element its page
    /// hit-tests. [LAW:one-source-of-truth] So the element is found from the row's own
    /// point - the hit there, or the nearest ancestor of it with the row's role and frame -
    /// and each edge of the frame is tested from that point outward along the lines
    /// through it: an edge a click presses the element at stands, and one it does not is
    /// moved in to the last point that does, found by halving. A box is the frame, or a
    /// part of it a click presses the element in along those lines.
    ///
    /// A row the tree did not place is not this reader's to check, and stands. Every read
    /// that does not answer, and a row whose own point lands on something else, leaves the
    /// box unchecked rather than guessed. [LAW:no-silent-failure]
    func press(_ found: Found) throws -> Pressed {
        guard let role = found.source.role else { return .kept }
        let frame = found.frame
        let centre = frame.centre
        guard case .answered(let at?) = try hit(centre), case .answered(let element?) = try named(from: at, role: role, frame: frame) else {
            return .unchecked
        }
        func presses(_ point: ScreenPoint) throws -> Heard<Bool> {
            switch try hit(point) {
            case .answered(let landed?): try holds(element, landed)
            case .answered(nil): .answered(false)
            case .unanswered: .unanswered
            }
        }
        // Each side's reach from the centre: how far out along its line a click still
        // presses the element.
        func reach(_ span: Double, _ along: (Double) -> ScreenPoint) throws -> Heard<Double> {
            let edge = span - Self.resolution
            switch try presses(along(edge)) {
            case .answered(true): return .answered(span)
            case .unanswered: return .unanswered
            case .answered(false): break
            }
            var (inside, outside) = (0.0, edge)
            while outside - inside > Self.resolution {
                let middle = (inside + outside) / 2
                switch try presses(along(middle)) {
                case .answered(true): inside = middle
                case .answered(false): outside = middle
                case .unanswered: return .unanswered
                }
            }
            return .answered(inside)
        }
        let (halfWidth, halfHeight) = (frame.width / 2, frame.height / 2)
        guard case .answered(let left) = try reach(halfWidth, { ScreenPoint(x: centre.x - $0, y: centre.y) }),
              case .answered(let right) = try reach(halfWidth, { ScreenPoint(x: centre.x + $0, y: centre.y) }),
              case .answered(let up) = try reach(halfHeight, { ScreenPoint(x: centre.x, y: centre.y - $0) }),
              case .answered(let down) = try reach(halfHeight, { ScreenPoint(x: centre.x, y: centre.y + $0) })
        else { return .unchecked }
        guard [left, right].allSatisfy({ $0 == halfWidth }), [up, down].allSatisfy({ $0 == halfHeight }) else {
            return .narrowed(ScreenRect(x: centre.x - left, y: centre.y - up, width: left + right, height: up + down))
        }
        return .kept
    }

    /// The element a row names, climbing from what its point hits: that element or the
    /// nearest ancestor with the row's role at the row's frame, to the point. Nil when no
    /// ancestor is it.
    private func named(from hit: Element, role: Role, frame: ScreenRect) throws -> Heard<Element?> {
        var element: Element? = hit
        for _ in 0..<Self.depth {
            guard let current = element else { return .answered(nil) }
            guard case .answered(let said) = try lineage(current) else { return .unanswered }
            if said.role == role, let placed = said.frame, placed.same(as: frame) { return .answered(current) }
            element = said.parent
        }
        return .unanswered
    }

    /// Whether `landed` is `element` or inside it, by its parents.
    private func holds(_ element: Element, _ landed: Element) throws -> Heard<Bool> {
        var current: Element? = landed
        for _ in 0..<Self.depth {
            guard let at = current else { return .answered(false) }
            if same(at, element) { return .answered(true) }
            guard case .answered(let said) = try lineage(at) else { return .unanswered }
            current = said.parent
        }
        return .unanswered
    }
}

extension ScreenRect {
    /// Frames agree to the point; an app and the tree round differently below that.
    func same(as other: ScreenRect) -> Bool {
        abs(x - other.x) < 1 && abs(y - other.y) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
