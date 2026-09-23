import ArgumentParser

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
        abstract: "Print the Mach service this vhid dials when --service is not given."
    )

    func run() {
        print(ServiceOption.byDefault.service)
    }
}
