# Where vhid reaches

Measured 2026-09-28 on studious (macOS 15.0.1, one display, US layout, FileVault off), vhid 0.1.0 as
installed by the pkg. Every call was `vhid` run over SSH as the admin user `bmf`, unless the row says
otherwise.

| Where | XPC reaches vhidd | a keystroke lands | layout resolves | cursor reads | click lands |
|---|---|---|---|---|---|
| Logged in, SSH as the console user | yes | yes | yes, the user's | yes | yes |
| That user's lock screen | yes | yes | yes | yes | yes |
| Terminal with Secure Keyboard Entry on | yes | yes | yes | yes | yes |
| System password prompt (SecurityAgent) | yes | yes | yes | yes | yes |
| Login window, nobody logged in | yes | yes | the SSH user's, see below | no: reads (0, 0) | no |
| After fast user switching, SSH as the user now in the background | yes | yes | the SSH user's, not the one in front | no: reads (0, 0) | no |
| FileVault pre-boot | impossible | impossible | impossible | impossible | impossible |

How each cell was shown:

- XPC: `vhid doctor` printed `ready` in every row, and each verb below got an answer from vhidd.
- Layout: every `vhid type` and `vhid press` printed the layout it resolved, `com.apple.keylayout.US`.
- Keystrokes: at the lock screen, the logged-out login window and the password prompt, `vhid type
  wrongpass` then `vhid press return` produced opendirectoryd's `ODErrorCredentialsInvalid` or
  authorizationhost's `Failed to authenticate user`. At the login window with bmf in the background,
  typing vhidtest's real password logged it in. In Terminal, with `kCGSSessionSecureInputPID` naming
  Terminal, the shell ran the command vhid typed.
- Cursor: `vhid cursor` printed the real position, or (0, 0) where the table says so.
- Clicks: Cancel on the password prompt ended `osascript` with -128; the vhidtest tile on the lock
  screen opened its password field; a click outside Terminal moved focus away from it.

## Cursor and click without a readable cursor

The cursor is read with `CGEvent(source: nil).location`, in `Sources/Input/Pointer.swift:88` and, with
`?? .zero`, in `Sources/vhid-record/main.swift:112`. When the caller's user is not the console user
(nobody logged in, or another user in front), that read answers (0, 0) as though it were a real
position, not an error. `click`, `move` and `drag` steer by reading the cursor back, see no motion, and
stop with `the cursor would not reach (x, y): it is at (0, 0) after 3 reports`. The exception is a
target within one step of (0, 0): the move is read as already there, so `click` reports success and
presses wherever the pointer really is (`Pointer.swift:196`).

Since then, `Pointer.screenCursor` asks the console user first and refuses the read, naming who is in
front, when the caller is neither that user nor root, or when nobody is logged in. Root read the same
position as bmf while bmf was in front.

What matters is the user, not the login session. Plain SSH as bmf, outside bmf's GUI session, read
the cursor and clicked while bmf was in front. With vhidtest in front, the same SSH call read (0, 0),
and `sudo launchctl asuser 503 sudo -u vhidtest vhid cursor` read the real position and `move` reached
its point. So with another user in front the device still moves the pointer; only reading it back fails.
Whether it moves at the empty login window was not read back. With nobody
logged in there is no user to run as, and a click cannot be placed: vhid moves by relative counts and
finds its target by reading the cursor.

## Layout at the login window

The layout is the calling process's own user's, never the console's
(`Sources/KeyboardLayouts/KeyboardLayout.swift:39-47`, measured earlier with Dvorak: `sudo` is answered
with root's US). At the login window, and after fast user switching, that is the SSH user's layout.
It types correctly only when it matches the layout the login window or the user in front is using. On
studious all of them are US, so every password landed. With nobody logged in, the CLI cannot see the
login window's layout, so no reading can check it: `type` and `press` take `--layout <input source
id>` to name it, and fall back to US English only when the system reports no layout at all.

## FileVault pre-boot

Impossible. Before the disk is unlocked, macOS has not started: neither vhidd nor the DriverKit
extension is running, so there is no daemon to call and no virtual keyboard to press. The unlock screen
reads the Mac's own keyboard only.
