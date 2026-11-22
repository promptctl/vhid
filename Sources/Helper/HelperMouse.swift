import Pointing

/// The mouse as a client reaches it: the acts of `PointingDevice`, each one report vhidd
/// posts and acknowledges. A `Count` is already inside the descriptor's range, so what
/// crosses is its byte and nothing is checked on the way. [LAW:parse-dont-validate]
public struct HelperMouse: PointingDevice {
    let helper: HelperConnection

    public func down(_ button: Button) throws {
        try helper.call { service, deadline, reply in service.buttonDown(button.rawValue, by: deadline, reply: reply) }
    }

    public func releaseAll() throws {
        try helper.release { service, deadline, reply in service.releaseButtons(by: deadline, reply: reply) }
    }

    /// Holds exactly `buttons`, as the report's button field carries them.
    public func hold(_ buttons: Set<Button>) throws {
        try helper.call { service, deadline, reply in service.holdButtons(Button.field(buttons), by: deadline, reply: reply) }
    }

    public func move(by delta: Move) throws {
        try helper.call { service, deadline, reply in service.move(x: delta.x.value, y: delta.y.value, by: deadline, reply: reply) }
    }

    public func scroll(by delta: Scroll) throws {
        try helper.call { service, deadline, reply in service.scroll(vertical: delta.vertical.value, horizontal: delta.horizontal.value, by: deadline, reply: reply) }
    }
}
