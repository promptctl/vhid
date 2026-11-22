import ScreenSpace

/// The screen as one answer reads it: which app is frontmost, which app is the agent's own,
/// what is running, the windows on screen and the display layout, read once, frontmost
/// first - an activation lands before the listing that reflects it.
///
/// [LAW:one-source-of-truth] The displays and windows an answer lists, the app it chooses
/// to read, and where a click it was asked about lands are judged against this one value,
/// so those parts of an answer describe one moment. The text read in the chosen place is
/// read after it, by readers that read the screen as they read - a wait reads it many times;
/// the first read of a place chosen here reads on this layout.
public struct Desk: Sendable {
    public let frontmost: Front.App?
    public let own: Front.Passed
    public let running: [Running]
    public let listing: WindowListing
    public let layout: DisplayLayout
    /// The layout's active displays, main first: derived from it in the init, so the displays
    /// an answer lists are the ones its app was chosen and its point placed on.
    /// [LAW:one-source-of-truth]
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

    /// `describe` says what the window server says of each active display beyond its place:
    /// `Geometry.describe` in the process, a test's own in a test. [LAW:effects-at-boundaries]
    public init(frontmost: Front.App?, own: Front.Passed, running: [Running], listing: WindowListing, layout: DisplayLayout,
                describe: (OnlineDisplay) -> Display) {
        self.frontmost = frontmost
        self.own = own
        self.running = running
        self.listing = listing
        self.layout = layout
        self.displays = Geometry.displays(in: layout, describe: describe)
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
