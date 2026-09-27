import Foundation
import MCP
import Testing
@testable import vhid

/// The command line and the MCP tool list, read as a user of each sees them and put side
/// by side: a verb on both has one name, one set of argument names, and one description.
///
/// Both sides are read from what they render - `--experimental-dump-help` for the command
/// line, the tool list for MCP - not from `Help`, so a declaration that stops reading
/// `Help` on one side fails here. [LAW:behavior-not-structure]
@Suite struct SurfaceTests {
    /// Verbs only the command line has. Adding one here is the deliberate act: a new verb
    /// missing from `Tools.all` fails the test until it is listed.
    /// `help` is the argument parser's own.
    static let commandLineOnly: Set = ["pointer", "mcp", "driver", "service", "help"]

    /// Options every verb on the command line takes and no tool does: a tool's daemon is
    /// the server's, chosen once when it starts.
    static let commandLineOnlyOptions: Set = ["service", "help"]

    /// One argument as the command line shows it.
    struct Shown: Equatable, CustomStringConvertible {
        let name: String
        let help: String
        var description: String { "\(name): \(help)" }
    }

    /// Each verb the command line has, by name: its abstract, discussion and arguments.
    static let commandLine: [String: (abstract: String, discussion: String, arguments: [Shown])] = {
        let json: String
        do {
            _ = try Vhid.parseAsRoot(["--experimental-dump-help"])
            fatalError("--experimental-dump-help parsed as a command")
        } catch {
            json = Vhid.fullMessage(for: error)
        }
        let dumped = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let verbs = (dumped["command"] as! [String: Any])["subcommands"] as! [[String: Any]]
        return Dictionary(uniqueKeysWithValues: verbs.map { verb in
            let arguments = (verb["arguments"] as? [[String: Any]] ?? []).map {
                Shown(name: $0["valueName"] as! String, help: $0["abstract"] as? String ?? "")
            }
            return (verb["commandName"] as! String,
                    (verb["abstract"] as? String ?? "", verb["discussion"] as? String ?? "",
                     arguments.filter { !commandLineOnlyOptions.contains($0.name) }))
        })
    }()

    /// A tool's arguments as the command line would show them, by name: the two surfaces
    /// order them differently, positionals first on the command line. A place is one
    /// argument over MCP and two on the command line, `from-x` and `from-y`; the tool's
    /// phrase for it goes on to spell the JSON, which is the tool's alone.
    static func expected(_ tool: Tool) -> [Shown] {
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        return properties.flatMap { name, property -> [Shown] in
            let phrase = property.objectValue?["description"]?.stringValue ?? ""
            guard property.objectValue?["type"]?.stringValue == "object" else { return [Shown(name: name, help: sentence(phrase))] }
            let place = phrase.components(separatedBy: ": {").first!
            return ["x", "y"].map { Shown(name: "\(name)-\($0)", help: sentence(place + ": " + $0)) }
        }.sorted { $0.name < $1.name }
    }

    private static func sentence(_ phrase: String) -> String { Help.sentence(phrase).abstract }

    @Test func everyVerbIsOnBothSurfacesOrListedAsCommandLineOnly() {
        #expect(Set(Tools.all.map(\.tool.name)) == Set(Self.commandLine.keys).subtracting(Self.commandLineOnly))
    }

    @Test(arguments: Tools.all.map(\.tool))
    func aVerbSaysTheSameOnBothSurfaces(_ tool: Tool) throws {
        let verb = try #require(Self.commandLine[tool.name], "no \(tool.name) on the command line")
        // The tool's description is the abstract and the discussion; the command line may
        // add notes of its own after them, and only after them.
        let said = verb.abstract + "\n\n" + verb.discussion
        let description = tool.description ?? ""
        #expect(description.hasPrefix(verb.abstract + "\n\n") && said.hasPrefix(description)
                    && (said.count == description.count || said.dropFirst(description.count).hasPrefix("\n\n")),
                "\(tool.name): the tool says\n\(description)\n\nthe command line says\n\(said)")
        #expect(Self.expected(tool) == verb.arguments.sorted { $0.name < $1.name })
    }
}
