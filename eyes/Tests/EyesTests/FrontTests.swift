import Testing
@testable import Eyes

/// What a look with no place named reads: the app an agent is working in, from listings a
/// test writes.
@Suite struct FrontTests {
    static let main = Display(id: 1, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), isMain: true, scale: 2)
    static let left = Display(id: 2, frame: ScreenRect(x: -1920, y: 0, width: 1920, height: 1080), isMain: false, scale: 1)
    static let terminal = Front.Passed(pids: [80, 81], name: "iTerm2")

    static func window(_ id: UInt32, _ owner: String, pid: Int32, x: Double = 0, layer: Int = 0) -> Window {
        Window(id: id, owner: owner, pid: pid, frame: ScreenRect(x: x, y: 40, width: 600, height: 400), layer: layer)
    }

    static let menuBar = Window(id: 1, owner: "Window Server", pid: 1, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 33), layer: 24)

    /// The menu bar, the agent's terminal, System Settings with Safari behind it.
    static let desk = WindowListing(windows: [
        menuBar,
        window(2, "iTerm2", pid: 80),
        window(3, "System Settings", pid: 300, x: -1000),
        window(4, "Safari", pid: 400),
    ], excluded: [])

    static func choose(frontmost: Front.App?, listing: WindowListing = desk) throws(NoFront) -> Front {
        try Front.choose(frontmost: frontmost, own: terminal, regular: [80, 300, 400], names: [300: "System Settings", 400: "Safari"],
                         listing: listing, displays: [main, left])
    }

    @Test func theFrontmostAppIsReadWhenItIsNotTheOneEyesAnswersTo() throws {
        let front = try Self.choose(frontmost: Front.App(pid: 400, name: "Safari"))
        #expect(front == Front(app: Front.App(pid: 400, name: "Safari"), display: 1, passedOver: nil))
    }

    /// The agent's own terminal echoes what it searches for, so with it in front the app of
    /// the frontmost ordinary window behind it is read - not the menu bar's owner.
    @Test func theAgentsOwnTerminalInFrontIsPassedOverForTheAppBehindIt() throws {
        let front = try Self.choose(frontmost: Front.App(pid: 81, name: "iTerm2"))
        #expect(front.app == Front.App(pid: 300, name: "System Settings"))
        #expect(front.passedOver == Self.terminal)
        // Its front window's centre is on the display left of the main one.
        #expect(front.display == 2)
    }

    @Test func noFrontmostAppReadsTheAppOfTheFrontmostOrdinaryWindow() throws {
        #expect(try Self.choose(frontmost: nil).app.pid == 300)
    }

    @Test func anAppWithNoWindowOnScreenIsReadOnTheMainDisplay() throws {
        #expect(try Self.choose(frontmost: Front.App(pid: 500, name: "Finder")).display == 1)
    }

    /// Nothing but the agent's own terminal: no place it could mean, so a refusal naming it.
    @Test func onlyTheAppEyesAnswersToOnScreenIsARefusal() {
        let alone = WindowListing(windows: [Self.menuBar, Self.window(2, "iTerm2", pid: 80)], excluded: [])
        #expect(throws: NoFront(own: "iTerm2")) { try Self.choose(frontmost: Front.App(pid: 80, name: "iTerm2"), listing: alone) }
        #expect(NoFront(own: "iTerm2").description.contains("no app but iTerm2, which eyes answers to, has a window on screen"))
    }

    /// The app, and whatever is in front of its front window - a remote Open panel over it -
    /// but never what is behind it, the agent's own terminal, or the menu bar above it, which
    /// shows the terminal's menus while the terminal is frontmost.
    @Test func theOwnersAreTheAppAndWhatIsOverItLessTheAppPassedOver() {
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1, passedOver: Self.terminal)
        let panel = WindowListing(windows: [Self.window(9, "Open and Save Panel Service", pid: 900, x: -900)] + Self.desk.windows, excluded: [])
        #expect(front.owners(in: Self.desk) == [300])
        #expect(front.owners(in: panel) == [900, 300])
        #expect(Region.front(front).owners(in: panel) == .only([900, 300]))
    }

    @Test func everyOtherRegionReadsEveryProcess() {
        for region: Region in [.display(1), .window(3), .rect(Self.main.frame), .page(window: 3, frame: Self.main.frame)] {
            #expect(region.owners(in: Self.desk) == .every)
        }
    }

    @Test func twoReadersOwnersAreTheirUnion() {
        #expect(Owners.only([1]).union(.only([2])) == .only([1, 2]))
        #expect(Owners.only([1]).union(.every) == .every)
    }
}

/// Which runs a reader that sees what is on top keeps for the owners: the tree's rule for a
/// window in front, `Covers`.
@Suite struct OwnersSeeTests {
    static let app = Window(id: 3, owner: "System Settings", pid: 300, frame: ScreenRect(x: 0, y: 0, width: 600, height: 400), layer: 0)
    static let over = Window(id: 4, owner: "Notification Center", pid: 700, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), layer: 23)
    static let behind = Window(id: 5, owner: "Safari", pid: 400, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), layer: 0)
    static let inApp = ScreenPoint(x: 100, y: 100)
    static let onlyBehind = ScreenPoint(x: 1000, y: 100)
    static let asked: @Sendable (ScreenPoint) -> Heard<Int32> = { _ in Issue.record("hit test asked"); return .unanswered }

    @Test func everyProcessReadsEveryRunWithoutAskingTheHitTest() {
        #expect(Owners.every.see(Self.onlyBehind, windows: [Self.app, Self.behind], hit: Self.asked) == .read)
    }

    @Test func aRunInNoOwnerWindowIsOutside() {
        #expect(Owners.only([300]).see(Self.onlyBehind, windows: [Self.app, Self.behind], hit: Self.asked) == .outside)
    }

    @Test func aRunInAnOwnerWindowWithNothingInFrontIsRead() {
        #expect(Owners.only([300]).see(Self.inApp, windows: [Self.app, Self.behind], hit: Self.asked) == .read)
    }

    /// A frame in front says only where a window could be drawn: the hit test settles it.
    @Test func aWindowInFrontHidesARunOnlyWhereTheHitTestLandsInIt() {
        let windows = [Self.over, Self.app, Self.behind]
        #expect(Owners.only([300]).see(Self.inApp, windows: windows) { _ in .answered(300) } == .read)
        #expect(Owners.only([300]).see(Self.inApp, windows: windows) { _ in .answered(700) } == .setAside(.covered))
        #expect(Owners.only([300]).see(Self.inApp, windows: windows) { _ in .unanswered } == .setAside(.overlaid))
    }
}
