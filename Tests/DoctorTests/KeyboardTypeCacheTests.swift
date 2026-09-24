import DriverExtension
import Foundation
import Installations
import Testing
@testable import Doctor

/// Reading Keyboard Setup Assistant's cache as the user, against files of the test's own:
/// the three readings, and each one as the row a person sees. [LAW:behavior-not-structure]
///
/// A class, so the scratch directory every file here is written into goes when the test
/// does.
@Suite final class KeyboardTypeCacheTests {
    private let key = VirtualKeyboardIdentity.keyboardTypeKey
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyboardtype-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func scratch(_ name: String) -> String { directory.appendingPathComponent("\(name).plist").path }

    private func written(_ root: [String: Any], _ name: String) throws -> String {
        let path = scratch(name)
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func answered(_ path: String) throws -> Bool { try KeyboardTypeCache.read(at: path).answersThisKeyboard }

    /// The KSA row a person would see for this reading, from the whole list.
    private func row(_ path: String) throws -> Requirement {
        let list = Readiness(installation: .development, driver: .success(.running), job: .success(.holdingTheService),
                             daemon: .answered(holder: nil), keyboardSetupAssistantAnswered: Result { try answered(path) })
        return try #require(list.requirements.first { $0.name == Requirement.Row.keyboardSetupAssistant.rawValue })
    }

    @Test func theVirtualKeyboardsAnswerOnFileIsAnswered() throws {
        let path = try written(["keyboardtype": ["1031-4176-0": 41, key: 40]], "answered")
        #expect(try answered(path))
        #expect(try row(path).met)
    }

    /// Other keyboards' answers are not this one's, and an answer other than the ANSI the
    /// daemon files is one the daemon rewrites - not filed.
    @Test func otherKeyboardsAnswersOrAnotherTypeAreUnanswered() throws {
        for (name, answers) in [("others", ["1031-4176-0": 40]), ("iso", [key: 41])] {
            let path = try written(["keyboardtype": answers], name)
            #expect(try !answered(path), "\(name)")
            #expect(try !row(path).met, "\(name)")
        }
    }

    /// A Mac that has met no keyboard has no file, and nothing is answered on it.
    @Test func noFileIsUnanswered() throws {
        #expect(try !answered(scratch("absent")))
        #expect(try !answered(written(["other": 1], "no-entry")))
    }

    /// A file this user may not read is never "unanswered": the answer may be in it. The
    /// row says so, with the mode the file should have. Root reads any mode, so the test
    /// means nothing run as root.
    @Test(.enabled(if: getuid() != 0)) func aFileThisUserCannotReadIsUnreadableAndNamesTheMode() throws {
        let path = try written(["keyboardtype": [key: 40]], "tight")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let unreadable = #expect(throws: KeyboardTypeCache.Unreadable.self) { try answered(path) }
        #expect(unreadable?.reason == .notReadableByThisUser)
        let shown = try row(path)
        #expect(!shown.met)
        #expect(shown.reads.contains("0644"), "\(shown.reads)")
    }

    /// Bytes that are not the cache, or a cache whose answers are the wrong shape.
    @Test func aFileThatIsNotTheCacheIsUnreadable() throws {
        let garbage = scratch("garbage")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: garbage))
        for path in [garbage, try written(["keyboardtype": "not a dictionary"], "wrong-shape")] {
            let unreadable = #expect(throws: KeyboardTypeCache.Unreadable.self) { try answered(path) }
            guard case .unparsable = unreadable?.reason else { Issue.record("read \(String(describing: unreadable))"); continue }
        }
    }

    /// A replaced cache carries every other top-level key through, and reads back as what
    /// it was given.
    @Test func replacingTheAnswersKeepsEverythingElse() throws {
        let path = try written(["keyboardtype": ["1031-4176-0": 40], "other": "kept"], "replace")
        let replaced = try KeyboardTypeCache.read(at: path).replacing(answers: [key: 40])
        #expect(replaced.answersThisKeyboard)
        #expect(replaced.root["other"] as? String == "kept")
        #expect(replaced.root["keyboardtype"] as? [String: Int] == [key: 40])
    }

    /// This Mac's own cache, read without privilege, reads as one of the answers rather
    /// than failing: the daemon keeps it world-readable. As root it proves nothing.
    @Test(.enabled(if: getuid() != 0)) func thisMacsCacheIsReadWithoutRoot() throws {
        _ = try KeyboardTypeCache.read().answersThisKeyboard
    }
}
