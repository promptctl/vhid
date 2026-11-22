import ScreenSpace
import ScreenSpaceTesting
import Testing
@testable import Seeing

/// What a look reads: the app it names, or with none named the app a person sees in front,
/// from desks a test writes.
@Suite struct FrontTests {
    static let main = Display(OnlineDisplay(id: 1, frame: .at(0, 0, 1512, 982), active: true), isMain: true, scale: 2)
    static let left = Display(OnlineDisplay(id: 2, frame: .at(-1920, 0, 1920, 1080), active: true), isMain: false, scale: 1)
    static let terminal = Front.Passed(pids: [80, 81], name: "iTerm2")
    static let settings = Front.App(pid: 300, name: "System Settings")
    static let safari = Front.App(pid: 400, name: "Safari")
    static let finder = Front.App(pid: 500, name: "Finder")

    static func window(_ id: UInt32, _ owner: String, pid: Int32, x: Double = 0, layer: Int = 0) -> Window {
        Window(id: id, owner: owner, pid: pid, frame: ScreenRect.at(x, 40, 600, 400), layer: layer)
    }

    static let menuBar = Window(id: 1, owner: "Window Server", pid: 1, frame: ScreenRect.at(0, 0, 1512, 33), layer: 24)

    /// The menu bar, the agent's terminal, System Settings on the left display with Safari behind it.
    static let listing = WindowListing(windows: [
        menuBar,
        window(2, "iTerm2", pid: 80),
        window(3, "System Settings", pid: 300, x: -1000),
        window(4, "Safari", pid: 400),
    ], excluded: [])

    static let running = [
        Desk.Running(app: Front.App(pid: 1, name: "Window Server"), regular: false),
        Desk.Running(app: Front.App(pid: 80, name: "iTerm2"), regular: true),
        Desk.Running(app: Front.App(pid: 81, name: "iTerm2"), regular: true),
        Desk.Running(app: settings, regular: true),
        Desk.Running(app: safari, regular: true),
        Desk.Running(app: finder, regular: true),
    ]

    static func desk(_ frontmost: Front.App?, _ listing: WindowListing = listing, running: [Desk.Running] = running,
                     displays: [Display] = [main, left]) -> Desk {
        Desk(frontmost: frontmost, own: terminal, running: running, listing: listing, layout: layout(displays), describe: describe)
    }

    /// A layout with `displays` awake at their ids and frames; with none, the main one asleep.
    static func layout(_ displays: [Display]) -> DisplayLayout {
        try! DisplayLayout(displays.isEmpty ? [OnlineDisplay(id: main.id, frame: main.frame, active: false)]
                                            : displays.map { OnlineDisplay(id: $0.id, frame: $0.frame, active: true) })
    }

    /// The window server's word on each display: these two as they are written above.
    static let describe: @Sendable (OnlineDisplay) -> Display = { display in
        Display(display, isMain: display.id == main.id, scale: display.id == main.id ? main.scale : left.scale)
    }

    static func choose(_ frontmost: Front.App?, _ listing: WindowListing = listing) throws(AppUnread) -> Front {
        try Front.choose(on: desk(frontmost, listing))
    }

    @Test func theFrontmostAppIsReadWhenItHasAWindowAndIsNotTheOneEyesAnswersTo() throws {
        #expect(try Self.choose(Self.safari) == Front(app: Self.safari, display: 1, own: Self.terminal, passedOver: nil))
    }

    /// The agent's own terminal echoes what it searches for, so with it in front the app of
    /// the frontmost ordinary window behind it is read - not the menu bar's owner.
    @Test func theAgentsOwnTerminalInFrontIsPassedOverForTheAppBehindIt() throws {
        let front = try Self.choose(Front.App(pid: 81, name: "iTerm2"))
        #expect(front.app == Self.settings)
        #expect(front.passedOver == .own("iTerm2"))
        // Its front window is wholly on the display left of the main one.
        #expect(front.display == 2)
    }

    /// Finder frontmost over the desktop, with no window of its own: what a person sees in
    /// front is the window behind it, so that window's app is read, and Finder named as passed over.
    @Test func aFrontmostAppWithNoWindowGivesWayToTheAppBehindIt() throws {
        let front = try Self.choose(Self.finder)
        #expect(front.app == Self.settings)
        #expect(front.passedOver == .windowless(Self.finder))
    }

    /// With no app frontmost, the app of the frontmost ordinary window is read, passing nothing over.
    @Test func noFrontmostAppReadsTheAppOfTheFrontmostOrdinaryWindow() throws {
        let front = try Self.choose(nil)
        #expect(front.app == Self.settings && front.passedOver == nil)
        let safariFirst = WindowListing(windows: [Self.menuBar, Self.window(4, "Safari", pid: 400), Self.window(2, "iTerm2", pid: 80)], excluded: [])
        #expect(try Self.choose(nil, safariFirst) == Front(app: Self.safari, display: 1, own: Self.terminal, passedOver: nil))
    }

    /// A status item in the menu bar is listed above every ordinary window, so an app with
    /// one is not the app behind for that, and its front window is its ordinary one.
    @Test func aStatusItemIsNotAnAppsFrontWindow() throws {
        let password = Front.App(pid: 600, name: "1Password")
        let statusItem = Window(id: 8, owner: "1Password", pid: 600, frame: ScreenRect.at(-1900, 0, 30, 24), layer: 25)
        let note = Window(id: 7, owner: "1Password", pid: 600, frame: ScreenRect.at(100, 100, 300, 300), layer: 0)
        let listing = WindowListing(windows: [statusItem, Self.menuBar] + Self.listing.windows.dropFirst() + [note], excluded: [])
        let running = Self.running + [Desk.Running(app: password, regular: true)]
        #expect(try Front.choose(on: Self.desk(Front.App(pid: 80, name: "iTerm2"), listing, running: running)).app == Self.settings)
        #expect(try Front.choose(on: Self.desk(password, listing, running: running)).display == 1)
    }

    /// A window across two displays is read on the one holding most of it.
    @Test func theDisplayIsTheOneHoldingMostOfTheFrontWindow() throws {
        let across = WindowListing(windows: [Self.window(4, "Safari", pid: 400, x: -200)], excluded: [])
        #expect(try Self.choose(Self.safari, across).display == 1)
        let mostlyLeft = WindowListing(windows: [Self.window(4, "Safari", pid: 400, x: -400)], excluded: [])
        #expect(try Self.choose(Self.safari, mostlyLeft).display == 2)
    }

    /// Each state that leaves nothing to read is refused with its own reason.
    @Test func eachUnreadableStateIsItsOwnRefusal() {
        let alone = WindowListing(windows: [Self.menuBar, Self.window(2, "iTerm2", pid: 80)], excluded: [])
        #expect(throws: AppUnread.noOrdinaryWindow(own: "iTerm2")) { try Self.choose(Front.App(pid: 80, name: "iTerm2"), alone) }
        #expect(throws: AppUnread.nothingOnScreen) { try Self.choose(Self.finder, WindowListing(windows: [Self.menuBar], excluded: [])) }
        // The display it was on unplugged mid-read: its window is on none left.
        #expect(throws: AppUnread.offDisplays(Self.settings)) { try Front.named("System Settings", on: Self.desk(Self.safari, displays: [Self.main])) }
        // No display active at all - the one attached asleep, as at the lock screen - is no
        // screen to read, whatever app it was.
        #expect(throws: AppUnread.noDisplay) { try Front.choose(on: Self.desk(Self.safari, displays: [])) }
        #expect(AppUnread.noOrdinaryWindow(own: "iTerm2").description.contains("no app but iTerm2, the agent's own, has a window on screen"))
    }

    /// An app named is matched by its name exactly, and each way it cannot be read is said.
    @Test func aNamedAppIsMatchedExactlyAndRefusedForWhatItIs() throws {
        let desk = Self.desk(Self.safari)
        #expect(try Front.named("System Settings", on: desk) == Front(app: Self.settings, display: 2, own: Self.terminal, passedOver: nil))
        #expect(throws: AppUnread.notRunning("Settings", ordinary: ["Finder", "Safari", "System Settings", "iTerm2"])) {
            try Front.named("Settings", on: desk)
        }
        #expect(throws: AppUnread.own("iTerm2")) { try Front.named("iTerm2", on: desk) }
        #expect(throws: AppUnread.noWindow(Self.finder)) { try Front.named("Finder", on: desk) }
    }

    /// Of two instances under one name, the one with a window is read, frontmost first; one of
    /// them being the agent's own app leaves the other to read.
    @Test func ofTwoInstancesTheOneWithTheFrontmostWindowIsRead() throws {
        let second = Front.App(pid: 401, name: "Safari")
        let listing = WindowListing(windows: [Self.window(5, "Safari", pid: 401), Self.window(4, "Safari", pid: 400)], excluded: [])
        let desk = Self.desk(nil, listing, running: Self.running + [Desk.Running(app: second, regular: true)])
        #expect(try Front.named("Safari", on: desk).app == second)
        let ownTwin = Desk(frontmost: nil, own: Front.Passed(pids: [401], name: "Safari"), running: desk.running, listing: listing, layout: desk.layout, describe: Self.describe)
        #expect(try Front.named("Safari", on: ownTwin).app == Self.safari)
    }

    /// The app, and whatever is in front of its front window that a click there lands in - a
    /// remote Open panel over it - but never what is behind it or the agent's own terminal.
    @Test func theOwnersAreTheAppAndWhatIsOverItLessTheAppPassedOver() {
        let front = Front(app: Self.settings, display: 1, own: Self.terminal, passedOver: .own("iTerm2"))
        let panel = WindowListing(windows: [Self.menuBar, Self.window(9, "Open and Save Panel Service", pid: 900), Self.window(3, "System Settings", pid: 300),
                                            Self.window(4, "Safari", pid: 400), Self.window(2, "iTerm2", pid: 80)], excluded: [])
        let landsInPanel: (ScreenPoint) -> Heard<Int32> = { _ in .answered(900) }
        #expect(front.owners(in: Self.listing, hit: landsInPanel) == [300])
        #expect(front.owners(in: panel, hit: landsInPanel) == [900, 300])
        #expect(Region.front(front).owners(in: panel, hit: landsInPanel) == .only([900, 300]))
    }

    /// A frame over the front window says only where a window could be drawn. Notification
    /// Center's covers the whole screen and draws nothing there; the menu bar shows the front
    /// app's menus. A click there landing elsewhere, or not answering, takes neither in.
    @Test func aWindowOverTheFrontOneIsTakenInOnlyWhereAClickLandsInIt() {
        let front = Front(app: Self.settings, display: 1, own: Self.terminal, passedOver: nil)
        let center = Window(id: 6, owner: "Notification Center", pid: 700, frame: ScreenRect.at(-1920, 0, 3432, 1080), layer: 23)
        let listing = WindowListing(windows: [center, Self.menuBar, Self.window(3, "System Settings", pid: 300, x: -1000)], excluded: [])
        var asked: [ScreenPoint] = []
        #expect(front.owners(in: listing) { asked.append($0); return .answered(300) } == [300])
        // Notification Center at the front window's centre; the menu bar does not reach it.
        #expect(asked == [ScreenPoint.at(-700, 240)])
        #expect(front.owners(in: listing) { _ in .unanswered } == [300])
        #expect(front.owners(in: listing) { _ in .answered(700) } == [700, 300])
    }

    /// The agent's own terminal over the front app's window is never read, though it was not
    /// the app in front: it echoes what the agent searches for.
    @Test func theAppEyesAnswersToOverTheFrontAppIsNotReadEither() {
        let front = Front(app: Self.safari, display: 1, own: Self.terminal, passedOver: nil)
        let floating = WindowListing(windows: [Self.window(2, "iTerm2", pid: 81, layer: 3), Self.window(4, "Safari", pid: 400)], excluded: [])
        #expect(front.owners(in: floating) { _ in .answered(81) } == [400])
    }

    @Test func everyOtherRegionReadsEveryProcess() {
        for region: Region in [.display(1), .window(3), .rect(Self.main.frame), .page(window: 3, frame: Self.main.frame)] {
            #expect(region.owners(in: Self.listing) { _ in Issue.record("hit test asked"); return .unanswered } == .every)
        }
    }

    /// Where an app a click lands in stands is the front look's own rule: the app it reads, a
    /// window over that app's it reads too - the remote Open panel - the agent's own terminal,
    /// or behind. The terminal in front, passed over, is the terminal, not the front app.
    @Test func whereAHitAppStandsIsDecidedByTheFrontLooksRule() {
        let front = Front(app: Self.settings, display: 1, own: Self.terminal, passedOver: .own("iTerm2"))
        let panel = WindowListing(windows: [Self.menuBar, Self.window(9, "Open and Save Panel Service", pid: 900), Self.window(3, "System Settings", pid: 300),
                                            Self.window(4, "Safari", pid: 400), Self.window(2, "iTerm2", pid: 80)], excluded: [])
        let desk = Self.desk(Front.App(pid: 80, name: "iTerm2"), panel)
        let landsInPanel: (ScreenPoint) -> Heard<Int32> = { _ in .answered(900) }
        let standing = { (pid: Int32, front: Result<Front, AppUnread>) in
            Front.standing(of: pid, at: try! desk.layout.active.place(.at(100, 100)), on: desk, front: front, hit: landsInPanel)
        }
        #expect(standing(300, .success(front)) == .front(Self.settings))
        #expect(standing(900, .success(front)) == .overFront(Self.settings))
        #expect(standing(80, .success(front)) == .own("iTerm2"))
        #expect(standing(81, .success(front)) == .own("iTerm2"))
        #expect(standing(400, .success(front)) == .behind(Self.settings))
        // With no app to read, a hit says why rather than that it is behind nothing.
        #expect(standing(80, .failure(.noOrdinaryWindow(own: "iTerm2"))) == .own("iTerm2"))
        #expect(standing(400, .failure(.noOrdinaryWindow(own: "iTerm2"))) == .unread(.noOrdinaryWindow(own: "iTerm2")))
        // A front look reads one display: a hit on another is not read, the front app's own
        // window there included.
        let onLeft = { (pid: Int32) in
            Front.standing(of: pid, at: try! desk.layout.active.place(.at(-500, 100)), on: desk, front: .success(front), hit: landsInPanel)
        }
        #expect(onLeft(300) == .otherDisplay(Self.settings, 1))
        #expect(onLeft(900) == .otherDisplay(Self.settings, 1))
        #expect(onLeft(80) == .own("iTerm2"))
        // The front app's menu bar is no window of its own, which that look never walks.
        #expect(Front.standing(of: 300, at: try! desk.layout.active.place(.at(100, 10)), on: desk, front: .success(front), hit: landsInPanel)
            == .noWindow(Self.settings))
    }

    @Test func twoReadersOwnersAreTheirUnion() {
        #expect(Owners.only([1]).union(.only([2])) == .only([1, 2]))
        #expect(Owners.only([1]).union(.every) == .every)
    }
}

/// Which runs a reader that sees what is on top keeps for the owners: the tree's rule for a
/// window in front, `Covers`.
@Suite struct OwnersSeeTests {
    static let app = Window(id: 3, owner: "System Settings", pid: 300, frame: ScreenRect.at(0, 0, 600, 400), layer: 0)
    static let over = Window(id: 4, owner: "Notification Center", pid: 700, frame: ScreenRect.at(0, 0, 1512, 982), layer: 23)
    static let behind = Window(id: 5, owner: "Safari", pid: 400, frame: ScreenRect.at(0, 0, 1512, 982), layer: 0)
    static let inApp = ScreenPoint.at(100, 100)
    static let onlyBehind = ScreenPoint.at(1000, 100)
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
