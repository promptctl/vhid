import CoreGraphics

/// The app a look with no place named reads: the one an agent is working in.
///
/// The frontmost app is where keys go, so it is that app - unless it is the app eyes answers
/// to, the agent's own terminal or Claude app, which echoes on screen the very text it asks
/// eyes to find. Then it is the app of the frontmost window behind it. What is read is that
/// app's windows and whatever is stacked in front of its front window - a remote Open panel,
/// a service's popover - derived afresh from each read's own window list by `owners(in:hit:)`,
/// so a panel that opens during a wait is read from the next read on. Only what a wait must
/// keep is held here. [LAW:one-source-of-truth]
public struct Front: Sendable, Hashable {
    public let app: App
    /// The display holding the app's front window, read whole and cut to the owners' windows.
    public let display: CGDirectDisplayID
    /// The app eyes answers to: its windows are never read, wherever they are stacked - in
    /// front and passed over, or a window over the front app's.
    public let own: Passed
    /// Whether the app eyes answers to was in front, and passed over for the app behind it.
    public let passedOver: Bool

    public init(app: App, display: CGDirectDisplayID, own: Passed, passedOver: Bool) {
        self.app = app
        self.display = display
        self.own = own
        self.passedOver = passedOver
    }

    /// A running application, as the window server and AppKit both know it.
    public struct App: Sendable, Hashable, CustomStringConvertible {
        public let pid: Int32
        public let name: String?

        public init(pid: Int32, name: String?) {
            self.pid = pid
            self.name = name
        }

        public var description: String { "\(name ?? "(unnamed)") (pid \(pid))" }
    }

    /// The app eyes answers to: every process running from its bundle, and its name.
    public struct Passed: Sendable, Hashable {
        public let pids: Set<Int32>
        public let name: String

        public init(pids: Set<Int32>, name: String) {
            self.pids = pids
            self.name = name
        }
    }

    /// The processes this read takes in, from the windows on screen now: the app, and every
    /// process with a window in front of the app's front window that a click there lands in -
    /// a remote Open panel, a service's popover - less the app eyes answers to.
    ///
    /// Listed above and over the front window is not enough: a frame says only where a window
    /// could be drawn. Notification Center holds one over the whole screen that draws nothing
    /// there, and the menu bar is listed above every window and shows the frontmost app's
    /// menus. So the hit test settles each, at the centre of what it covers of the front
    /// window, as `Covers` settles a rect; one that does not answer takes nothing in.
    /// [LAW:single-enforcer]
    public func owners(in listing: WindowListing, hit: (ScreenPoint) -> Heard<Int32>) -> Set<Int32> {
        let front = listing.front(of: app.pid)
        let over = front.map { i in
            listing.windows[..<i].filter { window in
                let shared = window.frame.cgRect.intersection(listing.windows[i].frame.cgRect)
                return !shared.isNull && !shared.isEmpty && hit(ScreenRect(shared).centre) == .answered(window.pid)
            }
        } ?? []
        return Set(over.map(\.pid)).union([app.pid]).subtracting(own.pids)
    }

    /// Where an app a click at `point` lands in stands to a look with no place named, by the
    /// rules that look reads by: `own`, its one display, the windows it walks, and `owners`.
    /// [LAW:single-enforcer] `front` is nil when only the app eyes answers to has an ordinary
    /// window open.
    public static func standing(of pid: Int32, at point: ScreenPoint, own: Passed, front: Front?, in listing: WindowListing,
                                displays: [Display], hit: (ScreenPoint) -> Heard<Int32>) -> Standing {
        if own.pids.contains(pid) { return .own(own.name) }
        guard let front else { return .behind(nil) }
        guard displays.contains(where: { $0.id == front.display && $0.frame.contains(point) }) else {
            return .otherDisplay(front.app, front.display)
        }
        guard listing.windows.contains(where: { $0.pid == pid && $0.frame.contains(point) }) else { return .noWindow(front.app) }
        if pid == front.app.pid { return .front(front.app) }
        return front.owners(in: listing, hit: hit).contains(pid) ? .overFront(front.app) : .behind(front.app)
    }

    /// The app a look with no place named reads, from facts the caller gathered.
    ///
    /// - frontmost: the app AppKit names frontmost, when any is; when none is, the app of the
    ///   frontmost ordinary window stands for it, by the same rule.
    /// - own: the app eyes answers to.
    /// - regular: the processes that are ordinary apps (AppKit's `.regular` activation
    ///   policy), which is what "an app behind" can be - not the Dock, the menu bar or a
    ///   service's panel.
    /// - names: what each of those apps is called.
    public static func choose(frontmost: App?, own: Passed, regular: Set<Int32>, names: [Int32: String],
                              listing: WindowListing, displays: [Display]) throws(NoFront) -> Front {
        let app = { (window: Window) in App(pid: window.pid, name: names[window.pid] ?? window.owner) }
        let ordinary = { (pid: Int32) in regular.contains(pid) }
        guard let first = frontmost ?? listing.front(where: ordinary).map({ app(listing.windows[$0]) }) else {
            throw NoFront(own: own.name, why: .onlyOwn)
        }
        let chosen: App
        let passed = own.pids.contains(first.pid)
        if !passed {
            chosen = first
        } else if let behind = listing.front(where: { ordinary($0) && !own.pids.contains($0) }) {
            chosen = app(listing.windows[behind])
        } else {
            throw NoFront(own: own.name, why: .onlyOwn)
        }
        let window = listing.front(of: chosen.pid).map { listing.windows[$0] }
        let display = window.flatMap { w in displays.first { $0.frame.contains(w.frame.centre) } } ?? displays.first { $0.isMain }
        guard let display else { throw NoFront(own: own.name, why: .noDisplay) }
        return Front(app: chosen, display: display.id, own: own, passedOver: passed)
    }
}

/// Where an app stands to a look with no place named.
public enum Standing: Sendable, Hashable {
    /// The app that look reads.
    case front(Front.App)
    /// An app with a window over that app's front window where a click lands in it - an Open
    /// panel another process draws - which that look reads too.
    case overFront(Front.App)
    /// The app eyes answers to, named: the agent's own terminal or Claude app, never read.
    case own(String)
    /// In no window of its own listed at the point - a menu bar, a menu - which that look,
    /// walking windows, never reads; with the app it reads.
    case noWindow(Front.App)
    /// On a display that look does not read, with the app it reads and the display it does.
    case otherDisplay(Front.App, CGDirectDisplayID)
    /// An app that look does not read, with the app it reads, nil when there is none.
    case behind(Front.App?)

    /// The app a look with no place named reads, when there is one.
    public var front: Front.App? {
        switch self {
        case .front(let app), .overFront(let app), .noWindow(let app), .otherDisplay(let app, _), .behind(let app?): app
        case .own, .behind(nil): nil
        }
    }

    public var said: String {
        switch self {
        case .front: "front"
        case .overFront: "over_front"
        case .own: "own"
        case .otherDisplay: "other_display"
        case .noWindow: "no_window"
        case .behind: "behind"
        }
    }
}

extension WindowListing {
    /// The window server's level for document and main windows. An app's front window is its
    /// frontmost one here, not whatever of it is listed first: a status item in the menu bar
    /// (25) or an open menu (101) is listed above every ordinary window. The level is the
    /// window server's own constant, not a threshold this module invents.
    static let ordinary = Int(CGWindowLevelForKey(.normalWindow))

    /// Where the frontmost ordinary window of a process `of` accepts is listed.
    func front(where of: (Int32) -> Bool) -> Int? {
        windows.firstIndex { $0.layer == Self.ordinary && of($0.pid) }
    }

    /// Where an app's front window is listed.
    func front(of pid: Int32) -> Int? { front { $0 == pid } }
}

/// A look with no place named has nothing it could mean: no app but the one eyes answers to
/// has a window on screen, or no display is attached. [LAW:no-silent-failure]
public struct NoFront: Error, Equatable, CustomStringConvertible {
    public let own: String
    public let why: Why

    public enum Why: Sendable, Equatable {
        case onlyOwn
        /// Between a display detached and the next attached, as when one is unplugged mid-read.
        case noDisplay
    }

    public init(own: String, why: Why) {
        self.own = own
        self.why = why
    }

    public var description: String {
        switch why {
        case .onlyOwn: "no app but \(own), which eyes answers to, has a window on screen; name a display to read every app on it"
        case .noDisplay: "no display is attached, so there is no screen to read"
        }
    }
}

/// Which processes' windows a reading takes in: every one, or only some.
public enum Owners: Sendable, Hashable {
    case every
    case only(Set<Int32>)

    /// Whether a window of this process is read.
    public func hold(_ pid: Int32) -> Bool {
        switch self {
        case .every: true
        case .only(let pids): pids.contains(pid)
        }
    }

    /// What two readers of one look took in between them.
    public func union(_ other: Owners) -> Owners {
        switch (self, other) {
        case (.only(let a), .only(let b)): .only(a.union(b))
        default: .every
        }
    }

    /// Whether a run at `point` is the owners', for a reader that sees what is on top
    /// rather than walking windows: read, or set aside - outside every owner window, or
    /// under a window in front as the tree sets an element aside, covered, or overlaid when
    /// the hit test does not settle it. [LAW:single-enforcer] The rule is `Covers`, the tree's own.
    public func see(_ point: ScreenPoint, windows: [Window], hit: @escaping (ScreenPoint) -> Heard<Int32>) -> Seen {
        guard case .only = self else { return .read }
        guard let index = windows.firstIndex(where: { hold($0.pid) && $0.frame.contains(point) }) else { return .setAside(.outside) }
        let covers = Covers(windows: windows[..<index].map { Cover(frame: $0.frame, pid: $0.pid) }, owner: windows[index].pid, hit: hit)
        switch covers.hide(point) {
        case .answered(false): return .read
        case .answered(true): return .setAside(.covered)
        case .unanswered: return .setAside(.overlaid)
        }
    }

    public enum Seen: Equatable {
        case read
        case setAside(Exclusion.Reason)
    }
}

public extension Region {
    /// The processes a read of this region takes in, from the windows on screen at that
    /// read. Every region but the front is every process's; a reader asks rather than
    /// branching on the region. [LAW:dataflow-not-control-flow]
    func owners(in listing: WindowListing, hit: (ScreenPoint) -> Heard<Int32>) -> Owners {
        switch self {
        case .front(let front): .only(front.owners(in: listing, hit: hit))
        case .display, .window, .rect, .page: .every
        }
    }
}
