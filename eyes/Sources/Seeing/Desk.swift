/// The screen as one answer reads it: which app is frontmost, which app eyes answers to,
/// what is running, the windows on screen and the displays, read once, frontmost first -
/// an activation lands before the listing that reflects it.
///
/// [LAW:one-source-of-truth] Every part of one answer - the displays and windows it lists,
/// the app it chooses to read, where a click it was asked about lands - is judged against
/// this one value, so no two parts of an answer describe two moments.
public struct Desk: Sendable {
    public let frontmost: Front.App?
    public let own: Front.Passed
    public let running: [Running]
    public let listing: WindowListing
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

    public init(frontmost: Front.App?, own: Front.Passed, running: [Running], listing: WindowListing, displays: [Display]) {
        self.frontmost = frontmost
        self.own = own
        self.running = running
        self.listing = listing
        self.displays = displays
    }

    func isRegular(_ pid: Int32) -> Bool { running.contains { $0.app.pid == pid && $0.regular } }

    /// The app a window belongs to, by the name AppKit gives it, or the window server's.
    public func app(of window: Window) -> Front.App {
        running.first { $0.app.pid == window.pid }?.app ?? Front.App(pid: window.pid, name: window.owner)
    }
}
