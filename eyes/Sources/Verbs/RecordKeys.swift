import Telemetry

// The keys the verbs' records are written under, declared once each.
// [LAW:types-are-the-program] [LAW:one-source-of-truth]

extension Telemetry.Count {
    /// Accessibility calls a hit test made, and those of them asking what is in front.
    static let calls = Self("calls")
    static let frontCalls = Self("front_calls")
    /// Elements a hit test landed through, from the deepest out.
    static let rows = Self("rows")
    /// Processes counted as the agent's own app.
    static let ownPids = Self("own_pids")
    /// Runs a reading examined, and the pages a paged reading read.
    static let examined = Self("examined")
    static let pages = Self("pages")
    /// Reads a wait made, and the time spent checking boxes against the screen.
    static let reads = Self("reads")
    static let boxMilliseconds = Self("box_ms")
    /// Boxes narrowed to their text, and the Accessibility calls checking them took.
    static let boxesNarrowed = Self("boxes_narrowed")
    static let boxCalls = Self("box_calls")
    /// Processes a reading was limited to.
    static let owners = Self("owners")
    /// Runs that matched, those matched only loosely, and those given as nearest instead.
    static let matched = Self("matched")
    static let matchedAlso = Self("matched_also")
    static let nearest = Self("nearest")
}

extension Telemetry.Attribute {
    /// The rule that chose the app read: `in_front` or `named`.
    static let chosen = Self("chosen")
    /// The app read, by name and pid, absent when AppKit names it nothing; the display
    /// holding most of its front window; the app it gave way from.
    static let frontApp = Self("front_app")
    static let frontPid = Self("front_pid")
    static let display = Self("display")
    static let passedOver = Self("passed_over")
    /// Where a hit test landed: the app, its pid and window, its standing, the app in front.
    static let app = Self("app")
    static let pid = Self("pid")
    static let window = Self("window")
    static let standing = Self("standing")
    static let front = Self("front")
    /// Why a hit test ended where it did.
    static let end = Self("end")
    /// How far a reading reached, and what it was asked to read and how.
    static let reach = Self("reach")
    static let source = Self("source")
    static let region = Self("region")
    static let order = Self("order")
    /// The role a reading was limited to; absent for none.
    static let role = Self("role")
    /// What a wait waited for.
    static let until = Self("until")
}
