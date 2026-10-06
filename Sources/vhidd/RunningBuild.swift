import Foundation
import Security

/// The executable this process was started from, while the file there is still the build
/// that is running.
///
/// A screen reader is a child of this executable, started by its path, and the path
/// outlives the build: a rebuild or an install replaces the file under a daemon that goes
/// on running. A child started from the replacement is another build, and the two need not
/// speak one protocol - the reader never says it joined, and the daemon blames the join.
/// So the path is handed out only while it holds this build, and the refusal otherwise
/// says the builds differ. [LAW:parse-dont-validate]
///
/// The running build is the kernel's: `SecCodeCheckValidity` on this process compares the
/// code directory it was started with against the file at its path, and answers
/// `errSecCSStaticCodeChanged` when they differ. Its signing information would not tell:
/// read off this process, it is read off the file. Measured on macOS 26.3: a process whose
/// binary was replaced under it reported the new file's cdhash as its own.
enum RunningBuild {
    /// The file at `path` is another build than the one running.
    struct Replaced: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "\(path) has been replaced by another build since this vhidd started, and a screen reader started from it would be that build, not this one: restart vhidd"
        }
    }

    /// The running build could not be compared with the file at `path`.
    struct Uncompared: Error, CustomStringConvertible {
        let path: String
        let status: OSStatus
        var description: String { "this vhidd's build could not be compared with \(path) (OSStatus \(status))" }
    }

    /// This process's executable, when the file there is the build running.
    static func executable() throws -> String {
        var running: SecCode?
        let found = SecCodeCopySelf([], &running)
        guard found == errSecSuccess, let running else { throw Uncompared(path: Bundle.main.executablePath!, status: found) }
        return try executable(at: Bundle.main.executablePath!, compared: SecCodeCheckValidity(running, [], nil))
    }

    /// `path`, when `compared` - `SecCodeCheckValidity`'s answer for the process started
    /// from it - says the file there is the build running.
    static func executable(at path: String, compared: OSStatus) throws -> String {
        switch compared {
        case errSecSuccess: return path
        case errSecCSStaticCodeChanged: throw Replaced(path: path)
        default: throw Uncompared(path: path, status: compared)
        }
    }
}
