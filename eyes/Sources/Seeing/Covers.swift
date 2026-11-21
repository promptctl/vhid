/// Where a click lands: the windows in front of one, and the system's hit test that settles
/// what a frame alone cannot. One rule for the tree's walk and for which runs belong to the
/// app a look reads, so "can this be seen" means one thing. [LAW:one-source-of-truth]

/// A read that either answered, possibly with nothing, or did not. [LAW:types-are-the-program]
public enum Heard<Value> {
    case answered(Value)
    case unanswered

    public func map<T>(_ transform: (Value) -> T) -> Heard<T> {
        switch self {
        case .answered(let value): .answered(transform(value))
        case .unanswered: .unanswered
        }
    }

    /// What it said, flattened: nil when it did not answer. Only where a failed read costs
    /// nothing - the role's name, whose failure `Facts.named` keeps apart, or a text
    /// already beaten by one that did answer.
    public var answer: Value? {
        if case .answered(let value) = self { value } else { nil }
    }
}

extension Heard: Sendable where Value: Sendable {}
extension Heard: Equatable where Value: Equatable {}

/// A window in front: where it could be drawn, and the process it belongs to.
public struct Cover: Equatable, Sendable {
    public let frame: ScreenRect
    public let pid: Int32

    public init(frame: ScreenRect, pid: Int32) {
        self.frame = frame
        self.pid = pid
    }
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
public struct Covers {
    public let windows: [Cover]
    /// The process of the window these are in front of.
    public let owner: Int32
    /// The process a click at a point lands in.
    public let hit: (ScreenPoint) -> Heard<Int32>

    public init(windows: [Cover], owner: Int32, hit: @escaping (ScreenPoint) -> Heard<Int32>) {
        self.windows = windows
        self.owner = owner
        self.hit = hit
    }

    /// Whether a click at `point` lands on a window in front of this one: unanswered when
    /// the hit test does not settle it.
    public func hide(_ point: ScreenPoint) -> Heard<Bool> {
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
    public func hide(_ rect: ScreenRect) -> Bool {
        let whole = windows.filter { $0.frame.cgRect.contains(rect.cgRect) }
        guard !whole.isEmpty else { return false }
        guard !whole.contains(where: { $0.pid == owner }) else { return true }
        guard case .answered(let pid) = hit(rect.centre) else { return false }
        return whole.contains { $0.pid == pid }
    }
}

