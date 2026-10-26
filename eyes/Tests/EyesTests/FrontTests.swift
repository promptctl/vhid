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
        #expect(front == Front(app: Front.App(pid: 400, name: "Safari"), display: 1, own: Self.terminal, passedOver: false))
    }

    /// The agent's own terminal echoes what it searches for, so with it in front the app of
    /// the frontmost ordinary window behind it is read - not the menu bar's owner.
    @Test func theAgentsOwnTerminalInFrontIsPassedOverForTheAppBehindIt() throws {
        let front = try Self.choose(frontmost: Front.App(pid: 81, name: "iTerm2"))
        #expect(front.app == Front.App(pid: 300, name: "System Settings"))
        #expect(front.passedOver)
        // Its front window's centre is on the display left of the main one.
        #expect(front.display == 2)
    }

    /// With no app named frontmost, the app of the frontmost ordinary window stands for it -
    /// and is passed over only when it is the agent's own terminal.
    @Test func noFrontmostAppReadsTheAppOfTheFrontmostOrdinaryWindow() throws {
        let terminalFirst = try Self.choose(frontmost: nil)
        #expect(terminalFirst.app.pid == 300)
        #expect(terminalFirst.passedOver)
        let safariFirst = WindowListing(windows: [Self.menuBar, Self.window(4, "Safari", pid: 400), Self.window(2, "iTerm2", pid: 80)], excluded: [])
        let safari = try Self.choose(frontmost: nil, listing: safariFirst)
        #expect(safari == Front(app: Front.App(pid: 400, name: "Safari"), display: 1, own: Self.terminal, passedOver: false))
    }

    /// A status item in the menu bar is listed above every ordinary window, so an app with
    /// one is not the app behind for that, and its front window is its ordinary one.
    @Test func aStatusItemIsNotAnAppsFrontWindow() throws {
        let statusItem = Window(id: 8, owner: "1Password", pid: 500, frame: ScreenRect(x: -1900, y: 0, width: 30, height: 24), layer: 25)
        let note = Window(id: 7, owner: "1Password", pid: 500, frame: ScreenRect(x: 100, y: 100, width: 300, height: 300), layer: 0)
        let listing = WindowListing(windows: [statusItem, Self.menuBar] + Self.desk.windows.dropFirst() + [note], excluded: [])
        let front = try Front.choose(frontmost: Front.App(pid: 80, name: "iTerm2"), own: Self.terminal, regular: [80, 300, 400, 500],
                                     names: [300: "System Settings", 500: "1Password"], listing: listing, displays: [Self.main, Self.left])
        #expect(front.app.pid == 300)
        #expect(try Self.choose(frontmost: Front.App(pid: 500, name: "1Password"), listing: listing).display == 1)
    }

    @Test func anAppWithNoWindowOnScreenIsReadOnTheMainDisplay() throws {
        #expect(try Self.choose(frontmost: Front.App(pid: 500, name: "Finder")).display == 1)
    }

    /// Nothing but the agent's own terminal: no place it could mean, so a refusal naming it.
    @Test func onlyTheAppEyesAnswersToOnScreenIsARefusal() {
        let alone = WindowListing(windows: [Self.menuBar, Self.window(2, "iTerm2", pid: 80)], excluded: [])
        #expect(throws: NoFront(own: "iTerm2", why: .onlyOwn)) { try Self.choose(frontmost: Front.App(pid: 80, name: "iTerm2"), listing: alone) }
        #expect(NoFront(own: "iTerm2", why: .onlyOwn).description.contains("no app but iTerm2, which eyes answers to, has a window on screen"))
    }

    /// With no display attached - one unplugged mid-read - the refusal says so, and not that
    /// nothing else is on screen.
    @Test func noDisplayIsARefusalSayingSo() {
        #expect(throws: NoFront(own: "iTerm2", why: .noDisplay)) {
            try Front.choose(frontmost: Front.App(pid: 300, name: "System Settings"), own: Self.terminal, regular: [300],
                             names: [:], listing: Self.desk, displays: [])
        }
        #expect(NoFront(own: "iTerm2", why: .noDisplay).description == "no display is attached, so there is no screen to read")
    }

    /// The app, and whatever is in front of its front window that a click there lands in - a
    /// remote Open panel over it - but never what is behind it or the agent's own terminal.
    @Test func theOwnersAreTheAppAndWhatIsOverItLessTheAppPassedOver() {
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1, own: Self.terminal, passedOver: true)
        let panel = WindowListing(windows: [Self.window(9, "Open and Save Panel Service", pid: 900, x: -900)] + Self.desk.windows, excluded: [])
        let landsInPanel: (ScreenPoint) -> Heard<Int32> = { _ in .answered(900) }
        #expect(front.owners(in: Self.desk, hit: landsInPanel) == [300])
        #expect(front.owners(in: panel, hit: landsInPanel) == [900, 300])
        #expect(Region.front(front).owners(in: panel, hit: landsInPanel) == .only([900, 300]))
    }

    /// A frame over the front window says only where a window could be drawn. Notification
    /// Center's covers the whole screen and draws nothing there; the menu bar shows the front
    /// app's menus. A click there landing elsewhere, or not answering, takes neither in.
    @Test func aWindowOverTheFrontOneIsTakenInOnlyWhereAClickLandsInIt() {
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1, own: Self.terminal, passedOver: false)
        let center = Window(id: 6, owner: "Notification Center", pid: 700, frame: ScreenRect(x: -1920, y: 0, width: 3432, height: 1080), layer: 23)
        let listing = WindowListing(windows: [center, Self.menuBar, Self.window(3, "System Settings", pid: 300, x: -1000)], excluded: [])
        var asked: [ScreenPoint] = []
        #expect(front.owners(in: listing) { asked.append($0); return .answered(300) } == [300])
        // Notification Center at the front window's centre; the menu bar does not reach it.
        #expect(asked == [ScreenPoint(x: -700, y: 240)])
        #expect(front.owners(in: listing) { _ in .unanswered } == [300])
        #expect(front.owners(in: listing) { _ in .answered(700) } == [700, 300])
    }

    /// The agent's own terminal over the front app's window is never read, though it was not
    /// the app in front: it echoes what the agent searches for.
    @Test func theAppEyesAnswersToOverTheFrontAppIsNotReadEither() {
        let front = Front(app: Front.App(pid: 400, name: "Safari"), display: 1, own: Self.terminal, passedOver: false)
        let floating = WindowListing(windows: [Self.window(2, "iTerm2", pid: 81, layer: 3), Self.window(4, "Safari", pid: 400)], excluded: [])
        #expect(front.owners(in: floating) { _ in .answered(81) } == [400])
    }

    @Test func everyOtherRegionReadsEveryProcess() {
        for region: Region in [.display(1), .window(3), .rect(Self.main.frame), .page(window: 3, frame: Self.main.frame)] {
            #expect(region.owners(in: Self.desk) { _ in Issue.record("hit test asked"); return .unanswered } == .every)
        }
    }

    /// Where an app a click lands in stands is the front look's own rule: the app it reads, a
    /// window over that app's it reads too - the remote Open panel - the agent's own terminal,
    /// or behind. The terminal in front, passed over, is the terminal, not the front app.
    @Test func whereAHitAppStandsIsDecidedByTheFrontLooksRule() {
        let settings = Front.App(pid: 300, name: "System Settings")
        let front = Front(app: settings, display: 1, own: Self.terminal, passedOver: true)
        let panel = WindowListing(windows: [Self.window(9, "Open and Save Panel Service", pid: 900, x: -900)] + Self.desk.windows, excluded: [])
        let landsInPanel: (ScreenPoint) -> Heard<Int32> = { _ in .answered(900) }
        let standing = { (pid: Int32, front: Front?) in
            Front.standing(of: pid, at: ScreenPoint(x: 100, y: 100), own: Self.terminal, front: front, in: panel,
                           displays: [Self.main, Self.left], hit: landsInPanel)
        }
        #expect(standing(300, front) == .front(settings))
        #expect(standing(900, front) == .overFront(settings))
        #expect(standing(80, front) == .own("iTerm2"))
        #expect(standing(81, front) == .own("iTerm2"))
        #expect(standing(400, front) == .behind(settings))
        // With nothing but the terminal on screen there is no front to read.
        #expect(standing(80, nil) == .own("iTerm2"))
        #expect(standing(400, nil) == .behind(nil))
        // A front look reads one display: a hit on another is not read, the front app's own
        // window there included.
        let onLeft = { (pid: Int32) in
            Front.standing(of: pid, at: ScreenPoint(x: -500, y: 100), own: Self.terminal, front: front, in: panel,
                           displays: [Self.main, Self.left], hit: landsInPanel)
        }
        #expect(onLeft(300) == .otherDisplay(settings, 1))
        #expect(onLeft(900) == .otherDisplay(settings, 1))
        #expect(onLeft(80) == .own("iTerm2"))
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
        #expect(Owners.only([300]).see(Self.onlyBehind, windows: [Self.app, Self.behind], hit: Self.asked) == .setAside(.outside))
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
