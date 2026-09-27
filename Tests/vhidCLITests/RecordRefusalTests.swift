import Testing
@testable import vhid

/// What stops `vhid record` before its tap app is launched, from what was read of this Mac.
@Suite struct RecordRefusalTests {
    /// Measured: `launchctl print system` on a Mac running vhid's dev daemon and the pqrs
    /// driver, cut to the lines around its services block.
    static let system = """
        system = {
        \ttype = system
        \tservices = {
        \t\t       0      0 \tcom.apple.security.agent.login.00000000-0000-0000-0000-0000000186B6
        \t\t   97414      - \torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice-0x1002545ac
        \t\t   37718      - \tcom.apple.lskdd
        \t}
        \tdisabled services = {
        \t\t"org.pqrs.service.daemon.karabiner_grabber" => enabled
        \t}
        }
        """

    @Test func theDriversOwnJobIsNoRefusal() throws {
        let labels = try RecordCommand.labels(inPrinted: Self.system, domain: "system")
        #expect(labels == ["com.apple.security.agent.login.00000000-0000-0000-0000-0000000186B6",
                           "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice-0x1002545ac", "com.apple.lskdd"])
        #expect(RecordCommand.refusal(holder: nil, system: labels, session: []) == nil)
    }

    /// A disabled-services entry is not a loaded job; a loaded Karabiner job in either
    /// domain is refused by name.
    @Test func karabinerIsRefusedByName() {
        let refusal = RecordCommand.refusal(holder: nil, system: ["org.pqrs.service.daemon.karabiner_grabber"],
                                            session: ["org.pqrs.service.agent.karabiner_console_user_server"])
        #expect(refusal == .pqrsServices(["org.pqrs.service.agent.karabiner_console_user_server", "org.pqrs.service.daemon.karabiner_grabber"]))
    }

    @Test func aHolderIsRefused() {
        #expect(RecordCommand.refusal(holder: 4242, system: [], session: []) == .held(by: 4242))
    }

    /// A record this build cannot find services in is refused, not read as none.
    @Test func anUnreadableRecordIsRefused() {
        #expect(throws: RecordRefusal.self) { try RecordCommand.labels(inPrinted: "system = {\n}\n", domain: "system") }
    }
}
