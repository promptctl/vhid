import ArgumentParser
import Input
import Foundation
@testable import Doctor
import EyesVerbs
import Installations
import MCP
import Pointing
import KeyboardLayouts
import Testing
import Turns
@testable import vhid

/// What the MCP server offers, and what it says to arguments it will not act on. No
/// daemon: every refusal here is one that comes back before a connection is made.
@Suite struct McpTests {
    @Test func theToolsAreListedInOrder() {
        #expect(Tools.all.map(\.tool.name) == ["look", "type", "press", "gesture", "click", "move", "scroll", "drag", "play", "cursor", "doctor"])
    }

    /// Only look, cursor and doctor promise to change nothing: look and cursor reach no
    /// device, and doctor asks the daemon a question that claims none.
    @Test func onlyLookCursorAndDoctorAreReadOnly() {
        #expect(Tools.all.filter { $0.tool.annotations.readOnlyHint == true }.map(\.tool.name) == ["look", "cursor", "doctor"])
    }

    /// The plugin's skill opens with the guidance as the server words it at initialize, so a
    /// client running a release whose server sends no instructions still reads it, and the
    /// two never become two versions. [LAW:one-source-of-truth]
    @Test func theSkillCarriesThePairingTheServersSend() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let skill = try String(contentsOf: root.appending(path: "claude-plugin/skills/look-click-look/SKILL.md"), encoding: .utf8)
        #expect(skill.contains(McpCommand.guidance))
    }

    /// The doctor tool answers with every row, in order, under a one-word verdict, then the
    /// screen grants. Against a service nothing registers, the verdict is always "not
    /// ready" - whatever Mac runs this - and a Mac that is not ready is an answer, not a
    /// failed call.
    @Test func theDoctorToolAnswersEveryRowUnderItsVerdictThenTheGrants() async throws {
        let said = try await Tools.doctor.call([:], on: Installation.nobody, taking: Turns())
        let sections = said.components(separatedBy: "\n\n")
        #expect(sections.count == 2, "\(said)")
        // Whichever grants this Mac holds, the section reads them, or says it could not.
        #expect(sections.last.map { $0.hasPrefix("2 grants, read before any dialog.") || $0.hasPrefix("The grants could not be read: ") } == true, "\(said)")
        let lines = sections[0].components(separatedBy: "\n")
        #expect(lines.first == "not ready")
        let rows = lines.dropFirst().filter { !$0.hasPrefix(" ") }
        #expect(rows.count == Requirement.Row.allCases.count, "\(said)")
        for (line, row) in zip(rows, Requirement.Row.allCases) {
            #expect(line.hasPrefix(row.rawValue + ": "), "\(said)")
        }
        #expect(said.contains("\(Requirement.Row.launchdJob.rawValue): no job"), "\(said)")
        #expect(await Self.refusal(Tools.doctor, ["service": "x"]) == "service is not an argument this tool takes, and it takes none")
    }

    // MARK: look

    /// look reads its arguments by the tool's own parameters: a flag is a JSON boolean, an id
    /// the window server's 32 bits, said in the schema and refused past them by name, and a
    /// question the verbs refuse comes back in their words.
    @Test func lookReadsItsArgumentsAsTheVerbsRefuseThem() async throws {
        let schema = try #require(Tools.look.tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(schema["display"]?.objectValue?["maximum"] == .int(4294967295))
        #expect(schema["exact"]?.objectValue?["type"] == "boolean")
        #expect(await Self.refusal(Tools.look, ["display": 4294967296]) == "display is 4294967296, and a window server's id runs from 0 to 4294967295")
        #expect(await Self.refusal(Tools.look, ["window": -1]) == "window is -1, and a window server's id runs from 0 to 4294967295")
        #expect(await Self.refusal(Tools.look, ["exact": "yes"]) == "exact is \"yes\", and it is \(EyesVerbs.Help.exact)")
        await #expect { try await Tools.look.call(["x": 1], on: Installation.nobody, taking: Turns()) } throws: {
            "\($0)" == "give x and y together: the point a click would land on"
        }
    }

    /// look asks nothing of the daemon, so it is answered while a call to the daemon holds
    /// the turn: a look waiting on a change holds up no act, and no act holds up a look.
    @Test(.timeLimit(.minutes(1))) func aLookIsAnsweredWhileACallToTheDaemonHoldsTheTurn() async throws {
        let turns = Turns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (held, holding) = AsyncStream<Void>.makeStream()
        let act = Task { try await turns.take { holding.yield(); for await _ in gate { break } } }
        for await _ in held { break }
        await #expect { try await Tools.look.call(["x": 1], on: Installation.nobody, taking: turns) } throws: { $0 is ValidationError }
        open.yield()
        try await act.value
    }

    // MARK: arguments

    private static func refusal(_ tool: VerbTool, _ given: [String: Value]) async -> String? {
        do {
            _ = try await tool.call(given, on: Installation.nobody, taking: Turns())
            return nil
        } catch let refused as ArgumentRefused {
            return refused.description
        } catch {
            return "not a refusal: \(error)"
        }
    }

    /// An unknown modifier is refused as a tool error, before any device is reached, on
    /// every pointer tool that holds them.
    @Test func anUnknownModifierIsRefusedNamingIt() async {
        #expect(await Self.refusal(Tools.click, ["x": 1, "y": 2, "modifiers": "leftShift+hyper"])?.hasSuffix("\"hyper\" in \"leftShift+hyper\" is not a modifier to hold (\(Modifier.holdableNames))") == true)
        #expect(await Self.refusal(Tools.scroll, ["x": 1, "y": 2, "modifiers": "function"])?.hasSuffix("function is not a key the device can hold") == true)
        #expect(await Self.refusal(Tools.drag, ["from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4], "modifiers": 3])?.hasPrefix("modifiers is 3") == true)
    }

    /// The schema offers it, not required.
    @Test func thePointerToolsTakeModifiers() {
        for tool in [Tools.click, Tools.scroll, Tools.drag] {
            #expect(tool.tool.inputSchema.objectValue?["properties"]?.objectValue?["modifiers"] != nil, "\(tool.tool.name)")
            #expect(tool.tool.inputSchema.objectValue?["required"]?.arrayValue?.contains("modifiers") != true, "\(tool.tool.name)")
        }
    }

    /// `layout` is offered by the two verbs that read keys off a layout, and required by neither.
    @Test func theKeyboardToolsTakeALayout() {
        for tool in [Tools.type, Tools.press] {
            #expect(tool.tool.inputSchema.objectValue?["properties"]?.objectValue?["layout"] != nil, "\(tool.tool.name)")
            #expect(tool.tool.inputSchema.objectValue?["required"]?.arrayValue?.contains("layout") != true, "\(tool.tool.name)")
        }
    }

    /// Refused before the daemon is reached, by the name given.
    @Test func anUnknownLayoutIsRefusedByName() async {
        await #expect(throws: NoLayout.noSourceNamed("com.apple.keylayout.Nope")) {
            try await Tools.type.call(["text": "a", "layout": "com.apple.keylayout.Nope"], on: Installation.nobody, taking: Turns())
        }
        await #expect(throws: NoLayout.noSourceNamed("com.apple.keylayout.Nope")) {
            try await Tools.press.call(["chords": ["return"], "layout": "com.apple.keylayout.Nope"], on: Installation.nobody, taking: Turns())
        }
    }

    /// A wrongly named argument is refused, not ignored: `count` for `times` would otherwise
    /// click once where three were asked for.
    @Test func anArgumentTheToolDoesNotTakeIsRefusedByName() async {
        #expect(await Self.refusal(Tools.click, ["x": 1, "y": 2, "count": 3])
            == "count is not an argument this tool takes: it takes x, y, box, button, times, modifiers")
        #expect(await Self.refusal(Tools.cursor, ["x": 1]) == "x is not an argument this tool takes, and it takes none")
    }

    /// The same spellings the command line's `--button` refuses. [LAW:single-enforcer]
    @Test func aButtonTheReportHasNoBitForIsRefused() async {
        for button: Value in ["thumb", "0", "33", 0, 33, -1, 1.5, true] {
            let said = await Self.refusal(Tools.click, ["x": 1, "y": 2, "button": button])
            #expect(said?.hasPrefix("button is ") == true, "\(button) was not refused: \(said ?? "accepted")")
        }
    }

    /// A script that cannot be played whole is refused at its line before any connection
    /// is made: the service here is one nobody registers, so reaching it would say so.
    @Test func aScriptThatCannotBePlayedIsRefusedAtItsLine() async {
        let script = #"{"to":{"x":1,"y":1}}"# + "\n" + #"{"t_ms":0,"keys":["leftShift"]}"#
        let refused = await #expect(throws: Play.ScriptInvalid.self) { try await Tools.play.call(["script": .string(script)], on: Installation.nobody, taking: Turns()) }
        #expect(refused?.line == 2)
        #expect(refused?.reason.hasPrefix("the script ends with leftShift held") == true, "\(String(describing: refused))")
    }

    @Test func noClicksIsRefused() async {
        #expect(await Self.refusal(Tools.click, ["x": 1, "y": 2, "times": 0])
            == "times is 0, and it is how many presses without moving between them, at least 1")
    }

    /// A place is x and y or a box, never half of one or both.
    @Test(arguments: [["x": 1], ["box": "0,0,10,10", "x": 1, "y": 2], [:]] as [[String: Value]])
    func aPlaceThatIsNeitherOrBothIsRefused(given: [String: Value]) async {
        #expect(await Self.refusal(Tools.move, given) == "give x and y, or box, and not both")
    }

    /// A box is read as eyes prints it, and refused by name when it is not one.
    @Test func aBoxIsReadAsEyesPrintsIt() async {
        #expect(await Self.refusal(Tools.click, ["box": "10,20,0,40"])?.hasPrefix("box is \"10,20,0,40\"") == true)
        #expect(await Self.refusal(Tools.scroll, ["box": ["x": 1, "y": 2]])?.hasPrefix("box is ") == true)
        // Read, and so past every argument's refusal to the devices, which are nobody's here.
        for tool in [Tools.click, Tools.move, Tools.scroll] {
            let said = await Self.refusal(tool, ["box": "-10,20,30,40"])
            #expect(said?.hasPrefix("box") == false && said?.hasPrefix("give") == false, "\(said ?? "nil")")
        }
        let dragged = await Self.refusal(Tools.drag, ["from": "-10,20,30,40", "to": ["x": 3, "y": 4]])
        #expect(dragged?.hasPrefix("from") == false && dragged?.hasPrefix("to") == false, "\(dragged ?? "nil")")
        #expect(await Self.refusal(Tools.drag, ["from": "1,2,3", "to": ["x": 3, "y": 4]])?.hasPrefix("from is ") == true)
    }

    /// The SDK has already turned `data:,hi` into bytes it cannot give back as sent, when
    /// it read the JSON: the text arrives as it would from a client, decoded.
    @Test func textThatReadsAsADataURLIsRefused() async throws {
        let text = try JSONDecoder().decode(Value.self, from: Data(#""data:,hi""#.utf8))
        #expect(await Self.refusal(Tools.type, ["text": text])?.hasPrefix("text begins data:") == true)
    }

    @Test func aPlaceNeedsBothCoordinatesAndNothingElse() async {
        let from: Value = ["x": 1, "y": 2]
        #expect(await Self.refusal(Tools.drag, ["from": from, "to": ["x": 3]])?.hasPrefix("to is ") == true)
        #expect(await Self.refusal(Tools.drag, ["from": from, "to": ["x": 3, "y": 4, "z": 5]])?.hasPrefix("to is ") == true)
    }

    // MARK: a number a Double cannot hold

    private static func line(_ text: String) -> Data { Data(text.utf8) }

    /// Answered under the caller's own id, as a tool error naming the argument, so the
    /// call it belongs to ends and the model can read why.
    @Test func aNumberTooLargeIsAnsweredUnderTheCallersIdNamingTheArgument() throws {
        let answer = try #require(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"move","arguments":{"x":1e400,"y":10}}}"#)))
        let response = try JSONDecoder().decode(Response<CallTool>.self, from: answer)
        #expect(response.id == 7)
        let result = try response.result.get()
        #expect(result.isError == true)
        guard case .text(let said, _, _) = result.content.first else { Issue.record("no text in \(result)"); return }
        #expect(said == "x is a number too large for a Double to hold, so nothing was done")
    }

    @Test func everyArgumentTooLargeIsNamed() throws {
        let answer = try #require(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"drag","arguments":{"from":{"x":1e400,"y":1},"to":{"x":1,"y":-1e999}}}}"#)))
        #expect(String(decoding: answer, as: UTF8.self).contains("from.x, to.y are numbers too large"))
    }

    @Test func aLineTheSDKCanReadIsLeftToIt() {
        #expect(Unreadable.answer(to: Self.line(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"move","arguments":{"x":1e300,"y":10}}}"#)) == nil)
        #expect(Unreadable.answer(to: Self.line(#"{"jsonrpc":"2.0","method":"notifications/x","params":{"n":1e400}}"#)) == nil)
    }

    // MARK: what is owed

    /// A request is owed an answer, an answer settles one, a cancellation withdraws one,
    /// and a notification is owed nothing.
    @Test func linesAreReadForWhatTheyAskAnswerAndWithdraw() {
        let request = Self.line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cursor"}}"#)
        let answer = Self.line(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        let failure = Self.line(#"{"jsonrpc":"2.0","id":"b","error":{"code":-32602,"message":"no"}}"#)
        let cancel = Self.line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)
        let notification = Self.line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        #expect(Exchange.requested(in: request) == [3])
        #expect(Exchange.answered(in: request).isEmpty)
        #expect(Exchange.answered(in: answer) == [3])
        #expect(Exchange.answered(in: failure) == ["b"])
        #expect(Exchange.requested(in: answer).isEmpty)
        #expect(Exchange.withdrawn(in: cancel) == [3])
        #expect(Exchange.requested(in: cancel).isEmpty)
        #expect(Exchange.requested(in: notification).isEmpty)
        #expect(Exchange.withdrawn(in: request).isEmpty)
    }

    @Test func aBatchIsReadMessageByMessage() {
        let batch = Self.line(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"two","method":"ping"}]"#)
        #expect(Exchange.requested(in: batch) == [1, "two"])
        #expect(Exchange.answered(in: Self.line(#"[{"jsonrpc":"2.0","id":1,"result":{}},{"jsonrpc":"2.0","id":"two","result":{}}]"#)) == [1, "two"])
    }

    /// One item the SDK cannot read fails the whole batch, which it then answers under an
    /// id of its own making. Owing the readable one would hold the session open for good.
    @Test func aBatchTheSDKCannotReadIsOwedNothing() {
        #expect(Exchange.requested(in: Self.line(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"foo":1}]"#)).isEmpty)
        #expect(Exchange.requested(in: Self.line("[]")).isEmpty)
    }

    /// A response the client sends back, and a message with no jsonrpc version, are
    /// nothing the SDK answers.
    @Test func whatTheSDKDoesNotAnswerIsNotOwed() {
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":4,"result":{}}"#)).isEmpty)
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":[4],"method":"x"}"#)).isEmpty)
    }

    /// A request whose params are not an object is still owed: the SDK answers it with a
    /// parse error under the same id.
    @Test func aRequestOfAnUnexpectedShapeIsStillOwed() {
        #expect(Exchange.requested(in: Self.line(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":"x"}"#)) == [9])
        #expect(Exchange.requested(in: Self.line("not json")).isEmpty)
    }
}
