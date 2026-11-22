import ScreenSpace

/// The screen as one answer reads it: which app is frontmost, which app is the agent's own,
/// what is running, the windows on screen and the displays, read once, frontmost first -
/// an activation lands before the listing that reflects it.
///
/// [LAW:one-source-of-truth] The displays and windows an answer lists, the app it chooses
/// to read, where a click it was asked about lands, and the first read of the chosen place
/// are judged against this one value, so those parts of an answer describe one moment. A
/// wait's later reads read the layout again, as they read the screen again.
public struct Desk: Sendable {
    public let frontmost: Front.App?
    public let own: Front.Passed
    public let running: [Running]
    public let listing: WindowListing
    /// The display layout, read once, which every question of where something is on the
    /// displays is asked of.
    public let layout: DisplayLayout
    /// The active displays as `eyes displays` lists them, from `layout`.
    public let displays: [Display]

    /// A running application, and whether it is an ordinary one - AppKit's `.regular`
    /// activation policy - which is what "the app behind" can be: not the Dock, the menu bar
    /// or a service's panel.
    public struct Running: Sendable, Hashable {
        public let app: Front.App
        public let regular: Bool

        public init(app: Front.App, regular: Bool) {
            self.app = app
            self.regular = regular
        }
    }

    /// `describe` says how each active display of `layout` is listed: the window server's
    /// main display and scale in the process, written by a test.
    public init(frontmost: Front.App?, own: Front.Passed, running: [Running], listing: WindowListing, layout: DisplayLayout,
                describe: (DisplayLayout) -> [Display]) {
        self.frontmost = frontmost
        self.own = own
        self.running = running
        self.listing = listing
        self.layout = layout
        displays = describe(layout)
    }

    func isRegular(_ pid: Int32) -> Bool { running.contains { $0.app.pid == pid && $0.regular } }

    /// The app a window belongs to, by the name AppKit gives it, or the window server's.
    public func app(of window: Window) -> Front.App { app(window.pid, owner: window.owner) }

    /// The app running as `pid`, by the name AppKit gives it, or else `owner`, the name the
    /// window server lists its window under. [LAW:one-source-of-truth] The one way a pid
    /// is named, so one pid is not called two things.
    public func app(_ pid: Int32, owner: String?) -> Front.App {
        running.first { $0.app.pid == pid }?.app ?? Front.App(pid: pid, name: owner)
    }
}
