// The record schema: every count and attribute a record of either half is written under,
// here and nowhere else, so a typo is a compile error and the set a reader can find is the
// set there is. What an attribute's value holds - a move's fields, a pause's - is its
// writer's, as its meaning is.
// [LAW:types-are-the-program] [LAW:one-source-of-truth] Names only - what each fact means is
// decided by the code that writes it - so Telemetry links nothing to hold them.

extension Telemetry {
    /// A count a record keeps: how many of something a unit did, summed by `tally`.
    public enum Count: String, CaseIterable, Sendable {
        // What a verb sent the devices, counted as each report is acknowledged.
        case keyboardReports = "keyboard_reports"
        case mouseReports = "mouse_reports"
        /// Wheel reports with a count on each axis: notches, since macOS takes a report as
        /// one notch whatever count it carries (`Pointer.scroll`).
        case verticalNotches = "scroll_notches_vertical"
        case horizontalNotches = "scroll_notches_horizontal"
        /// Keys a typist put down while another key was still held.
        case keyRollovers = "key_rollovers"
        /// Words a typist hesitated before.
        case keyHesitations = "key_hesitations"

        /// How long a call waited for a turn: an MCP tool call behind the daemon calls before
        /// it, which its `duration_ms` includes, and a reading's recognitions behind Vision's
        /// one turn, in all. Whole milliseconds.
        case queuedMilliseconds = "queued_ms"
        case visionQueuedMilliseconds = "vision_queued_ms"

        /// Accessibility calls a hit test made, and those of them asking what is in front.
        case calls
        case frontCalls = "front_calls"
        /// Elements a hit test landed through, from the deepest out.
        case rows
        /// Processes counted as the agent's own app.
        case ownPids = "own_pids"
        /// Runs a reading examined, and the pages a paged reading read.
        case examined
        case pages
        /// Reads a wait made, and the time spent checking boxes against the screen.
        case reads
        case boxMilliseconds = "box_ms"
        /// Boxes narrowed to their text, and the Accessibility calls checking them took.
        case boxesNarrowed = "boxes_narrowed"
        case boxCalls = "box_calls"
        /// Processes a reading was limited to.
        case owners
        /// Readings of this Mac whose limit was spent by their end: zero for a unit whose
        /// readings all ended in time, absent for one that took none.
        case limitsSpent = "limits_spent"
        /// Runs that matched, those matched only loosely, and those given as nearest instead.
        case matched
        case matchedAlso = "matched_also"
        case nearest

        /// Whether opening the devices writes this as zero, so a verb that opened them and
        /// sent nothing reads zero and one that never opened them carries none. A switch
        /// with no default, so a new count is not left out of that by forgetting it.
        /// [LAW:nothing-unseen]
        public var isSent: Bool {
            switch self {
            case .keyboardReports, .mouseReports, .verticalNotches, .horizontalNotches, .keyRollovers, .keyHesitations: true
            case .queuedMilliseconds, .visionQueuedMilliseconds, .calls, .frontCalls, .rows, .ownPids, .examined, .pages, .reads,
                 .boxMilliseconds, .boxesNarrowed, .boxCalls, .owners, .limitsSpent, .matched, .matchedAlso, .nearest: false
            }
        }
    }

    /// An attribute a record carries: a fact that is not a count, an id among them.
    public enum Attribute: String, CaseIterable, Sendable {
        /// Which dispatcher the unit came through: `cli` or `mcp`.
        case entry
        /// What a returned unit found - matched, landed, held - beside how it ended.
        case result
        /// The signal that landed while a command-line verb ran: `SIGINT`, which Control-C
        /// sends, or `SIGTERM`, a supervisor's. Absent when none did.
        case signal
        /// The commands a cancelled reading's stop ended, each as it was run: empty when the
        /// cancel landed while the reading waited on no command. Absent when no reading was
        /// cancelled.
        case stopped
        /// Why the devices were not handed back when the verb ended. Absent when they were.
        case leaveFailed = "leave_failed"
        /// Whether the displays still pressed as they did when a play was placed on them, once
        /// it finished or stopped: `kept`, `changed` or `unread`. Absent for a verb that placed no play.
        case layout
        /// Why a play's layout went unread. Absent when it was read.
        case layoutUnread = "layout_unread"
        /// How a recording ended - `stop`, `end`, `tap_off`, `hour`, `devices_lost` or
        /// `layout_lost` - and what it left out, by reason, zeros included. Absent for a
        /// verb that recorded nothing.
        case ending
        case leftOut = "left_out"
        /// How many times vhid's own motion ended on a screen edge while recording, after which
        /// the points written may be off. Absent for a verb that recorded nothing.
        case vhidAtEdge = "vhid_at_edge"

        /// The double-click interval the pointer's hand was fitted to, and the delay until a
        /// held key repeats the typist's key holds were fitted to, as the HID system holds
        /// them. Absent when the devices were never opened.
        case doubleClickMilliseconds = "double_click_ms"
        case keyRepeatDelayMilliseconds = "key_repeat_delay_ms"
        /// What the devices' random source was seeded with, as hex: what draws the pointer's
        /// moves and pauses and the typist's key timings again. Absent when the devices were
        /// never opened.
        case seed
        /// How far behind its drawn timing the typist's last report went out, in
        /// milliseconds: what slow acknowledgements and late wakes added to the run. Zero for
        /// a run that sent nothing, and absent for a verb that never typed.
        case keysLateMilliseconds = "keys_late_ms"
        /// The hesitations a typist drew before the words it hesitated before, in
        /// milliseconds all told. Zero for a run with none, absent for a verb that never typed.
        case keyHesitationMilliseconds = "key_hesitation_ms"
        /// The pauses the pointer and the typist made between reports, the one it stopped in
        /// too, by kind: how many and how long they slept in all. By kind, not one by one, so
        /// a roll or a text of any length is a record of bounded size; the seed draws each
        /// one again. Absent for a verb that made none.
        case pauses
        /// Each pointer move the verb made, in order, the one it stopped in too. Absent for a
        /// verb that made none.
        case paths

        /// The grant a gate asked about, whether its reading was taken or shared with one
        /// already underway, and the executable a grant child was started from.
        case grant
        case reading
        case executable

        /// The rule that chose the app read: `in_front` or `named`.
        case chosen
        /// The app read, by name and pid, absent when AppKit names it nothing; the display
        /// holding most of its front window; the app it gave way from.
        case frontApp = "front_app"
        case frontPid = "front_pid"
        case display
        case passedOver = "passed_over"
        /// Where a hit test landed: the app, its pid and window, its standing, the app in front.
        case app
        case pid
        case window
        case standing
        case front
        /// Why a hit test ended where it did.
        case end
        /// How far a reading reached, and what it was asked to read and how.
        case reach
        case source
        case region
        case order
        /// The role a reading was limited to; absent for none.
        case role
        /// What a wait waited for.
        case until
        /// A reading's runs left out, and its boxes left unchecked, each by reason, every
        /// reason there is named, zeros included.
        case excluded
        case boxesUnchecked = "boxes_unchecked"
    }
}
