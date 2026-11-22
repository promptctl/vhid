import CoreGraphics
import ScreenSpace

/// The app a look reads: the one it was told, or with no app named, the one a person sees
/// in front.
///
/// The frontmost app is where keys go, and with a window open it is what a person sees in
/// front - unless it is the agent's own app, its terminal or Claude app,
/// which echoes on screen the very text it asks eyes to find. Then, and when the frontmost
/// app has no window open - Finder over the desktop, an app whose last window closed - it
/// gives way to the app of the frontmost ordinary window, which is what is in front to see.
/// What is read is that app's windows and whatever is stacked in front of its front window
/// - a remote Open panel, a service's popover - derived afresh from each read's own window
/// list by `owners(in:hit:)`, so a panel that opens during a wait is read from the next read
/// on. Only what a wait must keep is held here. [LAW:one-source-of-truth]
public struct Front: Sendable, Hashable {
    public let app: App
    /// The display holding most of the app's front window, read whole and cut to the owners' windows.
    public let display: CGDirectDisplayID
    /// The agent's own app: its windows are never read, wherever they are stacked - in
    /// front and passed over, or a window over the front app's.
    public let own: Passed
    /// The frontmost app, when it gave way to the app behind it.
    public let passedOver: PassedOver?

    public init(app: App, display: CGDirectDisplayID, own: Passed, passedOver: PassedOver?) {
        self.app = app
        self.display = display
        self.own = own
        self.passedOver = passedOver
    }

    /// Why the frontmost app gave way: it is the agent's own app, or it has no window open.
    public enum PassedOver: Sendable, Hashable {
        case own(String)
        case windowless(App)
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

        /// Whether this is the app a caller named: by its name exactly as AppKit lists it,
        /// so a name never means two apps that merely share words. [LAW:single-enforcer] The
        /// one rule a named app is matched by, for a look and an act alike.
        public func isCalled(_ name: String) -> Bool { self.name == name }
    }

    /// The agent's own app: every process running from its bundle, and its name.
    public struct Passed: Sendable, Hashable {
        public let pids: Set<Int32>
        public let name: String

        public init(pids: Set<Int32>, name: String) {
            self.pids = pids
            self.name = name
        }
    }

    /// The app a look with no app named reads, on `desk`. [LAW:single-enforcer]
    public static func choose(on desk: Desk) throws(AppUnread) -> Front {
        if let first = desk.frontmost, !desk.own.pids.contains(first.pid), desk.listing.front(of: first.pid) != nil {
            return try Front(first, passedOver: nil, on: desk)
        }
        let readable = { (pid: Int32) in desk.isRegular(pid) && !desk.own.pids.contains(pid) }
        guard let behind = desk.listing.front(where: readable) else {
            throw desk.listing.front(where: { desk.own.pids.contains($0) }) == nil ? .nothingOnScreen : .noOrdinaryWindow(own: desk.own.name)
        }
        let passed = desk.frontmost.map { desk.own.pids.contains($0.pid) ? PassedOver.own(desk.own.name) : .windowless($0) }
        return try Front(desk.app(of: desk.listing.windows[behind]), passedOver: passed, on: desk)
    }

    /// The app called `name` on `desk`: of the instances running under that name, other than
    /// the agent's own app, the one whose window is frontmost.
    public static func named(_ name: String, on desk: Desk) throws(AppUnread) -> Front {
        let called = desk.running.map(\.app).filter { $0.isCalled(name) }
        guard !called.isEmpty else {
            throw .notRunning(name, ordinary: Set(desk.running.filter(\.regular).compactMap(\.app.name)).sorted())
        }
        let others = called.filter { !desk.own.pids.contains($0.pid) }
        guard let first = others.first else { throw .own(name) }
        let shown = others.compactMap { app in desk.listing.front(of: app.pid).map { (app: app, place: $0) } }
        guard let chosen = shown.min(by: { $0.place < $1.place }) else { throw .noWindow(first) }
        return try Front(chosen.app, passedOver: nil, on: desk)
    }

    /// `app` on the display holding most of its front window.
    private init(_ app: App, passedOver: PassedOver?, on desk: Desk) throws(AppUnread) {
        guard !desk.displays.isEmpty else { throw .noDisplay }
        guard let window = desk.listing.front(of: app.pid).map({ desk.listing.windows[$0] }) else { throw .noWindow(app) }
        let shown = { (display: Display) in display.frame.overlap(window.frame) }
        guard let display = desk.displays.max(by: { shown($0) < shown($1) }), shown(display) > 0 else { throw .offDisplays(app) }
        self.init(app: app, display: display.id, own: desk.own, passedOver: passedOver)
    }

    /// The processes this read takes in, from the windows on screen now: the app, and every
    /// process with a window in front of the app's front window that a click there lands in -
    /// a remote Open panel, a service's popover - less the agent's own app.
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
                window.frame.intersection(listing.windows[i].frame).map { hit($0.centre) == .answered(window.pid) } ?? false
            }
        } ?? []
        return Set(over.map(\.pid)).union([app.pid]).subtracting(own.pids)
    }

    /// Where an app a click at `point` lands in stands to a look with no place named, by the
    /// rules that look reads by: `own`, its one display, the windows it walks, and `owners`.
    /// [LAW:single-enforcer] `front` is what that look would read on `desk`, or why it reads nothing.
    /// The point is placed on the desk's active displays, so it is on one of them.
    public static func standing(of pid: Int32, at placed: Placed<ScreenPoint>, on desk: Desk, front: Result<Front, AppUnread>,
                                hit: (ScreenPoint) -> Heard<Int32>) -> Standing {
        let point = placed.value
        if desk.own.pids.contains(pid) { return .own(desk.own.name) }
        let read: Front
        switch front {
        case .success(let front): read = front
        case .failure(let why): return .unread(why)
        }
        guard desk.displays.contains(where: { $0.id == read.display && $0.frame.contains(point) }) else {
            return .otherDisplay(read.app, read.display)
        }
        guard desk.listing.windows.contains(where: { $0.pid == pid && $0.frame.contains(point) }) else { return .noWindow(read.app) }
        if pid == read.app.pid { return .front(read.app) }
        return read.owners(in: desk.listing, hit: hit).contains(pid) ? .overFront(read.app) : .behind(read.app)
    }
}

/// Where an app stands to a look with no place named.
public enum Standing: Sendable, Hashable {
    /// The app that look reads.
    case front(Front.App)
    /// An app with a window over that app's front window where a click lands in it - an Open
    /// panel another process draws - which that look reads too.
    case overFront(Front.App)
    /// The agent's own app, named: its terminal or Claude app, never read.
    case own(String)
    /// In no window of its own listed at the point - a menu bar, a menu - which that look,
    /// walking windows, never reads; with the app it reads.
    case noWindow(Front.App)
    /// On a display that look does not read, with the app it reads and the display it does.
    case otherDisplay(Front.App, CGDirectDisplayID)
    /// An app that look does not read, with the app it reads.
    case behind(Front.App)
    /// An app that look does not read, because it reads no app, and why.
    case unread(AppUnread)

    /// The app a look with no place named reads, when there is one.
    public var front: Front.App? {
        switch self {
        case .front(let app), .overFront(let app), .noWindow(let app), .otherDisplay(let app, _), .behind(let app): app
        case .own, .unread: nil
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
        case .unread: "unread"
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

/// Why a look has no app to read: each state an app can be in that leaves nothing of it to
/// read, built from what the desk said of it. [LAW:types-are-the-program] [LAW:no-silent-failure]
public enum AppUnread: Error, Hashable, CustomStringConvertible {
    /// No app but the agent's own has a window on screen.
    case noOrdinaryWindow(own: String)
    /// No app has a window on screen at all.
    case nothingOnScreen
    /// No running app is called this; the ordinary apps that are running, by name.
    case notRunning(String, ordinary: [String])
    /// The app named is the agent's own, whose windows a look never reads.
    case own(String)
    /// The app is running with no window on screen.
    case noWindow(Front.App)
    /// The app's front window is on none of the displays that are active.
    case offDisplays(Front.App)
    /// No display is active: none attached, or every one asleep.
    case noDisplay

    public var description: String {
        switch self {
        case .noOrdinaryWindow(let own):
            "no app but \(own), the agent's own, has a window on screen; name a display to read every app on it"
        case .nothingOnScreen:
            "no app has a window on screen; name a display to read what is on it"
        case .notRunning(let name, let ordinary):
            "no running app is called \(name.debugDescription), named exactly as it is listed; running: "
                + (ordinary.isEmpty ? "none" : ordinary.joined(separator: ", "))
        case .own(let name):
            "\(name) is the agent's own app, whose windows a look never reads"
        case .noWindow(let app):
            "\(app) has no window on screen, so there is nothing of it to read"
        case .offDisplays(let app):
            "\(app) has its front window on no active display, so there is nothing of it to read"
        case .noDisplay:
            "no display is active - none is attached, or each is asleep - so there is no screen to read"
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
