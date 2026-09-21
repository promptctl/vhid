import Testing

@testable import Installations

/// What an installation's names guarantee, and what the set of them is open to.
///
/// [LAW:behavior-not-structure] These assert the names a running Mac is keyed by and the
/// fact that a caller can add one, never how the strings are assembled.
struct InstallationTests {
    /// The strings vhid actually registers, pinned.
    ///
    /// Written out rather than rebuilt from the same pieces the code uses, because a test
    /// that composed them would agree with any renaming of them however wrong.
    /// [FRAMING:representation] These are what is installed on a Mac and recorded in
    /// launchd, in TCC and in Background Task Management, so changing one is a migration
    /// and not an edit - and this is where that shows up as a failure rather than as a
    /// daemon nobody can reach.
    @Test
    func vhidsOwnNamesAreTheOnesItHasAlwaysRegistered() {
        #expect(Installation.release.service == "ai.promptctl.vhid.vhidd")
        #expect(Installation.development.service == "ai.promptctl.vhid.vhidd.dev")
        #expect(Installation.refusalDomain == "ai.promptctl.vhid.vhidd.refusal")
    }

    /// The reason two installations can run at once. One name shared between them would
    /// mean one daemon held the endpoint and the other silently never got it.
    @Test
    func vhidsTwoInstallationsShareNoName() {
        let services = Installation.vhids.map(\.service)
        #expect(Set(services).count == Installation.vhids.count, "two installations share a service: \(services)")
    }

    /// The label and the service are one string, which is what makes a second claimant on
    /// an installation fail at bootstrap instead of running without an endpoint. Asserted
    /// for a service this package has never seen as well, because the guarantee belongs to
    /// the type and not to vhid's own two.
    @Test(arguments: ["ai.promptctl.vhid.vhidd", "ai.promptctl.vhid.vhidd.dev", "com.example.anything"])
    func theLabelIsTheService(service: String) {
        let installation = Installation(service: service)
        #expect(installation?.launchdLabel == installation?.service)
    }

    /// The whole point of the change: something linking this package registers a daemon
    /// under a name of its own, and nothing here had to be edited for it to work.
    @Test
    func anInstallationThisPackageNeverHeardOfIsAsGoodAsItsOwn() {
        let theirs = Installation(service: "ai.promptctl.low-talker.keyboardd")
        #expect(theirs?.service == "ai.promptctl.low-talker.keyboardd")
        #expect(theirs?.launchdLabel == "ai.promptctl.low-talker.keyboardd")
        #expect(theirs?.description == "ai.promptctl.low-talker.keyboardd")
        #expect(theirs != Installation.release)
    }

    /// [LAW:parse-dont-validate] The two shapes that cannot survive the trip a service
    /// name takes - through argv, into a launchd Label, onto a Mach service - are refused
    /// at the one crossing, so nothing downstream carries a name it has to re-examine.
    @Test(arguments: ["", " ", "\t", "\n", "two words", "trailing ", " leading", "a\tb"])
    func aNameThatCannotBeALabelIsRefused(service: String) {
        #expect(Installation(service: service) == nil)
    }

    /// Everything else is launchd's to judge. A shape rule here - reverse-DNS, a length
    /// cap - would be a second copy of rules the system actually doing the registering
    /// owns, and a copy that can disagree with it. [LAW:one-source-of-truth]
    @Test(arguments: ["a", "no-dots-at-all", "UPPER.Case.Name", "ai.promptctl.vhid.vhidd.dev.dev"])
    func anUnusualButRegistrableNameIsAccepted(service: String) {
        #expect(Installation(service: service)?.service == service)
    }
}
