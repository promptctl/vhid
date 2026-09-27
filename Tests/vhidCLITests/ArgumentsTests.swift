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

    /// Each pointer verb's help shows options before `--`, the one order that parses: the
    /// line it prints is found in the rendered help and parsed from the root as typed, and an
    /// option moved after `--` is refused.
    @Test(arguments: [
        (Help.NegativeExample.click, ClickCommand.self as ParsableCommand.Type),
        (Help.NegativeExample.move, MoveCommand.self),
        (Help.NegativeExample.scroll, ScrollCommand.self),
        (Help.NegativeExample.drag, DragCommand.self),
    ])
    func eachVerbsNegativeExampleParses(argv: [String], verb: ParsableCommand.Type) throws {
        let rendered = Vhid.helpMessage(for: verb, columns: 10_000)
        #expect(rendered.contains("vhid " + argv.joined(separator: " ")))
        #expect(type(of: try Vhid.parseAsRoot(argv)) == verb)
        let dash = argv.firstIndex(of: "--")!
        // `move` shows no option, so it has none to move past `--`.
        if dash > 1 {
            let optionsLast = [argv[0]] + argv[dash...] + argv[1..<dash]
            #expect(throws: (any Error).self) { try Vhid.parseAsRoot(Array(optionsLast)) }
        }
    }

    @Test func theNegativeExamplesLandOnTheNumbersTheyShow() throws {
        let click = try #require(try Vhid.parseAsRoot(Help.NegativeExample.click) as? ClickCommand)
        #expect((click.x, click.y) == (-100, -40))
        let drag = try #require(try Vhid.parseAsRoot(Help.NegativeExample.drag) as? DragCommand)
        #expect((drag.fromX, drag.fromY, drag.toX, drag.toY) == (-100, 40, 200, 40))
        let scroll = try #require(try Vhid.parseAsRoot(Help.NegativeExample.scroll) as? ScrollCommand)
        #expect((scroll.x, scroll.y, scroll.vertical) == (-100, -40, 3))
    }

    @Test func aBareNegativeCoordinateIsRefusedRatherThanMisread() {
        #expect(throws: (any Error).self) { try ClickCommand.parse(["-100", "50"]) }
    }
}
