import Darwin

/// Starts `executable` as this process's child, with the hygiene every child of vhidd
/// needs. [LAW:single-enforcer] Every child vhidd starts is started here, the commands it
/// runs to read the driver with them.
///
/// - Every signal at its default, and none blocked: vhidd ignores SIGTERM to answer it on
///   a queue, the threads dispatch runs its queues on block it, and `vhid record` ignores
///   SIGINT while it records. An ignored signal and a blocked one are both inherited
///   across exec, and either would leave that signal nothing to stop.
/// - No descriptor of vhidd's but the ones named: a child that held the write end of a
///   reader's stdin would keep that reader alive past vhidd itself. `stdio` maps a child's
///   0, 1 or 2 onto a descriptor of vhidd's; any of the three it leaves out is vhidd's own.
///
/// The pid is the caller's to reap, and until it does, no other process can have it.
public func spawn(_ executable: String, _ arguments: [String], stdio: [Int32: Int32]) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var every = sigset_t()
    sigfillset(&every)
    posix_spawnattr_setsigdefault(&attributes, &every)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attributes, &none)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for standard in Int32(0)...2 {
        if let from = stdio[standard] {
            posix_spawn_file_actions_adddup2(&actions, from, standard)
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, standard)
        }
    }
    let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    guard spawned == 0 else { throw CouldNotStart(executable: executable, code: spawned) }
    return pid
}

public struct CouldNotStart: Error, CustomStringConvertible {
    public let executable: String
    public let code: Int32
    public var description: String { "could not start \(executable): \(String(cString: strerror(code))) (\(code))" }
}
