import CoreGraphics
import Testing
@testable import Eyes

/// The rule that turns the window server's list into the windows a person can see, asked
/// with no window server.
///
/// [LAW:behavior-not-structure] Every fixture below is a shape measured on a real Mac,
/// not one invented to suit the rule: the layers are the ones `CGWindowListCopyWindowInfo`
/// reported on this machine, and the transient ones were produced by setting
/// `NSWindow.Level` and reading the layer back.
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
        let listing = Geometry.listing(from: [entry(id: 7, owner: "Xcode", x: 14, y: 47, width: 1400, height: 900)])
        #expect(listing.windows == [
            Window(id: 7, owner: "Xcode", frame: ScreenRect(x: 14, y: 47, width: 1400, height: 900), layer: 0),
        ])
        #expect(listing.excluded.isEmpty)
    }

    /// The regression this rule exists to prevent, and the reason there is no layer
    /// filter. Measured by setting `NSWindow.Level` and reading `kCGWindowLayer` back: a
    /// floating palette composites at 3, a modal alert panel at 8, an open menu at 101.
    /// A rule that kept only layer zero dropped all three - which is every transient
    /// surface a caller driving a pointer most needs to find - and said nothing about it.
    @Test func theMenuAndThePanelAndThePaletteAreAllOnScreen() {
        let listing = Geometry.listing(from: [
            entry(id: 1, owner: "Xcode", layer: 0),
            entry(id: 2, owner: "Xcode", layer: 3),
            entry(id: 3, owner: "Xcode", layer: 8),
            entry(id: 4, owner: "Xcode", layer: 101),
        ])
        #expect(listing.windows.map(\.layer) == [0, 3, 8, 101])
    }

    /// The layers do not separate application content from system chrome, which is why
    /// the layer is reported rather than filtered on: the Dock at 20 and the menu bar at
    /// 24 sit *between* an app's modal panel at 8 and its menus at 101, so no threshold
    /// divides them. The caller gets the number and decides.
    @Test func systemChromeIsReportedWithItsLayerRatherThanQuietlyDropped() {
        let listing = Geometry.listing(from: [
            entry(id: 1, owner: "Dock", layer: 20),
            entry(id: 2, owner: "Window Server", layer: 24, width: 1512, height: 33),
            entry(id: 3, owner: "Control Center", layer: 25, width: 30, height: 33),
            entry(id: 4, owner: "Notification Center", layer: -2_147_483_601, width: 360, height: 180),
        ])
        #expect(listing.windows.map(\.owner) == ["Dock", "Window Server", "Control Center", "Notification Center"])
        #expect(listing.windows.map(\.layer) == [20, 24, 25, -2_147_483_601])
        #expect(listing.excluded.isEmpty)
    }

    /// A window composited at zero alpha is on the list and on no screen - and is counted,
    /// so the number of rows and the number of entries can be reconciled.
    @Test func aFullyTransparentWindowIsNotOnScreenAndIsCounted() {
        let listing = Geometry.listing(from: [entry(alpha: 0)])
        #expect(listing.windows.isEmpty)
        #expect(listing.excluded == [WindowExclusion(reason: .invisible, count: 1)])
        #expect(Geometry.listing(from: [entry(alpha: 0.01)]).windows.count == 1)
    }

    /// [LAW:no-silent-failure] A bounds dictionary missing a field is refused, not read as
    /// zero: a window reported at 0,0 sized 0 is a claim about where it is, and the truth
    /// was that nobody could tell. It is counted apart from the ordinary invisible
    /// surfaces because it is an anomaly, and a caller watching it climb is watching
    /// something go wrong.
    @Test func aWindowWhosePositionWillNotReadIsCountedAsUnreadableRatherThanPlacedAtTheOrigin() {
        var broken = entry()
        broken[kCGWindowBounds as String] = ["X": 0.0, "Y": 0.0, "Width": 1512.0]
        let listing = Geometry.listing(from: [broken])
        #expect(listing.windows.isEmpty)
        #expect(listing.excluded == [WindowExclusion(reason: .unreadable, count: 1)])
    }

    /// The bound that is a number and is not one. NaN bridges out of an `NSNumber`
    /// through `as? Double` without complaint, and then passes every check that looks
    /// like it would catch it: `NaN <= 0` is false, so such a window is not `isEmpty` and
    /// was kept, and printing its row called `Int(Double.nan)` - a fatal error, not a bad
    /// number. Measured: the binary died with "Double value cannot be converted to Int
    /// because it is either infinite or NaN". An infinity traps in exactly the same way.
    @Test func aBoundThatIsNotAFiniteNumberIsRefusedRatherThanCrashingTheReading() {
        for bad in [Double.nan, .infinity, -.infinity] {
            var broken = entry()
            broken[kCGWindowBounds as String] = ["X": bad, "Y": 33.0, "Width": 1512.0, "Height": 949.0]
            let listing = Geometry.listing(from: [broken])
            #expect(listing.windows.isEmpty, "a window at \(bad) is not a window anyone can click")
            #expect(listing.excluded == [WindowExclusion(reason: .unreadable, count: 1)])
        }
    }

    /// A NaN *size* is the same hazard by a different door: it slips past the area guard
    /// because no comparison with NaN is ever true.
    @Test func aSizeThatIsNotAFiniteNumberIsRefusedToo() {
        var broken = entry()
        broken[kCGWindowBounds as String] = ["X": 0.0, "Y": 33.0, "Width": Double.nan, "Height": 949.0]
        #expect(Geometry.listing(from: [broken]).windows.isEmpty)
        // The reason the guard cannot be left to `isEmpty`, stated so it cannot return.
        #expect(!(Double.nan <= 0))
    }

    /// An entry with no layer at all cannot say how high it sits, which is now one of the
    /// facts a window carries, so it is refused rather than guessed at.
    @Test func anEntryWithNoLayerIsRefusedRatherThanAssumedToBeAnOrdinaryWindow() {
        var noLayer = entry()
        noLayer.removeValue(forKey: kCGWindowLayer as String)
        #expect(Geometry.listing(from: [noLayer]).excluded == [WindowExclusion(reason: .unreadable, count: 1)])
    }

    /// A zero-sized window is a real entry that covers nothing, so there is nowhere in it
    /// to look and nothing in it to click.
    @Test func aWindowWithNoAreaIsCounted() {
        let listing = Geometry.listing(from: [entry(width: 0, height: 400)])
        #expect(listing.windows.isEmpty)
        #expect(listing.excluded == [WindowExclusion(reason: .arealess, count: 1)])
    }

    /// Front-to-back is the window server's own ordering and is preserved, because the
    /// first row being the frontmost window is most of what makes this reading useful.
    @Test func theOrderTheWindowServerGaveIsKept() {
        let listing = Geometry.listing(from: [
            entry(id: 1, owner: "Front"), entry(id: 2, owner: "Middle"), entry(id: 3, owner: "Back"),
        ])
        #expect(listing.windows.map(\.owner) == ["Front", "Middle", "Back"])
    }

    /// Every entry the window server listed is either a window or a counted exclusion.
    /// That is what lets a caller reconcile a short list against a long one instead of
    /// wondering where the rest went. [LAW:one-source-of-truth]
    @Test func everyEntryIsEitherAWindowOrACountedExclusion() {
        var broken = entry(id: 5)
        broken[kCGWindowBounds as String] = ["X": 0.0]
        let raw = [
            entry(id: 1), entry(id: 2, layer: 101), entry(id: 3, alpha: 0),
            entry(id: 4, width: 0), broken,
        ]
        let listing = Geometry.listing(from: raw)
        #expect(listing.listed == raw.count)
        #expect(listing.windows.count == 2)
        #expect(listing.excluded.reduce(0) { $0 + $1.count } == 3)
    }

    /// The same screen reports its exclusions in the same order every time, rather than in
    /// whatever order a dictionary happened to hash them.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func theExclusionsComeBackInAStableOrder() {
        var broken = entry(id: 9)
        broken[kCGWindowBounds as String] = [:]
        let raw = [entry(id: 1, alpha: 0), entry(id: 2, width: 0), broken]
        let reasons = Geometry.listing(from: raw).excluded.map(\.reason)
        #expect(reasons == [.arealess, .invisible, .unreadable])
        for _ in 0..<20 {
            #expect(Geometry.listing(from: raw).excluded.map(\.reason) == reasons)
        }
    }
}
