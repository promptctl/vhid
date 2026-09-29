import Grants
import Testing
@testable import EyesCommand

struct GrantsReportTests {
    private let holder = Holder(executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2")

    /// Each missing grant names the app to switch on and the pane it is in.
    @Test func aMissingGrantNamesTheAppAndThePane() {
        let said = GrantsVerb.report(GrantReading { $0 == .accessibility }, holder: holder, asked: [])
        #expect(said == """
            2 grants, read before any dialog. macOS charges them to iTerm (/Applications/iTerm.app), the app responsible for this eyes; that is the app to switch on.
            Screen Recording\tnot granted\tpixels\tturn on iTerm in System Settings > Privacy & Security > Screen Recording
            Accessibility\tgranted\ttree
            """)
    }

    /// Asking names what was asked for, and says to read again once the dialog is answered.
    @Test func askingSaysToAnswerTheDialogThenReadAgain() {
        let asked = GrantsVerb.report(GrantReading { _ in false }, holder: holder, asked: Grant.allCases)
        #expect(asked.hasSuffix("Asked for Screen Recording and Accessibility: answer macOS's dialog, then run eyes grants to read again. If no dialog appeared, macOS already has an answer from iTerm, and only its switch in the pane changes it."))
        #expect(!GrantsVerb.report(GrantReading { _ in true }, holder: holder, asked: []).contains("Asked for"))
    }
}
