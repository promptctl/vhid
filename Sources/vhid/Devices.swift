import Helper
import Input
import Installations

/// The two devices an installation's daemon owns, as a client reaches them.
///
/// [LAW:decomposition] One sentence, and the reason it is one type rather than two is
/// that the two cannot be made separately. The helper admits one client at a time, so a
/// keyboard and a mouse in one process are one client and share one connection - two
/// would have the second refused as busy by the first. And the helper takes their
/// reports as a single sequence, so they share one `DeviceQueue`: with a queue each, the
/// order reports were asked in and the order they arrive in could differ.
///
/// [LAW:effects-at-boundaries] Opening the connection is the only effect here. What each
/// verb then does with a keyboard and a mouse is decided against types that know nothing
/// about privilege, which is also what lets the verbs be tested against devices that
/// record instead of typing.
struct Devices {
    let keyboard: any Keyboard
    let mouse: any Mouse

    init(keyboard: any Keyboard, mouse: any Mouse) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    /// The devices over a connection to this installation's daemon.
    ///
    /// The connection is lazy - launchd starts the job on the first call, not here - so a
    /// daemon that is not installed is discovered when the first report goes out rather
    /// than at construction. Nothing is claimed about it before then. [LAW:no-silent-failure]
    init(of installation: Installation) {
        let helper = HelperConnection(installation: installation)
        let queue = DeviceQueue()
        self.init(
            keyboard: QueuedKeyboard(keyboard: helper.keyboard, queue: queue),
            mouse: QueuedMouse(pointing: helper.mouse, queue: queue))
    }

    /// The typist these keys are typed by.
    var typist: Typist { Typist(keyboard: keyboard) }

    /// The pointer this mouse is steered by, reading the cursor back from the window
    /// server after every report - which is the only place the truth about where the
    /// pointer went lives, since macOS accelerates the counts the device sends.
    var pointer: Pointer { Pointer(mouse: mouse, cursor: Pointer.screenCursor) }
}
