import Eyes
import Testing
@testable import EyesCommand

/// The sentence the binary prints before its rows, asked with no screen behind it.
///
/// [LAW:no-silent-failure] Every row under this line is narrower than the screen, and the
/// line is the only thing that says by how much. A caller that reads "12 windows" without
/// being told fifteen entries were left out cannot tell a filtered answer from a whole
/// one, so what the sentence claims is a contract and is tested like one.
@Suite struct WindowsCommandTests {
    private func window(id: UInt32 = 1, owner: String = "Safari", layer: Int = 0) -> Window {
        Window(id: id, owner: owner, frame: ScreenRect(x: 0, y: 33, width: 1512, height: 949), layer: layer)
    }

    /// Nothing filtered and nothing excluded says so by saying nothing extra: the counted
    /// clauses only appear when there is something to count.
    @Test func awholeReadingClaimsNothingItDidNotDo() {
        let listing = WindowListing(windows: [window(id: 1), window(id: 2)], excluded: [])
        let line = Windows.scope(shown: 2, listing: listing)
        #expect(line == "2 windows, front to back."
            + " On screen only: minimized, hidden and other-Space windows were never looked at."
            + " Owner, layer and bounds; titles need Screen Recording.")
    }

    /// The narrowing no count can reach, and so the one that has to be said in words: the
    /// window server is asked for on-screen windows only and filters the rest before this
    /// package sees anything. Measured on one Mac: 29 on screen against 110 in all. A
    /// caller told "no Safari window" while Safari sits minimized was told something true
    /// about the screen and false about the question they asked.
    @Test func everyReadingSaysItOnlyLookedAtWhatIsOnScreen() {
        let whole = Windows.scope(shown: 2, listing: WindowListing(windows: [window()], excluded: []))
        let narrowed = Windows.scope(
            shown: 0,
            listing: WindowListing(windows: [window()], excluded: [WindowExclusion(reason: .invisible, count: 1)])
        )
        for line in [whole, narrowed] {
            #expect(line.contains("On screen only"))
            #expect(line.contains("minimized"))
        }
    }

    /// One window is one window, not "1 windows".
    @Test func theCountReadsAsEnglish() {
        let listing = WindowListing(windows: [window()], excluded: [])
        #expect(Windows.scope(shown: 1, listing: listing).hasPrefix("1 window, front to back."))
    }

    /// The owner filter says how much it took away and out of what, because the rows below
    /// cannot show what is missing from them.
    @Test func theOwnerFilterDeclaresWhatItTookAway() {
        let listing = WindowListing(windows: (1...12).map { window(id: UInt32($0)) }, excluded: [])
        let line = Windows.scope(shown: 2, listing: listing)
        #expect(line.contains("2 windows, front to back"))
        #expect(line.contains("10 of 12 filtered by owner"))
    }

    /// The measured case this line exists for: on a real Mac the window server listed 27
    /// entries and 15 of them were not windows. A reading that printed 12 rows and said
    /// nothing about the other 15 is the false negative nobody can detect.
    @Test func everyEntryTheWindowServerListedIsAccountedFor() {
        let listing = WindowListing(
            windows: (1...12).map { window(id: UInt32($0)) },
            excluded: [
                WindowExclusion(reason: .arealess, count: 2),
                WindowExclusion(reason: .invisible, count: 12),
                WindowExclusion(reason: .unreadable, count: 1),
            ]
        )
        let line = Windows.scope(shown: 12, listing: listing)
        #expect(line.contains("27 listed"))
        #expect(line.contains("2 arealess"))
        #expect(line.contains("12 invisible"))
        #expect(line.contains("1 unreadable"))
    }

    /// Both narrowings are reported together, because either one alone would make the
    /// count of rows look like the whole truth.
    @Test func theFilterAndTheExclusionsAreBothReported() {
        let listing = WindowListing(
            windows: (1...12).map { window(id: UInt32($0)) },
            excluded: [WindowExclusion(reason: .invisible, count: 3)]
        )
        let line = Windows.scope(shown: 4, listing: listing)
        #expect(line.contains("8 of 12 filtered by owner"))
        #expect(line.contains("15 listed, 3 invisible"))
    }

    /// The layer is on every row, because it is the one fact that tells an open menu from
    /// an ordinary window and the tool no longer decides which of those a caller meant.
    @Test func theRowCarriesTheLayerAndTheCoordinatesVhidClicks() {
        let row = Windows.row(Window(
            id: 104,
            owner: "System Settings",
            frame: ScreenRect(x: 160, y: 33, width: 723, height: 949),
            layer: 101
        ))
        #expect(row == "104\tSystem Settings\tL101\t160,33 723x949")
    }

    /// `kCGWindowOwnerName` is an optional key, so a window can be visible and clickable
    /// with nothing to call it by. It is named as unnamed rather than left blank, so the
    /// column cannot be read as an empty field.
    @Test func aWindowWithNoOwnerNameStillGetsARow() {
        let row = Windows.row(Window(
            id: 7,
            owner: nil,
            frame: ScreenRect(x: 0, y: 0, width: 100, height: 50),
            layer: 0
        ))
        #expect(row == "7\t(unnamed)\tL0\t0,0 100x50")
    }

    /// [LAW:no-silent-failure] An empty `--owner` matches nothing at all, because
    /// `localizedCaseInsensitiveContains("")` is false. That is the one spelling a caller
    /// never means producing the one answer they cannot argue with - zero windows on a
    /// screen full of them - and it arrives from `--owner "$APP"` with `APP` unset.
    @Test func anEmptyOwnerIsRefusedRatherThanFilteringEverythingOut() throws {
        // The Foundation behaviour the refusal exists for, stated so it cannot quietly
        // change underneath the check.
        #expect(!"Safari".localizedCaseInsensitiveContains(""))

        var empty = Windows()
        empty.owner = ""
        #expect(throws: (any Error).self) { try empty.validate() }

        var unset = Windows()
        unset.owner = nil
        #expect(throws: Never.self) { try unset.validate() }

        var real = Windows()
        real.owner = "Safari"
        #expect(throws: Never.self) { try real.validate() }
    }
}
