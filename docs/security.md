# Security: what vhid can do on your Mac

vhid exists to type and click in places macOS normally protects, such as the lock screen,
password prompts and the login window. That is useful, and it is also exactly what you
should understand before installing it. This page says what runs with elevated
privileges, who can make it type, what it records, and how to take it all out.

## What runs as root

| Process | Why |
|---|---|
| `vhidd`, the background service | the driver accepts commands only from a root process |
| a child of `vhidd` that reads the pointer position | the position can only be read from inside the session at the screen |
| `Karabiner-VirtualHIDDevice-Daemon`, from pqrs.org | the one process macOS allows to open the driver; `vhidd` starts it if nothing else has |

The driver itself is a DriverKit extension. It runs outside the kernel, and macOS loads it
only after it is switched on in System Settings, with an administrator's approval. The
installer can't switch it on. What clicks that switch is a person, or a program you have
already given Accessibility.

None of these listen on the network. `vhid` reaches `vhidd` over XPC, which is local to
the Mac.

## Who can make it type

`vhidd` accepts a caller only if the caller is signed with the same certificate `vhidd`
is signed with. For the released package, that is promptctl's Developer ID. It checks the
calling process through the kernel's audit token, so a different program can't pass by
borrowing a process id. It checks nothing else: not the program's name, not its path, not
its version. So it accepts every program signed with that certificate: `vhid`, the other
tools in the package (`eyes`, the menu bar item, `vhid-record.app`), the copy Homebrew
keeps in its Caskroom, and every earlier release of each, including releases older than a
fix you are relying on. Every other program is refused.

**What it does not check is who is running the program.** Any account that can run
programs on the Mac can run `/usr/local/bin/vhid`, whether it's an administrator or not
and whether it's at the keyboard or connected over SSH. So can any program running as
that account. Each of them can type and click into whatever is on screen: another user's
session, the lock screen, or the login window. That is how remote unlocking works, and it
is the main thing to weigh. On a Mac where you don't trust every account that can log in,
or every program those accounts run, vhid gives them a way to type into the session at
the screen.

What `vhid` can't do is just as useful to know:

- **It can't see the screen.** It types and clicks blind. Reading the screen is `eyes`'
  job, and `eyes` gets nothing without the Accessibility and Screen Recording permissions
  you grant to the app that runs it.
- **It can't read your typing.** The virtual devices only send input. `vhid record` is the
  exception, and it works only after you grant Input Monitoring to `vhid-record.app`.
- **It can't reach the FileVault unlock screen.** Nothing of vhid runs before the disk is
  unlocked.

`vhid` serves one caller at a time. Each command claims the devices, acts, and lets
go. A caller that holds a key down past a time limit has the key released for it.

## What it writes down

In vhid releases after 0.4.1, every `vhid` run appends one line to `~/Library/Logs/vhid/events.jsonl`, in the home
folder of the account that ran it. The line holds the command's name, whether it
worked, how long it took and how many reports it sent. It never holds the text typed. It
doesn't quote arguments it refused, either, because those could hold a password. `eyes`
keeps a similar log in `~/Library/Logs/eyes/`. With `OTEL_EXPORTER_OTLP_ENDPOINT` set,
these records go to that collector instead. Nothing is sent anywhere unless you set it.

**A recording is your keystrokes.** `vhid record` writes every key you press, in order,
to the file you name, as plain text. A password typed while recording is in that file.
Treat the file the way you'd treat the password.

## Taking it out

```sh
brew uninstall --zap --cask vhid                  # installed with Homebrew
sudo /usr/local/libexec/vhid-uninstall --driver   # installed from the pkg
```

Either one stops the service, removes every file vhid installed, and withdraws the
driver. To keep the driver, leave off `--zap` or `--driver`. While Karabiner-Elements is
installed, removing the driver is refused: `--driver` then removes nothing at all, and
`--zap` removes vhid but leaves the driver. Your logs in `~/Library/Logs/vhid` and
`~/Library/Logs/eyes` stay; delete them yourself.
[installing.md](installing.md#uninstalling) lists every file and every refusal.

## Where the code is

The admission check is
[`Sources/vhidd/CallerIdentity.swift`](../Sources/vhidd/CallerIdentity.swift), the
one-caller rule is [`Sources/vhidd/Holder.swift`](../Sources/vhidd/Holder.swift), and the
complete list of what a caller can ask `vhidd` to do is the protocol in
[`Sources/Helper/HelperService.swift`](../Sources/Helper/HelperService.swift).
[architecture.md](architecture.md) explains why each piece is where it is.
