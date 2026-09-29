# Where vhid reaches

Measured 2026-09-28 on studious (macOS 15.0.1, one display, US layout, FileVault off), vhid 0.1.0 as
installed by the pkg, every call made over SSH as the admin user `bmf` unless the row says otherwise.

| Where | XPC reaches vhidd | a keystroke lands | layout resolves | cursor reads | click lands |
|---|---|---|---|---|---|
| Logged in, SSH as the console user | yes | yes | yes, the user's | yes | yes |
| That user's lock screen | yes | yes | yes | yes | yes |
| Terminal with Secure Keyboard Entry on | yes | yes | yes | yes | yes |
| System password prompt (SecurityAgent) | yes | yes | yes | yes | yes |
| Login window, nobody logged in | yes | yes | US, see below | no: reads (0, 0) | no |
| After fast user switching, SSH as the user now in the background | yes | yes | US | no: reads (0, 0) | no |
| FileVault pre-boot | impossible | impossible | impossible | impossible | impossible |

How each yes was shown:

- Keystrokes: at the lock screen and both login windows, `vhid type wrongpass` then `press return`
  produced opendirectoryd's `ODErrorCredentialsInvalid` / authorizationhost's `Failed to
  authenticate user`. At the login window with bmf in the background, typing vhidtest's real
  password logged it in. Behind the password prompt and in Terminal, `kCGSSessionSecureInputPID` named
  the prompt and Terminal, and Terminal ran the command vhid typed.
- Clicks: Cancel on the password prompt ended `osascript` with -128; the vhidtest tile on the lock
  screen opened its password field; a click outside Terminal moved focus away from it.

## Cursor and click without a readable cursor

The cursor is read with `CGEvent(source: nil).location` (`Sources/Input/Pointer.swift:88`). A caller
outside the console user's GUI session - nobody logged in, or another user in front - gets (0, 0)
back as though it were a real position, not an error. `click` and `move` then steer toward their
point, see no motion, and stop with `the cursor would not reach (x, y): it is at (0, 0)`.

The devices are not the limit. With vhidtest in front, `sudo launchctl asuser 503 sudo -u vhidtest
vhid cursor` read the real position and `move` reached its point. So pointer verbs work from any
caller that runs in the console user's session, and from nowhere else. With nobody logged in no such
session exists, and a click cannot be placed: vhid moves by relative counts and steers by reading the
cursor back.

## Layout at the login window

With nobody logged in, `TISCopyCurrentKeyboardLayoutInputSource` in the SSH-launched CLI still answered
`com.apple.keylayout.US`, and the typed password was accepted. On this US-only Mac that doesn't show
whether it read the login window's layout or a default for a process with no session. On a Mac whose
login window uses another layout, the CLI could type the wrong characters and not know it, so an
explicit layout is the safe path there.

## FileVault pre-boot

Impossible. Before the disk is unlocked, macOS has not started: neither vhidd nor the DriverKit
extension is running, so there is no daemon to call and no virtual keyboard to press. The unlock screen
reads the Mac's own keyboard only.
