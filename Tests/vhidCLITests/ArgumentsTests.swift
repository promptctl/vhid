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

    /// `--modifiers` takes the chord vocabulary on all three pointer verbs, and a word that
    /// is not a modifier is refused at the parse, by name, before anything connects.
    @Test func modifiersParseOrAreRefusedByName() throws {
        #expect(try ClickCommand.parse(["--modifiers", "leftShift+leftCommand", "1", "2"]).modifiers == HeldModifiers([.leftShift, .leftCommand]))
        #expect(try ScrollCommand.parse(["--modifiers", "leftCommand", "1", "2"]).modifiers == HeldModifiers([.leftCommand]))
        #expect(try DragCommand.parse(["--modifiers", "leftOption", "1", "2", "3", "4"]).modifiers == HeldModifiers([.leftOption]))
        #expect(try ClickCommand.parse(["1", "2"]).modifiers == .none)
        for (spelling, reason) in [("leftShift+hyper", "\"hyper\" in \"leftShift+hyper\" is not a modifier to hold (leftShift, "),
                                   ("function", "function is not a key the device can hold"),
                                   ("", "\"\" in \"\" is not a modifier to hold")] {
            let refused = #expect(throws: (any Error).self) { try ClickCommand.parse(["--modifiers", spelling, "1", "2"]) }
            let message = refused.map { ClickCommand.message(for: $0) } ?? ""
            #expect(message.contains("--modifiers") && message.contains(reason), "\(spelling): \(message)")
        }
    }

    @Test func anOrdinaryPointParses() throws {
        let click = try ClickCommand.parse(["100", "40.5"])
        #expect(try places(click.place, count: 1) == [.point(ScreenPoint(x: 100, y: 40.5)!)])
        #expect(click.button == .left)
        #expect(click.times == .single)
    }

    /// A display left of or above the main one has negative coordinates, and a bare -100
    /// is a flag as far as any argument parser is concerned. `--` is how it is said, and
    /// the help says so.
    @Test func negativeCoordinatesAreReachableAfterADoubleDash() throws {
        let click = try ClickCommand.parse(["--", "-100", "-40.5"])
        #expect(try places(click.place, count: 1) == [.point(ScreenPoint(x: -100, y: -40.5)!)])
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
        #expect(try places(click.place, count: 1) == [.point(ScreenPoint(x: -100, y: -40)!)])
        let drag = try #require(try Vhid.parseAsRoot(Help.NegativeExample.drag) as? DragCommand)
        #expect(try places(drag.places, count: 2) == [.point(ScreenPoint(x: -100, y: 40)!), .point(ScreenPoint(x: 200, y: 40)!)])
        let scroll = try #require(try Vhid.parseAsRoot(Help.NegativeExample.scroll) as? ScrollCommand)
        #expect(try places(scroll.place, count: 1) == [.point(ScreenPoint(x: -100, y: -40)!)])
        #expect(scroll.vertical == 3)
    }

    @Test func aBareNegativeCoordinateIsRefusedRatherThanMisread() {
        #expect(throws: (any Error).self) { try ClickCommand.parse(["-100", "50"]) }
    }
}


/// Places on a command line: a point as two words, a box as one, as eyes prints it.
@Suite struct PlacesTests {
    static let box = Target.box(ScreenRect(x: -10, y: 20, width: 30, height: 40)!)

    @Test func aBoxIsOneWordAndAPointTwo() throws {
        #expect(try places(["-10,20,30,40"], count: 1) == [Self.box])
        #expect(try places(["-10, 20, 30, 40"], count: 1) == [Self.box])
        #expect(try places(["5", "6", "-10,20,30,40"], count: 2) == [.point(ScreenPoint(x: 5, y: 6)!), Self.box])
        #expect(try places(["-10,20,30,40", "5", "6"], count: 2) == [Self.box, .point(ScreenPoint(x: 5, y: 6)!)])
    }

    @Test func theVerbsTakeABox() throws {
        let click = try ClickCommand.parse(["--", "-10,20,30,40"])
        #expect(try places(click.place, count: 1) == [Self.box])
        let drag = try #require(try Vhid.parseAsRoot(["drag", "--", "-10,20,30,40", "100", "200"]) as? DragCommand)
        #expect(try places(drag.places, count: 2) == [Self.box, .point(ScreenPoint(x: 100, y: 200)!)])
    }

    @Test(arguments: [
        (["1,2,3"], "1,2,3 is not a box"), (["1,2,0,4"], "1,2,0,4 is not a box"), (["1,2,3,nan"], "1,2,3,nan is not a box"),
        (["1,2,3,4,5"], "1,2,3,4,5 is not a box"), (["1"], "1 is not a point"), (["1", "x"], "1 x is not a point"),
        (["1", "2", "3", "4"], "1 2 3 4 is 2 places, and this takes 1"), (["inf", "2"], "(inf, 2.0) is not a place"),
    ])
    func whatIsNotAPlaceIsRefusedByName(words: [String], said: String) {
        #expect { try places(words, count: 1) } throws: { "\($0)".contains(said) }
    }
}
