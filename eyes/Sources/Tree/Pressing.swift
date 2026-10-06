import Eyes

/// What one element says of itself for a row to be found by it.
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
    /// An element's parent alone, nil at the top: all a climb from a hit needs.
    let parent: (Element) throws -> Heard<Element?>
    let same: (Element, Element) -> Bool
    /// Whether the time for checking a reading's boxes is spent, asked before every hit
    /// test: a busy app holds each one for the whole messaging timeout.
    let spent: () -> Bool

    /// The most parents climbed from an element: far more than a web page nests, and a
    /// bound on an app whose parents run in a loop, past which the check is unanswered.
    static var depth: Int { 64 }

    /// How close a cut edge is found: half a point, finer than the whole points a box
    /// prints in.
    static var resolution: Double { 0.5 }

    /// Why a row's check stopped short, thrown from wherever it did.
    private struct Stop: Error { let why: Unchecked }

    /// A row's box, checked against where a click lands on the element the row names.
    ///
    /// A frame is the app's claim, and the hit test is where the click goes: Safari gives a
    /// native-looking `<button>` a frame several points wider than the element its page
    /// hit-tests. [LAW:one-source-of-truth] So the element is found from the row's own
    /// point - the hit there, or the nearest ancestor of it with the row's role and frame -
    /// and the box is tested from that point outward: each edge along the line through it
    /// to the edge, moved in to the last point a click presses the element at, found by
    /// halving; then each corner of that box along the diagonal to it, since a rounded
    /// button's corner presses the page though both its edges stand, the box's sides drawn
    /// in until every corner is a point the diagonal reached.
    ///
    /// A row the tree did not place is not this reader's to check, and stands. Every read
    /// that does not answer, a row whose own point lands on something else, and a row the
    /// time ran out on leave the box unchecked rather than guessed, and say which.
    /// [LAW:no-silent-failure]
    func press(_ found: Found) throws -> Checked {
        guard let role = found.source.role else { return Checked(.kept, hitTests: 0) }
        var hitTests = 0
        do {
            let pressed = try box(found.frame, role: role) { point in
                guard !spent() else { throw Stop(why: .overTime) }
                hitTests += 1
                return try heard(hit(point))
            }
            return Checked(pressed, hitTests: hitTests)
        } catch let stop as Stop {
            return Checked(.unchecked(stop.why), hitTests: hitTests)
        }
    }

    private func box(_ frame: ScreenRect, role: Role, landing: (ScreenPoint) throws -> Element?) throws -> Pressed {
        let centre = frame.centre
        guard let at = try landing(centre), let element = try named(from: at, role: role, frame: frame) else {
            throw Stop(why: .elsewhere)
        }
        let above = try ancestors(of: element)
        // Climbs from what a click landed on until it meets the element - inside it - or one
        // of the element's own ancestors or the top - beside it.
        func presses(_ point: ScreenPoint) throws -> Bool {
            var current = try landing(point)
            for _ in 0..<Self.depth {
                guard let at = current, !above.contains(where: { same($0, at) }) else { return false }
                if same(at, element) { return true }
                current = try heard(parent(at))
            }
            throw Stop(why: .unanswered)
        }
        // How far from the centre along a line of length `span` a click still presses the
        // element: all of it, or the last point found by halving.
        func reach(_ span: Double, _ along: (Double) -> ScreenPoint) throws -> Double {
            guard span > Self.resolution, !(try presses(along(span - Self.resolution))) else { return span }
            var (inside, outside) = (0.0, span - Self.resolution)
            while outside - inside > Self.resolution {
                let middle = (inside + outside) / 2
                if try presses(along(middle)) { inside = middle } else { outside = middle }
            }
            return inside
        }
        let (halfWidth, halfHeight) = (frame.width / 2, frame.height / 2)
        let left = try reach(halfWidth) { ScreenPoint(x: centre.x - $0, y: centre.y) }
        let right = try reach(halfWidth) { ScreenPoint(x: centre.x + $0, y: centre.y) }
        let up = try reach(halfHeight) { ScreenPoint(x: centre.x, y: centre.y - $0) }
        let down = try reach(halfHeight) { ScreenPoint(x: centre.x, y: centre.y + $0) }
        // The share of the diagonal to a corner of that box a click presses the element along.
        func corner(_ dx: Double, _ dy: Double) throws -> Double {
            let length = (dx * dx + dy * dy).squareRoot()
            return length == 0 ? 1 : try reach(length) { ScreenPoint(x: centre.x + dx * $0 / length, y: centre.y + dy * $0 / length) } / length
        }
        let (upLeft, upRight) = (try corner(-left, -up), try corner(right, -up))
        let (downLeft, downRight) = (try corner(-left, down), try corner(right, down))
        let (l, r) = (left * min(upLeft, downLeft), right * min(upRight, downRight))
        let (u, d) = (up * min(upLeft, upRight), down * min(downLeft, downRight))
        guard (l, r, u, d) == (halfWidth, halfWidth, halfHeight, halfHeight) else {
            return .narrowed(ScreenRect(x: centre.x - l, y: centre.y - u, width: l + r, height: u + d))
        }
        return .kept
    }

    /// The element a row names, climbing from what its point hits: that element or the
    /// nearest ancestor with the row's role at the row's frame, to the point. Nil when no
    /// ancestor is it.
    private func named(from hit: Element, role: Role, frame: ScreenRect) throws -> Element? {
        var element: Element? = hit
        for _ in 0..<Self.depth {
            guard let current = element else { return nil }
            let said = try heard(lineage(current))
            if said.role == role, let placed = said.frame, placed.same(as: frame) { return current }
            element = said.parent
        }
        throw Stop(why: .unanswered)
    }

    /// The element's parents up to the top of its tree, nearest first.
    private func ancestors(of element: Element) throws -> [Element] {
        var above: [Element] = []
        var current = try heard(parent(element))
        for _ in 0..<Self.depth {
            guard let at = current else { return above }
            above.append(at)
            current = try heard(parent(at))
        }
        throw Stop(why: .unanswered)
    }

    private func heard<Value>(_ heard: Heard<Value>) throws -> Value {
        guard case .answered(let value) = heard else { throw Stop(why: .unanswered) }
        return value
    }
}

extension ScreenRect {
    /// Frames agree to the point; an app and the tree round differently below that.
    func same(as other: ScreenRect) -> Bool {
        abs(x - other.x) < 1 && abs(y - other.y) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
