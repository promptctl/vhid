import Keystrokes

/// The keyboard as a client reaches it: the acts of `KeyPress`, with a root process in the
/// middle instead of the driver. A value over the connection, so a typist holds a
/// `KeyPress` and not a connection. [LAW:composability]
public struct HelperKeyboard: KeyPress {
    let helper: HelperConnection

    public func down(_ usage: Usage) throws {
        try helper.call { service, deadline, reply in service.down(usage: usage.rawValue, by: deadline, reply: reply) }
    }

    public func releaseAll() throws {
        try helper.release { service, deadline, reply in service.releaseAll(by: deadline, reply: reply) }
    }

    /// Holds exactly `keys`. Repeating the set the daemon last acknowledged posts no
    /// report and keeps the keys past the daemon's two-second limit; an empty set always
    /// posts.
    public func hold(_ keys: HeldKeys) throws {
        try helper.call { service, deadline, reply in service.hold(usages: keys.usages.map(\.rawValue), by: deadline, reply: reply) }
    }
}
