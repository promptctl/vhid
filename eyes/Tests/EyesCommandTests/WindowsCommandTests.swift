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

    /// Nothing filtered and nothing excluded says so by saying nothing extra: the clause
    /// only appears when there is something to report.
    @Test func awholeReadingClaimsNothingItDidNotDo() {
        let listing = WindowListing(windows: [window(id: 1), window(id: 2)], excluded: [])
        let line = Windows.scope(shown: 2, listing: listing)
        #expect(line == "2 windows, front to back. Owner, layer and bounds; titles need Screen Recording.")
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
                WindowExclusion(reason: .unplaced, count: 1),
            ]
        )
        let line = Windows.scope(shown: 12, listing: listing)
        #expect(line.contains("27 listed"))
        #expect(line.contains("2 arealess"))
        #expect(line.contains("12 invisible"))
        #expect(line.contains("1 unplaced"))
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
}
