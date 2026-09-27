import Foundation
import MCP
import Testing
@testable import vhid

/// The command line and the MCP tool list, read as a user of each sees them and put side
/// by side: a verb on both has one name, one set of arguments, and one description.
///
/// Both sides are read from what they render - `--experimental-dump-help` for the command
/// line, the tool list for MCP - so a declaration that stops reading `Help` on one side
/// fails here. [LAW:behavior-not-structure]
@Suite struct SurfaceTests {
    /// Verbs only the command line has. Adding one here is the deliberate act: a new verb
    /// missing from `Tools.all` fails the test until it is listed. `help` is the argument
    /// parser's own.
    static let commandLineOnly: Set = ["mcp", "driver", "service", "record", "help"]

    /// Options every verb on the command line takes and no tool does: a tool's daemon is
    /// the server's, chosen once when it starts, and the version is the server's initialize answer.
    static let commandLineOnlyOptions: Set = ["--service", "--help", "--version"]

    /// What the command line adds to a tool's description, which is true of the command
    /// line alone. Read from `Help` because the dump cannot tell a note from the discussion;
    /// what is compared is still both renderings.
    static let commandLineNotes = Dictionary(uniqueKeysWithValues: [
        Help.type, Help.press, Help.click, Help.move, Help.scroll, Help.drag, Help.play, Help.cursor, Help.doctor,
    ].map { ($0.name, $0.commandLine) })

    /// A tool argument the command line reads from stdin rather than from argv, by verb: a
    /// script is a file's worth of lines, which a shell pipes in.
    static let fromStdin = ["play": "script"]

    /// One argument as a user types it: `--times` or `x`, whether it must be given, and
    /// what it says.
    struct Shown: Equatable, CustomStringConvertible {
        let name: String
        let required: Bool
        let help: String
        var description: String { "\(name)\(required ? "" : "?"): \(help)" }
    }

    struct Verb {
        let abstract: String
        let discussion: String
        let arguments: [Shown]
    }

    struct Unreadable: Error, CustomStringConvertible { let description: String }

    /// Each verb the command line has, by name.
    static func commandLine() throws -> [String: Verb] {
        let json: String
        do {
            _ = try Vhid.parseAsRoot(["--experimental-dump-help"])
            throw Unreadable(description: "--experimental-dump-help parsed as a command")
        } catch let unreadable as Unreadable {
            throw unreadable
        } catch {
            json = Vhid.fullMessage(for: error)
        }
        guard let dumped = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let verbs = (dumped["command"] as? [String: Any])?["subcommands"] as? [[String: Any]] else {
            throw Unreadable(description: "the dump has no command.subcommands: \(json.prefix(200))")
        }
        return try Dictionary(uniqueKeysWithValues: verbs.map { verb in
            guard let name = verb["commandName"] as? String else { throw Unreadable(description: "a verb without a name") }
            let arguments = try (verb["arguments"] as? [[String: Any]] ?? []).compactMap { argument -> Shown? in
                let longs = (argument["names"] as? [[String: Any]] ?? [])
                    .filter { $0["kind"] as? String == "long" }.compactMap { $0["name"] as? String }.map { "--" + $0 }
                guard let typed = longs.first ?? argument["valueName"] as? String else {
                    throw Unreadable(description: "\(name) has an argument without a name")
                }
                if commandLineOnlyOptions.contains(typed) { return nil }
                return Shown(name: typed, required: argument["isOptional"] as? Bool == false,
                             help: argument["abstract"] as? String ?? "")
            }
            return (name, Verb(abstract: verb["abstract"] as? String ?? "", discussion: verb["discussion"] as? String ?? "",
                               arguments: arguments))
        })
    }

    /// A tool's arguments as the command line would show them. A required argument is a
    /// positional and an optional one an option. A place is one argument over MCP and one
    /// per coordinate on the command line, `from-x` and `from-y`; the tool's phrase for it
    /// goes on to spell the JSON, which is the tool's alone.
    static func expected(_ tool: Tool) -> [Shown] {
        let schema = tool.inputSchema.objectValue ?? [:]
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return properties.flatMap { name, property -> [Shown] in
            let property = property.objectValue ?? [:]
            let phrase = property["description"]?.stringValue ?? ""
            let isRequired = required.contains(name)
            guard let coordinates = property["properties"]?.objectValue?.keys.sorted() else {
                return [Shown(name: isRequired ? name : "--" + name, required: isRequired, help: sentence(phrase))]
            }
            let place = phrase.components(separatedBy: ": {").first!
            return coordinates.map { Shown(name: "\(name)-\($0)", required: isRequired, help: sentence(place + ": " + $0)) }
        }.sorted { $0.name < $1.name }
    }

    private static func sentence(_ phrase: String) -> String { Help.sentence(phrase).abstract }

    /// Both surfaces show `Help.press`, so its key names reach both in natural order.
    @Test func pressListsTheKeyNamesInNaturalOrder() {
        #expect(Help.press.discussion.contains("f9, f10"))
    }

    @Test func everyVerbIsOnBothSurfacesOrListedAsCommandLineOnly() throws {
        let verbs = Set(try Self.commandLine().keys)
        #expect(Self.commandLineOnly.isSubset(of: verbs), "listed as command-line only but not a verb: \(Self.commandLineOnly.subtracting(verbs))")
        #expect(Tools.all.map(\.tool.name).sorted() == verbs.subtracting(Self.commandLineOnly).sorted())
    }

    @Test(arguments: Tools.all.map(\.tool.name))
    func aVerbSaysTheSameOnBothSurfaces(_ name: String) throws {
        let tool = try #require(Tools.all.first { $0.tool.name == name }).tool
        let verb = try #require(try Self.commandLine()[name], "no \(name) on the command line")
        let notes = try #require(Self.commandLineNotes[name], "\(name) is missing from commandLineNotes")
        // The command line says what the tool says, then its own notes and nothing else.
        let said = verb.abstract + "\n\n" + verb.discussion
        let description = tool.description ?? ""
        #expect(said == ([description] + notes).joined(separator: "\n\n"),
                "\(name): the tool says\n\(description)\n\nthe command line says\n\(said)")
        #expect(Self.expected(tool).filter { $0.name != Self.fromStdin[name] } == verb.arguments.sorted { $0.name < $1.name })
    }
}
