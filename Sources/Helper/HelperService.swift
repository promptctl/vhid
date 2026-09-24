import Foundation

/// What crosses the privilege boundary: a key goes down and every key comes up; a button
/// goes down and every button comes up; the pointer moves by counts and the wheel rolls.
///
/// The driver extension takes commands from root alone, so the process that owns the
/// devices is not the process that decides what to type or where to click. This protocol
/// is the whole of what passes between them, and it is deliberately the smallest thing
/// that can work.
///
/// **It cannot express text, and that is the point.** [LAW:types-are-the-program] macOS
/// turns a HID usage into a character using the console user's keyboard layout, and Text
/// Input Sources answers per process: with this Mac switched to Dvorak, the console user
/// is told `com.apple.keylayout.Dvorak` and the same call under `sudo` is told
/// `com.apple.keylayout.US`. A helper handed text would look up the keys with root's
/// layout and type something else entirely - measured, and every check still passed,
/// because the daemon acknowledged every report and the screen held what had been typed.
/// A helper that cannot be handed text cannot make that mistake.
///
/// **It cannot express a place on the screen either, for the same shape of reason.** The
/// device knows deltas, and macOS accelerates them: where the pointer lands after a report
/// is a fact of the window server in the user's session, which a root daemon cannot read.
/// So absolute motion is the client's loop - post a delta, read the cursor back, repeat -
/// and only deltas cross.
///
/// **One report per call, and the client decides when.** The daemon acknowledges reports
/// the driver then drops: twelve 500-character runs, each report awaited, six of which
/// landed fewer keys than were acknowledged - as few as 469 of 500. The only delivery
/// receipt is the event tap, which runs in the user's session and not here. So a method
/// shaped `type(_ text: String)` would swallow a whole burst inside the helper, which has
/// no way to observe the loss and would answer "typed" to a client that got 608
/// characters. The pacing lives with the process that can see what landed.
///
/// **The focus check does not cross.** Which app is frontmost, and whether the operator
/// interrupted, are facts of the user's session that a root daemon cannot read. They stay
/// on the client, which is why this carries no "type into" argument: the helper types
/// wherever the keyboard is pointed, exactly as hardware does, and deciding that is the
/// client's job. [LAW:one-way-deps]
///
/// The integers are the wire's: a usage is the 16 bits of the report, a button is its
/// number, a count is the signed byte the report carries. The wire admits values the
/// device has no bit or count for - button 0 and 33 upward, and -128 - and the helper
/// refuses those by name rather than folding them. [LAW:parse-dont-validate]
@objc public protocol DeviceService {
    /// Holds `usage` down, and answers when the daemon has acknowledged the report.
    ///
    /// The reply is what makes the client's pacing possible, so it is not a fire-and-
    /// forget: `error` is nil when the report was acknowledged and carries the refusal
    /// otherwise. NSXPC has no throwing form, so the failure is the argument.
    func down(usage: UInt16, reply: @escaping (Error?) -> Void)

    /// Every key up, which is what a report of nothing held says.
    func releaseAll(reply: @escaping (Error?) -> Void)

    /// Holds mouse button `button`, 1 through 32, down.
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void)

    /// Every button up.
    func releaseButtons(reply: @escaping (Error?) -> Void)

    /// Moves the pointer by `x` counts right and `y` counts down, buttons held as they are.
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void)

    /// Rolls the wheel: `vertical` positive away from the hand, `horizontal` positive right.
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void)
}

/// What a client is served: the device acts, and handing them back.
///
/// **Leaving is a call and not only a disconnection, because a disconnection is not
/// acknowledged.** The daemon serves one client at a time and frees the devices from the
/// departing connection's invalidation handler, on a thread of its own, after releasing
/// every key and button. A client that invalidates and reconnects at once - the next
/// `vhid` in a shell script, the next call of an MCP session - arrives while that is still
/// running and is refused as busy by its own previous connection. Measured: seven of sixty
/// back-to-back MCP tool calls, each refused as `pid N holds the keyboard` with N its own
/// pid. `leave` answers only once the devices are free, so the next connection is served
/// on the answer rather than on a race. [LAW:no-ambient-temporal-coupling]
///
/// Disconnecting without leaving still releases everything, because a client that
/// crashes cannot leave; `leave` is how a client that can goes without racing.
///
/// **The devices are claimed by the first act, not by connecting.** A connection is
/// admitted on its signature alone, so a client that only asks `status` reaches the daemon
/// while another client holds the devices, and takes nothing from it. A second client's
/// first act is what is refused as busy. [LAW:single-enforcer]
@objc public protocol HelperService: DeviceService {
    /// Releases every key and button this client left held, and frees the devices for the
    /// next client. Every device act after it on this connection is refused.
    func leave(reply: @escaping (Error?) -> Void)

    /// Which process holds the devices, as a pid, or nil when none does. Claims nothing and
    /// sends no report, so asking it is never an act on the devices.
    ///
    /// The answer is also the proof the devices are up: the daemon listens only once both
    /// are ready, and exits when it loses them.
    func status(reply: @escaping (NSNumber?, Error?) -> Void)
}
