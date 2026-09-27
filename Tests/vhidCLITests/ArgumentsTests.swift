import ArgumentParser
import Input
import Pointing
import Testing
@testable import vhid

/// What argv becomes before a verb holds it. [LAW:parse-dont-validate]
@Suite struct ArgumentsTests {
    /// The spelling a button prints is a spelling the flag takes, both ways round, for
    /// all thirty-two. [LAW:one-source-of-truth]
    @Test func everyButtonReadsBackAsItPrints() throws {
        for number in UInt8(1)...32 {
            let button = try #require(Button(rawValue: number))
            #expect(Button(argument: button.description) == button)
        }
    }

    @Test func theThreeWordsNameTheirButtons() {
        #expect(Button(argument: "left") == .left)
        #expect(Button(argument: "right") == .right)
        #expect(Button(argument: "middle") == .middle)
    }

    /// Nothing outside the thirty-two the report has a bit for.
    @Test func aButtonTheReportHasNoBitForIsRefused() {
        #expect(Button(argument: "0") == nil)
        #expect(Button(argument: "33") == nil)
        #expect(Button(argument: "-1") == nil)
        #expect(Button(argument: "nope") == nil)
        #expect(Button(argument: "") == nil)
    }

    /// The default shown in help is a value the flag accepts, which is not what a
    /// `RawRepresentable` shows on its own - it would offer `1` where `left` is the word.
    @Test func theButtonDefaultIsPrintedAsAWordNotANumber() {
        #expect(Button.left.defaultValueDescription == "left")
    }

    @Test func clicksAreWholeAndAtLeastOne() {
        #expect(Clicks(argument: "1") == .single)
        #expect(Clicks(argument: "2") == .double)
        #expect(Clicks(argument: "7")?.rawValue == 7)
        #expect(Clicks(argument: "0") == nil)
        #expect(Clicks(argument: "-1") == nil)
        #expect(Clicks(argument: "1.5") == nil)
    }

    /// `inf` and `nan` are both things a shell hands over as a Double without complaint,
    /// and neither is a place on the screen.
    @Test func aPointThatIsNotAPlaceOnTheScreenIsRefusedAtTheParse() {
        for x in ["inf", "-inf", "nan"] {
            #expect(throws: (any Error).self) { try ClickCommand.parse([x, "10"]) }
            #expect(throws: (any Error).self) { try ClickCommand.parse(["10", x]) }
        }
    }

    @Test func anOrdinaryPointParses() throws {
        let click = try ClickCommand.parse(["100", "40.5"])
        #expect(click.x == 100)
        #expect(click.y == 40.5)
        #expect(click.button == .left)
        #expect(click.times == .single)
    }

    /// A display left of or above the main one has negative coordinates, and a bare -100
    /// is a flag as far as any argument parser is concerned. `--` is how it is said, and
    /// the help says so.
    @Test func negativeCoordinatesAreReachableAfterADoubleDash() throws {
        let click = try ClickCommand.parse(["--", "-100", "-40.5"])
        #expect(click.x == -100)
        #expect(click.y == -40.5)
    }

    /// Each verb's help shows options before `--`, the one order that parses; the example
    /// it prints is the argv parsed here, and it lands on the negative numbers it shows.
    @Test func eachVerbsNegativeExampleParses() throws {
        let click = try ClickCommand.parse(Array(Help.NegativeExample.click.dropFirst()))
        #expect((click.x, click.y, click.times.rawValue) == (-100, -40, 2))
        let move = try MoveCommand.parse(Array(Help.NegativeExample.move.dropFirst()))
        #expect((move.x, move.y) == (-100, -40))
        let scroll = try ScrollCommand.parse(Array(Help.NegativeExample.scroll.dropFirst()))
        #expect((scroll.x, scroll.y, scroll.vertical) == (-100, -40, 3))
        let drag = try DragCommand.parse(Array(Help.NegativeExample.drag.dropFirst()))
        #expect((drag.fromX, drag.fromY, drag.toX, drag.toY, drag.button) == (-100, 40, 200, 40, .right))
        for (verb, argv) in [(Help.click, Help.NegativeExample.click), (Help.move, Help.NegativeExample.move),
                             (Help.scroll, Help.NegativeExample.scroll), (Help.drag, Help.NegativeExample.drag)] {
            #expect(verb.configuration.discussion.contains("vhid " + argv.joined(separator: " ")))
            #expect(argv.first == verb.name)
        }
    }

    @Test func aBareNegativeCoordinateIsRefusedRatherThanMisread() {
        #expect(throws: (any Error).self) { try ClickCommand.parse(["-100", "50"]) }
    }
}
