import Installations
import Testing

@testable import vhidd

/// What the daemon accepts from its plist, and everything it refuses.
///
/// [LAW:behavior-not-structure] The contract is "this argv names that installation, or
/// none", asserted over argv shapes a malformed plist actually produces.
struct ServiceArgumentTests {
    @Test(arguments: Installation.vhids)
    func theInstallationItIsGivenIsTheOneItReads(installation: Installation) {
        #expect(serviceArgument(["/path/to/vhidd", "--service", installation.service]) == installation)
    }

    /// The set is open, which is the point of taking a name: a service this package has
    /// never heard of is read back as readily as vhid's own two.
    @Test
    func aServiceThisPackageDoesNotShipIsReadBackAllTheSame() {
        let mine = serviceArgument(["vhidd", "--service", "com.example.someone-elses.daemon"])
        #expect(mine?.service == "com.example.someone-elses.daemon")
        #expect(mine?.launchdLabel == "com.example.someone-elses.daemon")
    }

    /// The flag need not be first: launchd passes the program as argv[0] and a plist may
    /// carry other arguments before this one.
    @Test
    func theFlagIsFoundWhereverItStands() {
        #expect(serviceArgument(["vhidd", "--verbose", "--service", "a.b.c"])?.service == "a.b.c")
    }

    /// Every way a plist can fail to say. None of these may answer an installation: the
    /// daemon would then listen on another one's service and take its endpoint.
    @Test(arguments: [
        [],
        ["vhidd"],
        ["vhidd", "--service"],
        ["vhidd", "--service", ""],
        ["vhidd", "--service", "has a space"],
        ["vhidd", "--service", "\t"],
        ["vhidd", "ai.promptctl.vhid.vhidd"],
        ["vhidd", "--flavor", "release"],
        ["vhidd", "--services", "ai.promptctl.vhid.vhidd"],
    ])
    func anArgvThatDoesNotSayIsRefused(arguments: [String]) {
        #expect(serviceArgument(arguments) == nil)
    }
}
