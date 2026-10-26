import CoreGraphics

/// The app a look with no place named reads: the one an agent is working in.
///
/// The frontmost app is where keys go, so it is that app - unless it is the app eyes answers
/// to, the agent's own terminal or Claude app, which echoes on screen the very text it asks
/// eyes to find. Then it is the app of the frontmost window behind it. What is read is that
/// app's windows and whatever is stacked in front of its front window - a remote Open panel,
/// a service's popover - derived afresh from each read's own window list by `owners(in:)`,
/// so a panel that opens during a wait is read from the next read on. Only what a wait must
/// keep is held here. [LAW:one-source-of-truth]
public struct Front: Sendable, Hashable {
    public let app: App
    /// The display holding the app's front window, read whole and cut to the owners' windows.
    public let display: CGDirectDisplayID
    /// The app eyes answers to, when it was in front and passed over: its windows are never
    /// read, wherever they are stacked.
    public let passedOver: Passed?

    public init(app: App, display: CGDirectDisplayID, passedOver: Passed?) {
        self.app = app
        self.display = display
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
    /// process with a window in front of the app's frontmost one - listed above it and over
    /// it - less the app eyes answers to. Over it, and not merely above: the menu bar is
    /// listed above every window and shows the frontmost app's menus, which with the app eyes
    /// answers to in front are that app's own.
    public func owners(in listing: WindowListing) -> Set<Int32> {
        let front = listing.windows.firstIndex { $0.pid == app.pid }
        let over = front.map { i in listing.windows[..<i].filter { $0.frame.intersects(listing.windows[i].frame) } } ?? []
        return Set(over.map(\.pid)).union([app.pid]).subtracting(passedOver?.pids ?? [])
    }

    /// The app a look with no place named reads, from facts the caller gathered.
    ///
    /// - frontmost: the app AppKit names frontmost, when any is.
    /// - own: the app eyes answers to.
    /// - regular: the processes that are ordinary apps (AppKit's `.regular` activation
    ///   policy), which is what "an app behind" can be - not the Dock, the menu bar or a
    ///   service's panel.
    /// - names: what each of those apps is called.
    public static func choose(frontmost: App?, own: Passed, regular: Set<Int32>, names: [Int32: String],
                              listing: WindowListing, displays: [Display]) throws(NoFront) -> Front {
        let app: App
        let passed: Passed?
        if let frontmost, !own.pids.contains(frontmost.pid) {
            (app, passed) = (frontmost, nil)
        } else if let behind = listing.windows.first(where: { regular.contains($0.pid) && !own.pids.contains($0.pid) }) {
            (app, passed) = (App(pid: behind.pid, name: names[behind.pid] ?? behind.owner), own)
        } else {
            throw NoFront(own: own.name)
        }
        let window = listing.windows.first { $0.pid == app.pid }
        let display = window.flatMap { w in displays.first { $0.frame.contains(w.frame.centre) } } ?? displays.first { $0.isMain }
        guard let display else { throw NoFront(own: own.name) }
        return Front(app: app, display: display.id, passedOver: passed)
    }
}

/// No app but the one eyes answers to has a window on screen: a look with no place named
/// has nothing it could mean. [LAW:no-silent-failure]
public struct NoFront: Error, Equatable, CustomStringConvertible {
    public let own: String

    public init(own: String) { self.own = own }

    public var description: String {
        "no app but \(own), which eyes answers to, has a window on screen; name a display to read every app on it"
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
    /// rather than walking windows: read, outside every owner window (out of the region, as
    /// text outside a rect is), or set aside under a window in front as the tree sets an
    /// element aside - covered, or overlaid when the hit test does not settle it.
    /// [LAW:single-enforcer] The rule is `Covers`, the tree's own.
    public func see(_ point: ScreenPoint, windows: [Window], hit: @escaping (ScreenPoint) -> Heard<Int32>) -> Seen {
        guard case .only = self else { return .read }
        guard let index = windows.firstIndex(where: { hold($0.pid) && $0.frame.contains(point) }) else { return .outside }
        let covers = Covers(windows: windows[..<index].map { Cover(frame: $0.frame, pid: $0.pid) }, owner: windows[index].pid, hit: hit)
        switch covers.hide(point) {
        case .answered(false): return .read
        case .answered(true): return .setAside(.covered)
        case .unanswered: return .setAside(.overlaid)
        }
    }

    public enum Seen: Equatable {
        case read
        case outside
        case setAside(Exclusion.Reason)
    }
}

public extension Region {
    /// The processes a read of this region takes in, from the windows on screen at that
    /// read. Every region but the front is every process's; a reader asks rather than
    /// branching on the region. [LAW:dataflow-not-control-flow]
    func owners(in listing: WindowListing) -> Owners {
        switch self {
        case .front(let front): .only(front.owners(in: listing))
        case .display, .window, .rect, .page: .every
        }
    }
}
