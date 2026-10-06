import Foundation
import Security
import Testing
@testable import vhidd

/// A process's build is the cdhash of the file it was started from. [LAW:behavior-not-structure]
@Suite struct BuildTests {
    /// This test process's build, read again here off its executable by path: what any
    /// other process reading that file would say it is.
    @Test func aProcessIsTheBuildItsFileIs() throws {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(try #require(Bundle.main.executableURL) as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        try #require(SecCodeCopySigningInformation(try #require(code), [], &information) == errSecSuccess)
        let hash = try #require((information as? [CFString: Any])?[kSecCodeInfoUnique] as? Data)
        #expect(try Build.ofThisProcess() == Build(cdhash: hash.map { String(format: "%02x", $0) }.joined()))
    }
}
