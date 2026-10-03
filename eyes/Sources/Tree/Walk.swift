import ApplicationServices
import Eyes

/// What one accessibility read came back as, before anything is made of it.
///
/// [LAW:types-are-the-program] Three answers, because two of them are easy to collapse
/// and must not be: an app saying an element has no such attribute has answered, and an
/// app that did not answer has not. Folding the second into the first prunes a subtree
/// and then calls the text missing.
enum Answer: Equatable {
    /// The app answered, with whatever it had.
    case answered
    /// The app answered that there is no such attribute: a leaf has no children, an
    /// unlabelled element has no title.
    case absent
    /// Looked, and this part would not say - the element is skipped and counted.
    case unanswered
}

/// What a read was for, which is the one thing that decides what a generic failure means.
enum Part {
    /// A value, title or description: what an element says.
    case text
    /// A role, position, size, children or window list: what holds the tree together.
    case structure
}

extension Answer {
    /// Every `AXError` a read can return, decided one value at a time: this part went unread
    /// and the walk goes on, or - with no grant - the reader could not look at all and throws.
    /// [LAW:no-silent-failure] Nothing is folded into absence except the codes that mean it.
    init(_ error: AXError, for part: Part) throws(TreeError) {
        switch error {
        case .success: self = .answered
        case .noValue, .attributeUnsupported: self = .absent
        // How AppKit says an element has no such text: measured, TextEdit answers a
        // description read on its text area with it every time, while the value beside it
        // holds the whole document. Read as unanswered, every wordless AppKit element would
        // leave the region unread, and no absence could ever be proven. Only for text: a
        // failed children read taken as "no children" would prune a subtree unseen.
        case .failure: self = part == .text ? .absent : .unanswered
        // The app is busy past the messaging timeout, the element went away mid-walk, or
        // the app does not implement the API. Each is a fact about this element, and the
        // rest of the tree may answer.
        case .cannotComplete, .invalidUIElement, .notImplemented: self = .unanswered
        // Codes a well-behaved app never returns for an attribute read. Another app's
        // implementation is not bound by that, and one odd element must not fail the read
        // of every window, so they too are this part unread.
        case .illegalArgument, .invalidUIElementObserver, .actionUnsupported,
             .notificationUnsupported, .notificationAlreadyRegistered, .notificationNotRegistered,
             .parameterizedAttributeUnsupported, .notEnoughPrecision:
            self = .unanswered
        // No grant: no element anywhere will answer, and waiting will not change that.
        case .apiDisabled: throw .noGrant
        @unknown default: self = .unanswered
        }
    }
}

/// A read that either answered, possibly with nothing, or did not. [LAW:types-are-the-program]
enum Heard<Value> {
    case answered(Value)
    case unanswered

    func map<T>(_ transform: (Value) -> T) -> Heard<T> {
        switch self {
        case .answered(let value): .answered(transform(value))
        case .unanswered: .unanswered
        }
    }

    /// What it said, flattened: nil when it did not answer. Only where a failed read costs
    /// nothing - the role's name, whose failure `Facts.named` keeps apart, or a text
    /// already beaten by one that did answer.
    var answer: Value? {
        if case .answered(let value) = self { value } else { nil }
    }
}

extension Heard: Sendable where Value: Sendable {}
extension Heard: Equatable where Value: Equatable {}

/// What one element says about itself, each read as it came back.
///
/// Reads are kept apart rather than failing the element together, because apps fail
/// reads they have no use for. Whether a failed read matters is decided by what the
/// element needed from it.
struct Facts {
    /// `AXUnknown` - the tree's own word - when the app would not name it.
    let role: Role
    /// Its value, title and description, in that order.
    let texts: [Heard<String?>]
    /// Where it is: nil inside when it has no position or no size.
    let frame: Heard<ScreenRect?>
    /// Whether the app answered its role, even with nothing. Apart from `role` because
    /// `AXUnknown` is also a role apps answer - measured, Safari names elements that - and
    /// the two are not one fact. No default: a caller building one says which it is.
    let named: Bool
}

/// One element read: what it says, and what is under it.
struct Node<Element> {
    let facts: Facts
    let children: Heard<[Element]>
}

/// An element as something a reading can hold, or why it cannot be.
enum Candidate: Equatable {
    case found(Found)
    case excluded(Exclusion.Reason)
}

/// A window in front: where it could be drawn, and the process it belongs to.
struct Cover: Equatable {
    let frame: ScreenRect
    let pid: Int32
}

/// The windows in front of one, and the system's own answer to where a click lands.
///
/// A frame says only where a window could be drawn, not that it is drawn there. Measured on
/// studious: Notification Center holds a window over the whole screen at layer 23 that
/// draws nothing but its desktop widgets, and taken as opaque it hid every window from the
/// tree. So where a frame is in front, the hit test the system routes clicks by settles it -
/// about 2 ms a point, asked only there. A click landing in the element's own process
/// leaves it seen; landing in a window's in front covers it; landing anywhere else - the
/// menu bar is the Window Server's but a click on it lands in the front app, and a panel
/// drawn by a service lands in the service - settles nothing, and says so. A window in
/// front from the element's own process covers by its frame, since a click landing there
/// cannot tell the two apart. [LAW:one-source-of-truth] [LAW:no-silent-failure]
struct Covers {
    let windows: [Cover]
    /// The process of the window these are in front of.
    let owner: Int32
    /// The process a click at a point lands in.
    let hit: (ScreenPoint) -> Heard<Int32>

    /// Whether a click at `point` lands on a window in front of this one: unanswered when
    /// the hit test does not settle it.
    func hide(_ point: ScreenPoint) -> Heard<Bool> {
        let over = windows.filter { $0.frame.contains(point) }
        guard !over.isEmpty else { return .answered(false) }
        guard !over.contains(where: { $0.pid == owner }) else { return .answered(true) }
        switch hit(point) {
        case .answered(owner): return .answered(false)
        case .answered(let pid) where over.contains(where: { $0.pid == pid }): return .answered(true)
        case .answered, .unanswered: return .unanswered
        }
    }

    /// Whether all of `rect` is under one window in front that a click at its centre lands
    /// in. The centre stands for the rest: a window wholly inside a front one that draws
    /// only in places is read whole or not at all by where its middle is. Only a window
    /// holding the whole rect can stand for it - a click at the centre landing in one that
    /// overlaps only the middle says nothing of the rest. Unanswered is not hidden - what
    /// is under it is read, and each finding asks for itself.
    func hide(_ rect: ScreenRect) -> Bool {
        let whole = windows.filter { $0.frame.cgRect.contains(rect.cgRect) }
        guard !whole.isEmpty else { return false }
        guard !whole.contains(where: { $0.pid == owner }) else { return true }
        guard case .answered(let pid) = hit(rect.centre) else { return false }
        return whole.contains { $0.pid == pid }
    }
}

/// The part of `frame` a click can reach inside `clip`: none when they do not meet, or when
/// what they share lies wholly under one window in front.
///
/// One rule for an element's children and for a window the tree cannot walk, so "could
/// anything there be seen" means one thing. [LAW:single-enforcer]
func visible(_ frame: ScreenRect, in clip: ScreenRect, under covers: Covers) -> ScreenRect? {
    let shared = frame.cgRect.intersection(clip.cgRect)
    guard !shared.isNull, !shared.isEmpty, !covers.hide(ScreenRect(shared)) else { return nil }
    return ScreenRect(shared)
}

/// Roles whose frame is an area holding other elements. What such an element says names
/// the area - a window's title, a list's label - and the centre of the area is on whatever
/// sits there, never on the words: measured, a window's title came back at the middle of
/// its document. The words themselves, where they are drawn, are an element of their own.
/// Not a group: on a web page a labelled group is as often a control - an icon button
/// whose only child is its image - pressed at its centre.
let areas: Set<Role> = Set([
    kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXScrollAreaRole,
    kAXSplitGroupRole, kAXTabGroupRole, kAXToolbarRole, kAXListRole, kAXOutlineRole, kAXTableRole,
    kAXColumnRole, kAXBrowserRole, kAXLayoutAreaRole, kAXGridRole, kAXRadioGroupRole, kAXMenuRole,
    kAXMenuBarRole, kAXPopoverRole, "AXWebArea",
].map { Role(rawValue: $0) })

extension Node {
    /// The element as a finding: its first text that is not blank, at its own frame, if it
    /// is not an area, and the centre of that frame - the point a click lands on - is
    /// inside `clip` and under none of the windows in front of this one.
    ///
    /// An area is known by its role and children together: a list with nothing under it is
    /// the thing its label names, and its centre is where it is pressed. It is decided first, from reads that arrive with the role, so an area
    /// whose text would not answer never leaves the region unread over words that could
    /// not have been a finding. Placement is decided before text, so an element that could
    /// never be a finding here is unplaced whatever its text reads did - a busy
    /// element's own text off the region does not make the region unread; what is under
    /// it is `descent`'s to decide. An element is unanswered
    /// only when a read it needed failed: its frame would not say, or no text answered and
    /// one would not say. Whether it is covered is asked only of an element with words or
    /// words it could not read, since the hit test is a call into another process and a
    /// wordless element could never be a finding. [LAW:no-silent-failure]
    /// [LAW:effects-at-boundaries] Decided from facts and a hit test handed in, so every
    /// rule an element is kept or dropped by is tested with both written by a test.
    func candidate(in clip: ScreenRect, under covers: Covers) -> Candidate {
        let leaf = if case .answered(let children) = children { children.isEmpty } else { false }
        guard leaf || !areas.contains(facts.role) else { return .excluded(.area) }
        if case .answered(let placed) = facts.frame {
            guard let placed, !placed.isThin, clip.contains(placed.centre) else { return .excluded(.unplaced) }
        }
        let text = facts.texts.lazy.compactMap({ $0.answer.flatMap { $0 }.flatMap(Text.init) }).first
        guard text != nil || facts.texts.contains(.unanswered) else { return .excluded(.wordless) }
        if case .answered(let placed?) = facts.frame {
            switch covers.hide(placed.centre) {
            case .answered(false): break
            case .answered(true): return .excluded(.covered)
            case .unanswered: return .excluded(.overlaid)
            }
        }
        guard let text, case .answered(let placed?) = facts.frame else { return .excluded(.unanswered) }
        return .found(Found(text: text, frame: placed, source: .tree(role: facts.role)))
    }
}

extension ScreenRect {
    /// No more than a point across in either direction: nothing a person reads or clicks.
    /// Measured on studious: Chrome places a page element scrolled wholly out of view on
    /// the edge of the viewport nearest it, a strip one point thick and its full length the
    /// other way, so its centre is inside the page while the element is not.
    var isThin: Bool { width <= 1 || height <= 1 }
}

/// What a window's tree said of the pages in it: the frame of each web area shown, cut to
/// where the window and the areas clipping it let it draw, and how far the search got.
public struct Paged: Sendable, Equatable {
    public let pages: [ScreenRect]
    public let examined: Int
    /// Why the search ended before reading every element it reached, if it did.
    public let stop: Stop?

    /// The three ways a search for a page ends short - its own, since no result limit or
    /// merge applies to it. [LAW:types-are-the-program]
    public enum Stop: Sendable, Equatable, CustomStringConvertible {
        case elementLimit(Limit)
        case timeBudget(Duration)
        /// An element's children did not answer, or the window's app would not list it.
        case unread

        public var description: String {
            switch self {
            case .elementLimit(let l): "it stopped at \(l.count) elements"
            case .timeBudget(let d): "it stopped after \(d)"
            case .unread: "parts of it did not answer"
            }
        }
    }

    /// The one page shown, or the refusal saying why there is not exactly one: a page
    /// is known only from a search that read everything it reached, since an element
    /// left unread could hold a second one. [LAW:no-silent-failure]
    public func page(in window: UInt32) throws(PageError) -> ScreenRect {
        if let stop { throw .unread(window, stop) }
        guard let page = pages.first else { throw .none(window) }
        guard pages.count == 1 else { throw .several(window, pages.count) }
        return page
    }
}

/// Every web page shown under `root`, breadth first and never inside one another: what
/// is inside a page - its iframes - is that page. Each is cut to `window` and to every
/// area above it that clips what it holds, as the reading walk's bound is, so a page
/// scrolled partly out of its viewport is the part a person sees. A web area left with
/// nothing to show - a background tab - is no page. Bounded as the reading walk is, by
/// elements and by time, since a browser's tree is tens of thousands wide.
/// [LAW:effects-at-boundaries]
func pages<Element>(
    under root: Element, in window: ScreenRect, within bounds: Bounds,
    elapsed: () -> Duration, read: (Element) throws -> Node<Element>
) rethrows -> Paged {
    var queue = [(element: root, bound: window)][...]
    var pages: [ScreenRect] = []
    var examined = 0
    var unread = false
    while let (element, bound) = queue.popFirst() {
        guard examined < bounds.elements.count else { return Paged(pages: pages, examined: examined, stop: .elementLimit(bounds.elements)) }
        guard elapsed() < bounds.time else { return Paged(pages: pages, examined: examined, stop: .timeBudget(bounds.time)) }
        let node = try read(element)
        examined += 1
        // A page or a clipping area that will not say where it is leaves unknown which page
        // is shown and how much of it: dropping it could leave a DevTools pane the one page,
        // and passing the window down could hand back the toolbar. [LAW:no-silent-failure]
        if node.facts.role == webArea || clips.contains(node.facts.role), case .unanswered = node.facts.frame { unread = true; continue }
        let placed = node.facts.frame.answer.flatMap { $0 }
        let inner = placed.map { clips.contains(node.facts.role) && !$0.isEmpty ? ScreenRect(bound.cgRect.intersection($0.cgRect)) : bound } ?? bound
        if node.facts.role == webArea {
            if let placed, case let shown = bound.cgRect.intersection(placed.cgRect), !shown.isNull, !ScreenRect(shown).isThin {
                pages.append(ScreenRect(shown))
            }
            continue
        }
        guard case .answered(let children) = node.children else { unread = true; continue }
        queue.append(contentsOf: children.map { ($0, inner) })
    }
    return Paged(pages: pages, examined: examined, stop: unread ? .unread : nil)
}

/// Why a window has no one page to read.
public enum PageError: Error, CustomStringConvertible {
    case none(UInt32)
    /// More than one web area shown side by side, such as a page and a docked DevTools.
    case several(UInt32, Int)
    /// The search ended before it read every element it reached.
    case unread(UInt32, Paged.Stop)

    public var description: String {
        switch self {
        case .none(let id): "window \(id) shows no web page: its accessibility tree holds no AXWebArea on screen"
        case .several(let id, let n): "window \(id) shows \(n) web pages side by side, such as a page and a docked DevTools;"
            + " read the one meant with a rect"
        case .unread(let id, let stop): "window \(id)'s accessibility tree was not read whole looking for its page (\(stop)),"
            + " so whether it shows one is unknown; read it with a rect"
        }
    }
}

/// The role a browser gives the page it shows.
let webArea = Role(rawValue: "AXWebArea")

/// Roles that draw nothing outside their own frame: a scroll area's rows, and a web page
/// inside its viewport.
let clips: Set<Role> = Set([kAXScrollAreaRole, "AXWebArea"].map { Role(rawValue: $0) })

/// What the walk does under an element: how its children are read.
enum Descent: Equatable {
    /// Walk them, counting in `clip` - what can be clicked in the region - and drawn no
    /// further than `bound`.
    case descend(clip: ScreenRect, bound: ScreenRect)
    /// The element is not seen in the region, but its children may be: a web page's
    /// dropdown hangs below a header scrolled off it. Read them, counting each only if it
    /// is seen.
    case probe
    /// Nothing under it can be seen.
    case prune
    /// It is not seen, it could still hold something that is, and its role read failed -
    /// so whether it clips its children is unknown. They are not read, and are counted as a
    /// part left unread. [LAW:no-silent-failure]
    case unsure
}

extension Facts {
    /// How the walk goes on under this element.
    ///
    /// Two rectangles come down the walk, because two questions are asked. `clip` is what
    /// can be clicked in the region, and a finding is judged against it. `bound` is where
    /// anything under the element can be drawn at all, whatever the region: the window, cut
    /// down by each element that clips what it holds - a scroll area to its viewport, a web
    /// page to its own. A row scrolled wholly out of its list is outside the list's bound,
    /// so nothing under it is drawn anywhere and it is pruned. A header just above the
    /// region is inside its page's bound, so what hangs off it may be in the region, and it
    /// is probed rather than skipped - a skipped dropdown is a false proof of absence. An
    /// element with no frame, or an empty one, says nothing about where its children are,
    /// so the walk goes on into it.
    ///
    /// Probing reads what the region does not show: measured on Safari and Finder, up to
    /// 2.7 times the elements pruning at the region read, and at most a fifth of a second
    /// more. The walk's own bounds cap it, and say so in the reach.
    ///
    /// The one place the descend, probe and prune decision is made. [LAW:single-enforcer]
    func descent(clip: ScreenRect, bound: ScreenRect, under covers: Covers) -> Descent {
        guard case .answered(let placed?) = frame, !placed.isEmpty else { return .descend(clip: clip, bound: bound) }
        let clipping = clips.contains(role)
        if let shown = visible(placed, in: clip, under: covers) {
            guard clipping else { return .descend(clip: clip, bound: bound) }
            return .descend(clip: shown, bound: ScreenRect(bound.cgRect.intersection(placed.cgRect)))
        }
        guard !clipping, placed.intersects(bound) else { return .prune }
        return named ? .probe : .unsure
    }
}

/// Where a walk starts: one window's element, the part of the screen a click inside it can
/// reach, and the frames of every window in front of it. Everything under it inherits the
/// covers, and the clip and bound narrowed by what clips on the way down.
struct Root<Element> {
    let element: Element
    let clip: ScreenRect
    /// Where anything under it can be drawn. See `Facts.descent`.
    let bound: ScreenRect
    let covers: Covers
    /// Read under an element not seen in the region, to find what hangs into it: counted
    /// only if seen. See `Descent.probe`.
    var probe = false
}

/// What a walk established, ready to be judged.
struct Walked: Equatable {
    let found: [Found]
    let examined: Int
    let excluded: [Exclusion]
    let reach: Reach
}

/// How much one walk may read. A tree is read one synchronous call into another process
/// per element, and a browser's is tens of thousands wide, so a walk stops at these and
/// says so in its reach rather than outlasting its caller.
struct Bounds {
    let elements: Limit
    let time: Duration
}

/// One text at one place, whatever role said it: a button and the label inside it are two
/// elements and one thing on screen.
private struct Place: Hashable {
    let text: String
    let frame: ScreenRect
}

/// Each root in turn, front to back, breadth first within it, every element read once,
/// until the roots run out or a bound is hit - so a walk cut short has spent its bounds on
/// the windows in front, never on the shallow levels of one behind.
///
/// [LAW:dataflow-not-control-flow] An element that will not answer is a value the walk
/// carries on past - counted, and its subtree unread - not an abort: the text is usually
/// in another branch. `unwalked` counts on-screen windows in the region with no element to
/// start from; they were never read, so the region was not read whole.
///
/// Every accessibility call - the reads and the hit tests in each root's covers - is
/// handed in, so the walk, its bounds and its counts are checked with no app to read
/// from. [LAW:effects-at-boundaries]
func walk<Element>(
    from roots: [Root<Element>],
    unwalked: Int,
    within bounds: Bounds,
    elapsed: () -> Duration,
    read: (Element) throws -> Node<Element>
) rethrows -> Walked {
    var found: [Found] = []
    var seen: Set<Place> = []
    var counts: [Exclusion.Reason: Int] = unwalked > 0 ? [.unwalked: unwalked] : [:]
    var examined = 0
    var stop: Stop?

    roots: for start in roots {
        var queue = [start][...]
        while let root = queue.popFirst() {
            guard examined < bounds.elements.count else { stop = .elementLimit(bounds.elements); break roots }
            guard elapsed() < bounds.time else { stop = .timeBudget(bounds.time); break roots }
            let node = try read(root.element)
            examined += 1
            let candidate = node.candidate(in: root.clip, under: root.covers)
            // A probe not seen - off the clip, or with a frame that says nothing - was never
            // placed in the region: nothing to count, unless a read it needed failed, which
            // leaves unknown whether it was.
            let quiet = root.probe && candidate != .excluded(.unanswered) && {
                guard case .answered(let placed?) = node.facts.frame, !placed.isEmpty else { return true }
                return visible(placed, in: root.clip, under: root.covers) == nil
            }()
            switch candidate {
            case _ where quiet: break
            case .found(let run) where !seen.insert(Place(text: run.text.value, frame: run.frame)).inserted:
                counts[.duplicate, default: 0] += 1
            case .found(let run): found.append(run)
            case .excluded(let reason): counts[reason, default: 0] += 1
            }
            let unread = candidate == .excluded(.unanswered)
            switch (node.children, node.facts.descent(clip: root.clip, bound: root.bound, under: root.covers)) {
            // An element whose frame says nothing about where it is does not end a probe.
            case (.answered(let children), .descend(let clip, let bound)):
                let probe = root.probe && quiet
                queue.append(contentsOf: children.map { Root(element: $0, clip: clip, bound: bound, covers: root.covers, probe: probe) })
            case (.answered(let children), .probe):
                queue.append(contentsOf: children.map { Root(element: $0, clip: root.clip, bound: root.bound, covers: root.covers, probe: true) })
            // A subtree unread is one more unanswered part - unless nothing in it could be
            // seen, or this element was already counted as one.
            case (.unanswered, .descend), (.unanswered, .probe), (.unanswered, .unsure):
                if !unread { counts[.unanswered, default: 0] += 1 }
            case (.answered(let children), .unsure) where !children.isEmpty:
                if !unread { counts[.unanswered, default: 0] += 1 }
            case (_, .prune), (.answered, .unsure): break
            }
        }
    }

    // Ordered by the reason's spelling so one screen always reports the same way.
    let excluded = counts.map { Exclusion(reason: $0.key, count: $0.value) }.sorted { $0.reason.rawValue < $1.reason.rawValue }
    let unread = counts[.unanswered] != nil || counts[.unwalked] != nil || counts[.overlaid] != nil
    let reach: Reach = stop.map(Reach.stopped) ?? (unread ? .stopped(.unread) : .whole)
    return Walked(found: found, examined: examined, excluded: excluded, reach: reach)
}

/// The on-screen windows any of which can be seen in `region`, front to back, each with
/// the part of it that can be seen there and the frames of every window in front of it -
/// every layer, so the menu bar and the Dock cover what they cover. A window off the
/// region or wholly behind one in front holds nothing to read, so it is never matched,
/// walked or counted. The hit test is handed in, so the rule is tested with windows and a
/// hit test a test wrote.
func seen(_ windows: [Window], in region: ScreenRect, hit: @escaping (ScreenPoint) -> Heard<Int32>) -> [Seen] {
    windows.enumerated().compactMap { index, window in
        let covers = Covers(windows: windows[..<index].map { Cover(frame: $0.frame, pid: $0.pid) }, owner: window.pid, hit: hit)
        return visible(window.frame, in: region, under: covers).map { Seen(window: window, clip: $0, covers: covers) }
    }
}

/// A window that can be seen, where, and under what.
struct Seen {
    let window: Window
    let clip: ScreenRect
    let covers: Covers
}

/// Seen windows as roots to walk, and a count of the ones with no element to start from -
/// an open menu, a system surface, a window whose app would not list it. Those were on
/// screen and never read. [LAW:no-silent-failure]
func plan<Element>(_ seen: [Seen], matched: [UInt32: Element]) -> (roots: [Root<Element>], unwalked: Int) {
    let roots = seen.compactMap { entry in matched[entry.window.id].map { Root(element: $0, clip: entry.clip, bound: entry.window.frame, covers: entry.covers) } }
    return (roots, seen.count - roots.count)
}

/// Everything that means the tree reader could not look, as opposed to having looked and
/// found nothing. Each one throws, because a returned `Reading` is taken as proof of
/// looking.
public enum TreeError: ReaderError, CustomStringConvertible {
    case noGrant

    public var missingGrant: Bool { self == .noGrant }

    public var description: String {
        switch self {
        case .noGrant:
            "\(TreeReader.grant.name) is not granted to the app responsible for eyes, so no app's elements can be read."
                + " Grant it in \(TreeReader.grant.pane)."
        }
    }
}
