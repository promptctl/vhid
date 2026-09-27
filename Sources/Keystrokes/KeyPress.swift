/// Something that holds keys down and lets them all go.
///
/// The acts a HID keyboard performs, and the whole of what has to be true of a thing
/// for text to be typed on it. What is on the other side - the driver in this process, or
/// a root daemon across an XPC boundary - is not a fact anything above here needs, which
/// is what lets the same typing code run under `sudo` against the device and unprivileged
/// against vhidd. [LAW:composability]
///
/// There is no `up(_:)`. A caller that released one key at a time would be deciding what
/// the device is holding, and the device is the only thing that can know: it derives every
/// report from its own set of held keys, so a report composed anywhere else is a report
/// that can disagree with what is actually down. Releasing everything is the act that
/// cannot disagree. [LAW:one-source-of-truth]
///
/// Sendable, because a press blocks the thread it is made on until the far side answers,
/// so it is made on a thread kept for waiting: the daemon presses from the thread a
/// client's call arrived on, and a client from the `DeviceQueue` its `QueuedKeyboard`
/// runs every call on.
///
/// `hold` states the whole set down at once, which is how a replay says Shift stays held
/// while A is let go: the device replaces its set with this one and derives the report from
/// it, so this too composes no report.
public protocol KeyPress: Sendable {
    func down(_ usage: Usage) throws
    func releaseAll() throws
    func hold(_ keys: HeldKeys) throws
}
