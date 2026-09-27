import Eyes
import Testing
@testable import EyesCommand

/// What `eyes displays` prints, over displays written here.
@Suite struct DisplaysCommandTests {
    static let desk = [
        Display(id: 1, frame: ScreenRect(x: 0, y: 0, width: 1512, height: 982), isMain: true, scale: 2),
        Display(id: 3, frame: ScreenRect(x: -1920, y: -98, width: 1920, height: 1080), isMain: false, scale: 1),
    ]

    /// A secondary display left of and above the main one prints its negative origin as is,
    /// because that is the point vhid click would press there.
    @Test func eachDisplayIsARowInClickCoordinates() {
        #expect(Displays.report(Self.desk) == """
            2 displays, main first. Active only: a sleeping display was never looked at. \
            Bounds are the screen points vhid click takes, negative left of or above the main display.
            1\tmain\t0,0 1512x982\t2x
            3\tsecondary\t-1920,-98 1920x1080\t1x
            """)
    }

    @Test func oneDisplayReadsAsEnglishAndAFractionalScaleSurvives() {
        let one = [Display(id: 7, frame: ScreenRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true, scale: 1.5)]
        let lines = Displays.report(one).split(separator: "\n")
        #expect(lines[0].hasPrefix("1 display, main first."))
        #expect(lines[1] == "7\tmain\t0,0 2560x1440\t1.5x")
    }

    /// A mode that could not be read says so, rather than passing for 1x.
    @Test func anUnreadableScaleIsNotGuessed() {
        let display = Display(id: 2, frame: ScreenRect(x: 0, y: 0, width: 800, height: 600), isMain: true, scale: nil)
        #expect(Displays.row(display) == "2\tmain\t0,0 800x600\tscale unreadable")
    }
}
