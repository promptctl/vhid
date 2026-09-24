import DriverExtension
import Foundation

/// Reading whether Keyboard Setup Assistant has this keyboard's answer on file, as the
/// user and with no privilege: the daemon keeps the file world-readable for this.
///
/// [LAW:effects-at-boundaries] The file is read here and understood by
/// `KeyboardTypeCache`, the same reading the daemon files it through.
public enum KeyboardTypeProbe {
    /// Whether the answer for the virtual keyboard is on file.
    ///
    /// Three answers, told apart: filed, not filed - which a file that is not there yet
    /// is too, because a Mac that has met no keyboard has cached nothing - and a file this
    /// could not read, which throws. An unreadable file is never "not filed": the answer
    /// may be in it. [LAW:no-silent-failure]
    public static func answered(at path: String = VirtualKeyboardIdentity.keyboardTypePlist) throws(KeyboardTypeUnreadable) -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            return false
        } catch CocoaError.fileReadNoPermission {
            throw KeyboardTypeUnreadable(path: path, reason: .notReadableByThisUser)
        } catch {
            throw KeyboardTypeUnreadable(path: path, reason: .readFailed("\(error)"))
        }
        do {
            return try KeyboardTypeCache.parse(data).answers[VirtualKeyboardIdentity.keyboardTypeKey] != nil
        } catch {
            throw KeyboardTypeUnreadable(path: path, reason: .unparsable(error.reason))
        }
    }
}

/// The Keyboard Setup Assistant cache could not be read, and why.
///
/// A file this user may not read gets the mode it should have in its words, because that
/// is the one cause a person can see and fix: the daemon sets the file to 0644 each time
/// it starts, so a file this user cannot read was tightened after that start, or the
/// daemon could not set it - and said why in its log.
public struct KeyboardTypeUnreadable: Error, CustomStringConvertible, Equatable {
    public enum Reason: Sendable, Equatable {
        case notReadableByThisUser
        case readFailed(String)
        case unparsable(String)
    }

    public let path: String
    public let reason: Reason

    public var description: String {
        switch reason {
        case .notReadableByThisUser:
            "\(path) is not readable by this user; the daemon sets it to 0644 each time it starts, so check its mode with: ls -l \(path)"
        case .readFailed(let why):
            "\(path) could not be read: \(why)"
        case .unparsable(let why):
            "\(path) is not a keyboard type cache: \(why)"
        }
    }
}
