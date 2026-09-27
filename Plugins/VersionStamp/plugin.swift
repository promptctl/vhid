import Foundation
import PackagePlugin

// Writes the version scripts/version prints into a Swift file the target compiles. A
// prebuild command, because the answer depends on git's state rather than on any file
// the build could name as an input; the file is rewritten only when the answer changes,
// so an unchanged tree does not recompile the target.
@main struct VersionStamp: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        let root = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL.appending(path: "Stamped")
        let file = output.appending(path: "Stamped.swift")
        let script = """
            set -eu
            v=$("$1/scripts/version" "$1")
            new="let stamped = \\"$v\\""
            mkdir -p "$2"
            [ -f "$3" ] && [ "$(cat "$3")" = "$new" ] || printf '%s\\n' "$new" >"$3"
            """
        return [
            .prebuildCommand(
                displayName: "Stamping the vhid version",
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", script, "sh", root.path(), output.path(), file.path()],
                outputFilesDirectory: output
            )
        ]
    }
}
