import Foundation
import Security
import Testing
@testable import vhidd

/// A screen reader is started from this executable only while the file there is the build
/// running. [LAW:behavior-not-structure]
@Suite struct RunningBuildTests {
    /// This test process, whose executable nothing has replaced, is handed its own path.
    @Test func anExecutableNothingReplacedIsHandedOut() throws {
        #expect(try RunningBuild.executable() == Bundle.main.executablePath)
    }

    /// What the daemon says when a rebuild has replaced the file under it: the builds
    /// differ, and not that the reader would not join.
    @Test func aReplacedExecutableIsRefusedSayingTheBuildsDiffer() {
        #expect {
            try RunningBuild.executable(at: "/repo/.build/debug/vhidd", compared: errSecCSStaticCodeChanged)
        } throws: {
            "\($0)" == "/repo/.build/debug/vhidd has been replaced by another build since this vhidd started, and a screen reader started from it would be that build, not this one: restart vhidd"
        }
    }

    @Test func aComparisonThatCouldNotBeMadeIsRefusedWithItsStatus() {
        #expect {
            try RunningBuild.executable(at: "/usr/local/libexec/vhidd", compared: errSecCSNoSuchCode)
        } throws: {
            "\($0)" == "this vhidd's build could not be compared with /usr/local/libexec/vhidd (OSStatus \(errSecCSNoSuchCode))"
        }
    }
}
