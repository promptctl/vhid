import Input
import Installations
import Keystrokes
import MCP
import Testing
@testable import vhid

/// What `--into` and the tools' `into` do: keys only when the app named is in front, and
/// nothing at all otherwise. The app in front is handed in, so which one it is is a fact
/// of the test rather than of the Mac running it. [LAW:effects-at-boundaries]
@Suite struct AimTests {
    static let textEdit = FrontApp(pid: 41, name: "TextEdit")
    static let terminal = FrontApp(pid: 42, name: "Terminal")

    @Test func typeIntoTheAppInFrontTypesAndSaysWhere() async throws {
        let keyboard = RecordingKeyboard()
        let said = try await TypeCommand.type("abc", on: VerbTests.us, into: .into("TextEdit"), with: Typist(keyboard: keyboard),
                                              front: { Self.textEdit })
        #expect(said == "typed 3 characters on \(VerbTests.us.name) into TextEdit")
        #expect(keyboard.down.count >= 3)
    }

    @Test func typeIntoAnAppNotInFrontSendsNothingAndNamesTheOne() async {
        let keyboard = RecordingKeyboard()
        await #expect(throws: NotInFront(aimed: "TextEdit", front: Self.terminal)) {
            try await TypeCommand.type("abc", on: VerbTests.us, into: .into("TextEdit"), with: Typist(keyboard: keyboard),
                                       front: { Self.terminal })
        }
        #expect(keyboard.down.isEmpty && keyboard.holds.isEmpty)
    }

    @Test func pressIntoAnAppNotInFrontPressesNothing() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: NotInFront(aimed: "TextEdit", front: Self.terminal)) {
            try await PressCommand.press(["leftCommand+s"], on: VerbTests.us, into: .into("TextEdit"), with: Typist(keyboard: keyboard),
                                         front: { Self.terminal })
        }
        #expect(keyboard.down.isEmpty && keyboard.holds.isEmpty)
        let said = try await PressCommand.press(["return"], on: VerbTests.us, into: .into("TextEdit"), with: Typist(keyboard: keyboard),
                                                front: { Self.textEdit })
        #expect(said.hasSuffix(" on \(VerbTests.us.name) into TextEdit"))
    }

    /// A name that only contains the one in front is another app: "Notes" is not Sticky Notes.
    @Test func theNameMustBeTheWholeName() async {
        await #expect(throws: NotInFront.self) {
            try await Aim.into("Notes").admit { FrontApp(pid: 7, name: "Sticky Notes") }
        }
        await #expect(throws: NotInFront.self) {
            try await Aim.into("textedit").admit { Self.textEdit }
        }
    }

    /// Without an aim, nothing is asked of macOS at all.
    @Test func anywhereNeverAsksWhatIsInFront() async throws {
        try await Aim.anywhere.admit { Issue.record("asked what is in front"); return nil }
    }

    @Test func theRefusalNamesWhatWasInFrontOrThatNothingWas() {
        #expect("\(NotInFront(aimed: "TextEdit", front: Self.terminal))"
            == "TextEdit is not in front, so nothing was sent: Terminal (pid 42) is")
        #expect("\(NotInFront(aimed: "TextEdit", front: nil))" == "TextEdit is not in front, so nothing was sent: no application is")
    }

    // MARK: the command line

    @Test func bothKeyboardVerbsReadIt() throws {
        let typed = try #require(try Vhid.parseAsRoot(["type", "--into", "TextEdit", "a"]) as? TypeCommand)
        #expect(try typed.aimOption.aim() == .into("TextEdit"))
        let pressed = try #require(try Vhid.parseAsRoot(["press", "--into", "TextEdit", "return"]) as? PressCommand)
        #expect(try pressed.aimOption.aim() == .into("TextEdit"))
        #expect(try AimOption.parse([]).aim() == .anywhere)
    }

    @Test func anEmptyNameIsRefused() {
        #expect(throws: (any Error).self) { try AimOption.parse(["--into", ""]).aim() }
    }

    // MARK: the tools

    @Test func theKeyboardToolsTakeIntoAndNeitherRequiresIt() {
        for tool in [Tools.type, Tools.press] {
            #expect(tool.tool.inputSchema.objectValue?["properties"]?.objectValue?["into"] != nil, "\(tool.tool.name)")
            #expect(tool.tool.inputSchema.objectValue?["required"]?.arrayValue?.contains("into") != true, "\(tool.tool.name)")
        }
    }

    /// Refused as an argument, before the daemon is reached.
    @Test func anEmptyOrNonStringIntoIsRefusedBeforeConnecting() async {
        for into: Value in ["", 3] {
            await #expect(throws: ArgumentRefused.self) {
                try await Tools.type.call(["text": "a", "into": into], on: Installation.nobody)
            }
            await #expect(throws: ArgumentRefused.self) {
                try await Tools.press.call(["chords": ["return"], "into": into], on: Installation.nobody)
            }
        }
    }
}
