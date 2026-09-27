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

extension Answer {
    /// Every `AXError` a read can return, decided one value at a time: either this
    /// element went unread and the walk goes on, or the reader could not look at all and
    /// throws. [LAW:no-silent-failure] Nothing here is folded into absence except the two
    /// codes that mean absence.
    init(_ error: AXError) throws(TreeError) {
        switch error {
        case .success: self = .answered
        // `failure` is how AppKit says an element has no such attribute: measured, TextEdit
        // answers a description read on its text area with it every time, while the value
        // beside it holds the whole document. Read as unanswered, every wordless AppKit
        // element would make the region unread, and no absence could ever be proven.
        case .noValue, .attributeUnsupported, .failure: self = .absent
        // The app is busy past the messaging timeout, the element went away mid-walk, or
        // the app does not implement the API. Each is a fact about this element, and the
        // rest of the tree may answer.
        case .cannotComplete, .invalidUIElement, .notImplemented: self = .unanswered
        // No grant: no element anywhere will answer, and waiting will not change that.
        case .apiDisabled: throw .noGrant
        // Codes a plain attribute read cannot produce unless this code asked wrongly, so
        // they are a bug in the reader, never a fact about the screen.
        case .illegalArgument, .invalidUIElementObserver, .actionUnsupported,
             .notificationUnsupported, .notificationAlreadyRegistered, .notificationNotRegistered,
             .parameterizedAttributeUnsupported, .notEnoughPrecision:
            throw .unexpected(error.rawValue)
        @unknown default: throw .unexpected(error.rawValue)
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
    /// nothing - the role, which names an element and never places or hides one, or a text
    /// already beaten by one that did answer.
    var answer: Value? {
        if case .answered(let value) = self { value } else { nil }
    }
}

/// What one element says about itself, each read as it came back.
///
/// Reads are kept apart rather than failing the element together, because apps fail
/// reads they have no use for: measured, TextEdit answers a description read on its text
/// area with a failure, every time, while the value beside it holds the whole document.
/// Whether a failed read matters is decided by what the element needed from it.
struct Facts {
    /// `AXUnknown` - the tree's own word - when the app would not name it.
    let role: Role
    /// Its value, title and description, in that order.
    let texts: [Heard<String?>]
    /// Where it is: nil inside when it has no position or no size.
    let frame: Heard<ScreenRect?>
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

extension Facts {
    /// The element as a finding in `region`: its first text that is not blank, at its own
    /// frame, if the centre of that frame - the point a click lands on - is in the region
    /// and under none of the windows in front of this one. An element is unanswered only
    /// when a read it needed failed: no text answered and one would not say, or its frame
    /// would not say. [LAW:no-silent-failure]
    /// [LAW:effects-at-boundaries] Pure, so every rule an element is kept or dropped by is
    /// tested with facts a test wrote.
    func candidate(in region: ScreenRect, under covers: [ScreenRect]) -> Candidate {
        guard let text = texts.lazy.compactMap({ $0.answer.flatMap { $0 }.flatMap(Text.init) }).first else {
            return .excluded(texts.contains(.unanswered) ? .unanswered : .wordless)
        }
        guard case .answered(let placed) = frame else { return .excluded(.unanswered) }
        guard let placed, !placed.isEmpty, region.contains(placed.centre) else { return .excluded(.unplaced) }
        guard !covers.contains(where: { $0.contains(placed.centre) }) else { return .excluded(.covered) }
        return .found(Found(text: text, frame: placed, source: .tree(role: role)))
    }

    /// Whether nothing under this element can be a finding: the part of its frame inside
    /// the region is empty, or lies wholly under one window in front. The walk does not
    /// descend there.
    ///
    /// Measured, this is what lets a walk reach a window at all: a full-screen terminal in
    /// front held four thousand elements, every one of them off the region asked about,
    /// and walking them spent the whole element bound. A child can lie outside its
    /// parent's frame - scrolled-off rows do - but then it is clipped by that parent and
    /// no click reaches it either. An element with no frame, or an empty one, says
    /// nothing about where its children are, so the walk goes on into it.
    func screensOff(_ region: ScreenRect, under covers: [ScreenRect]) -> Bool {
        guard case .answered(let placed?) = frame, !placed.isEmpty else { return false }
        let visible = placed.cgRect.intersection(region.cgRect)
        return visible.isNull || visible.isEmpty || covers.contains { $0.cgRect.contains(visible) }
    }
}

/// Where a walk starts: one window's element, and the frames of every window in front of
/// it, which everything under it inherits.
struct Root<Element> {
    let element: Element
    let covers: [ScreenRect]
}

/// What a walk established, ready to be judged.
struct Walked: Equatable {
    let found: [Found]
    let examined: Int
    let excluded: [Exclusion]
    let reach: Reach
}

/// How much one walk may read. A tree is read one synchronous call into another process
/// per attribute, and a browser's is tens of thousands wide, so a walk stops at these and
/// says so in its reach rather than outlasting its caller.
struct Bounds {
    let elements: Limit
    let time: Duration
}

/// Breadth first from `roots`, every element read once, until the tree runs out or a
/// bound is hit. The roots come front to back, so a walk cut short by a bound has spent
/// it on what is most visible. `unansweredRoots` counts windows that could not be found
/// because their app would not list them - never read, and so never whole. [LAW:dataflow-not-control-flow] An element that will not answer is a
/// value the walk carries on past - counted, and its subtree unread - not an abort: the
/// text is usually in another branch.
///
/// Held apart from every accessibility call so the walk, its bounds and its counts are
/// checked with no app to read from. [LAW:effects-at-boundaries]
func walk<Element>(
    from roots: [Root<Element>],
    unansweredRoots: Int,
    in region: ScreenRect,
    within bounds: Bounds,
    elapsed: () -> Duration,
    read: (Element) throws -> Node<Element>
) rethrows -> Walked {
    var queue = roots[...]
    var found: [Found] = []
    var seen: Set<Found> = []
    var counts: [Exclusion.Reason: Int] = unansweredRoots > 0 ? [.unanswered: unansweredRoots] : [:]
    var examined = 0
    var stop: Stop?

    while let root = queue.popFirst() {
        guard examined < bounds.elements.count else { stop = .elementLimit(bounds.elements); break }
        guard elapsed() < bounds.time else { stop = .timeBudget(bounds.time); break }
        let node = try read(root.element)
        examined += 1
        let candidate = node.facts.candidate(in: region, under: root.covers)
        switch candidate {
        // A button and the label inside it are two elements with one text at one place.
        case .found(let run) where !seen.insert(run).inserted: counts[.duplicate, default: 0] += 1
        case .found(let run): found.append(run)
        case .excluded(let reason): counts[reason, default: 0] += 1
        }
        switch node.children {
        case .answered(let children) where !node.facts.screensOff(region, under: root.covers):
            queue.append(contentsOf: children.map { Root(element: $0, covers: root.covers) })
        case .answered: break
        // A subtree unread is one more unanswered part, unless this element was already
        // counted as one.
        case .unanswered where candidate != .excluded(.unanswered): counts[.unanswered, default: 0] += 1
        case .unanswered: break
        }
    }

    // Ordered by the reason's spelling so one screen always reports the same way.
    let excluded = counts.map { Exclusion(reason: $0.key, count: $0.value) }.sorted { $0.reason.rawValue < $1.reason.rawValue }
    let reach: Reach = stop.map(Reach.stopped) ?? (counts[.unanswered] == nil ? .whole : .stopped(.unanswered))
    return Walked(found: found, examined: examined, excluded: excluded, reach: reach)
}

/// Everything that means the tree reader could not look, as opposed to having looked and
/// found nothing. Each one throws, because a returned `Reading` is taken as proof of
/// looking.
public enum TreeError: Error, CustomStringConvertible {
    case noGrant
    case unexpected(Int32)

    public var description: String {
        switch self {
        case .noGrant:
            "Accessibility is not granted to this process, so no app's elements can be read."
                + " Grant it in System Settings > Privacy & Security > Accessibility."
        case .unexpected(let code):
            "an accessibility read failed with AXError \(code), which a read of an attribute should never return"
        }
    }
}

extension Heard: Sendable where Value: Sendable {}
extension Heard: Equatable where Value: Equatable {}
