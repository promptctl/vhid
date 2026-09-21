import CoreGraphics
import Testing
@testable import Eyes

/// The rule that turns the window server's list into the windows a person can see, asked
/// with no window server.
///
/// [LAW:behavior-not-structure] Every fixture below is a shape measured on a real Mac,
/// not one invented to suit the rule. Three quarters of a real listing is not a window
/// anyone means, and a reading that handed all of it back would cost a caller most of its
/// tokens on Control Center.
@Suite struct WindowTests {
    private func entry(
        id: UInt32 = 1,
        owner: String = "Safari",
        layer: Int = 0,
        alpha: Double = 1,
        x: Double = 0, y: Double = 33, width: Double = 1512, height: Double = 949
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height],
        ]
    }

    /// An application window comes through with its bounds untouched: the window server
    /// already answers in global screen coordinates with a top-left origin, which is the
    /// space everything here speaks.
    @Test func anApplicationWindowKeepsItsOwnerAndItsBounds() {
        let windows = Geometry.windows(from: [entry(id: 7, owner: "Xcode", x: 14, y: 47, width: 1400, height: 900)])
        #expect(windows == [Window(id: 7, owner: "Xcode", frame: ScreenRect(x: 14, y: 47, width: 1400, height: 900))])
    }

    /// The layers measured on one Mac at one moment: the menu bar at 24, thirteen Control
    /// Center extras at 25, three Notification Center surfaces at Int32's floor. None of
    /// them is a window a caller means, and all of them would cost tokens.
    @Test func onlyLayerZeroIsAnApplicationWindow() {
        let listing = [
            entry(id: 1, owner: "iTerm2", layer: 0),
            entry(id: 2, owner: "Window Server", layer: 24, width: 1512, height: 33),
            entry(id: 3, owner: "Control Center", layer: 25, width: 30, height: 33),
            entry(id: 4, owner: "Notification Center", layer: -2_147_483_601, width: 360, height: 180),
        ]
        #expect(Geometry.windows(from: listing).map(\.owner) == ["iTerm2"])
    }

    /// Measured on the same Mac in a different moment: a loginwindow entry 30000 points
    /// square at a negative origin. It is excluded because the window server says it is
    /// not at layer zero, and never because of its size - a size rule would be this module
    /// inventing an answer the system already publishes, and it would drop a small real
    /// palette to catch this.
    @Test func theThirtyThousandPointWindowGoesWithoutASizeRule() {
        let listing = [entry(id: 9, owner: "loginwindow", layer: -1, x: -15000, y: -15000, width: 30000, height: 30000)]
        #expect(Geometry.windows(from: listing).isEmpty)
    }

    /// A window composited at zero alpha is on the list and on no screen.
    @Test func aFullyTransparentWindowIsNotOnScreen() {
        #expect(Geometry.windows(from: [entry(alpha: 0)]).isEmpty)
        #expect(Geometry.windows(from: [entry(alpha: 0.01)]).count == 1)
    }

    /// [LAW:no-silent-failure] A bounds dictionary missing a field is refused, not read as
    /// zero: a window reported at 0,0 sized 0 is a claim about where it is, and the truth
    /// was that nobody could tell.
    @Test func aWindowWhosePositionWillNotReadIsDroppedRatherThanPlacedAtTheOrigin() {
        var broken = entry()
        broken[kCGWindowBounds as String] = ["X": 0.0, "Y": 0.0, "Width": 1512.0]
        #expect(Geometry.windows(from: [broken]).isEmpty)
    }

    /// A zero-sized window is a real entry that covers nothing, so there is nowhere in it
    /// to look and nothing in it to click.
    @Test func aWindowWithNoAreaIsDropped() {
        #expect(Geometry.windows(from: [entry(width: 0, height: 400)]).isEmpty)
    }

    /// Front-to-back is the window server's own ordering and is preserved, because the
    /// first row being the frontmost window is most of what makes this reading useful.
    @Test func theOrderTheWindowServerGaveIsKept() {
        let listing = [entry(id: 1, owner: "Front"), entry(id: 2, owner: "Middle"), entry(id: 3, owner: "Back")]
        #expect(Geometry.windows(from: listing).map(\.owner) == ["Front", "Middle", "Back"])
    }
}
