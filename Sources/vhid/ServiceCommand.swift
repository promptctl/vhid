import ArgumentParser
import Doctor
import Foundation

/// The Mach service this vhid dials when no `--service` is given.
///
/// The release pkg asks this of the binary it is about to pack, and writes the launchd
/// plist's Label, its MachServices key and the daemon's `--service` from the answer. So
/// the name the installed CLI dials and the name the installed daemon is registered
/// under are one value read out of one binary, and cannot come to be two.
/// [LAW:one-source-of-truth]
///
/// [CLI] The name alone on stdout, so `$(vhid service)` is exactly the name.
struct ServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Print the Mach service this vhid dials when --service is not given.",
        subcommands: [Standing.self]
    )

    func run() {
        print(ServiceOption.byDefault.service)
    }
}

extension ServiceCommand {
    /// Where launchd stands on the job for the service, as one word.
    ///
    /// pkg/scripts/postinstall asks this of the job it has just loaded, and `vhid doctor`
    /// reads the same standing through the same probe: an installer with a reader of its
    /// own would be a second idea of what launchd's record says, free to disagree with
    /// doctor's about one job. [LAW:one-source-of-truth]
    ///
    /// [CLI] The word on stdout, and exit 1 with nothing on stdout for a launchd that could
    /// not be read: no word stands for "unread", so none is printed for it. A caller that
    /// took an empty answer for a standing would unload a healthy job. [LAW:no-silent-failure]
    struct Standing: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "standing",
            abstract: "Print where launchd stands on the job for the service, as one word.",
            // [LAW:one-source-of-truth] Listed from the enum, so the help cannot name a word
            // this build no longer prints.
            discussion: "The words are \(JobStanding.allCases.map(\.rawValue).joined(separator: ", "))."
        )

        @OptionGroup var service: ServiceOption

        func run() throws {
            do {
                print(try LaunchdProbe.standing(of: service.installation()).rawValue)
            } catch {
                FileHandle.standardError.write(Data("vhid service standing: \(error)\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
