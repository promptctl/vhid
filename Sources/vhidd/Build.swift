import Foundation
import Security

/// One build of vhidd: the cdhash of the code it was signed as.
///
/// A screen reader is a child of this executable, started by its path, and the path
/// outlives the build: a rebuild or an install replaces the file under a daemon that goes
/// on running, and the next child started from it is the replacement. The two need not
/// speak one protocol, so a child says which build it is in the line that says it joined,
/// and the daemon takes it only when that is its own build. [LAW:parse-dont-validate] The
/// child that will answer is the one checked, so no path, link or moment comes between
/// the check and what it is a check of.
///
/// Read off the file this process was started from, because that is what Security reads a
/// process's own signing information off: measured on macOS 26.3, a process whose binary
/// was replaced under it reported the new file's cdhash as its own. So it is read once, at
/// the start, while the file is the build running - by the daemon before it serves
/// anything, and by a child before it says it joined. [LAW:no-ambient-temporal-coupling]
struct Build: Equatable, CustomStringConvertible {
    /// The cdhash, in hex.
    let cdhash: String
    var description: String { cdhash }

    /// Signed code always has a cdhash; code without one is not signed at all.
    struct Unsigned: Error, CustomStringConvertible {
        var description: String { "this executable has no cdhash: it is not code signed" }
    }

    /// This process's build, off the file it was started from.
    static func ofThisProcess() throws -> Build {
        guard let hash = try ownSigningInformation()[kSecCodeInfoUnique] as? Data else { throw Unsigned() }
        return Build(cdhash: hash.map { String(format: "%02x", $0) }.joined())
    }
}

/// This process's own code signature could not be read.
struct SignatureUnread: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "this process's own code signature could not be read (OSStatus \(status))" }
}

/// This process's signing information, certificates included, read off the file it was
/// started from. [LAW:one-source-of-truth] The one reading of it, for whoever needs a
/// fact off this process's own signature.
func ownSigningInformation() throws(SignatureUnread) -> [CFString: Any] {
    var running: SecCode?
    let found = SecCodeCopySelf([], &running)
    guard found == errSecSuccess, let running else { throw SignatureUnread(status: found) }
    var code: SecStaticCode?
    let pinned = SecCodeCopyStaticCode(running, [], &code)
    guard pinned == errSecSuccess, let code else { throw SignatureUnread(status: pinned) }
    var information: CFDictionary?
    let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    guard read == errSecSuccess, let information = information as? [CFString: Any] else { throw SignatureUnread(status: read) }
    return information
}
