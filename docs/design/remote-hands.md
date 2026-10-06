# Where vhid reaches

Measured 2026-09-28 on studious (macOS 15.0.1, one display, US layout, FileVault off), vhid 0.1.0 as
installed by the pkg; the cursor and click columns again on 2026-09-29, once vhidd read the cursor.
Every call was `vhid` run over SSH as the admin user `bmf`, unless the row says otherwise.

| Where | XPC reaches vhidd | a keystroke lands | layout resolves | cursor reads | click lands |
|---|---|---|---|---|---|
| Logged in, SSH as the console user | yes | yes | yes, the user's | yes | yes |
| That user's lock screen | yes | yes | yes | yes | yes |
| Terminal with Secure Keyboard Entry on | yes | yes | yes | yes | yes |
| System password prompt (SecurityAgent) | yes | yes | yes | yes | yes |
| Login window, nobody logged in | yes | yes | the SSH user's, see below | yes | yes |
| After fast user switching, SSH as the user now in the background | yes | yes | the SSH user's, not the one in front | yes | yes |
| FileVault pre-boot | impossible | impossible | impossible | impossible | impossible |

How each cell was shown:

- XPC: `vhid doctor` printed `ready` in every row, and each verb below got an answer from vhidd.
- Layout: every `vhid type` and `vhid press` printed the layout it resolved, `com.apple.keylayout.US`.
- Keystrokes: at the lock screen, the logged-out login window and the password prompt, `vhid type
  wrongpass` then `vhid press return` produced opendirectoryd's `ODErrorCredentialsInvalid` or
  authorizationhost's `Failed to authenticate user`. At the login window with bmf in the background,
  typing vhidtest's real password logged it in. In Terminal, with `kCGSSessionSecureInputPID` naming
  Terminal, the shell ran the command vhid typed.
- Cursor: `vhid cursor` printed the real position, and a click at (40, 400) left it within a point of there.
- Clicks: Cancel on the password prompt ended `osascript` with -128; the vhidtest tile on the lock
  screen opened its password field; a click outside Terminal moved focus away from it.

## Reading the cursor in the session in front

A process outside the session in front reads the cursor as (0, 0), as though it were a real
position: SSH as bmf at the login window, `sudo`, and `launchctl asuser` into a user in the background
all did. So vhidd reads it, over XPC, and not the client. Measured 2026-09-29, at the login window
after fast user switching:

- A root process that joined the audit session IOConsoleUsers marks on console (`audit_session_join`)
  read the real position, and one that joined bmf's session in the background read (0, 0).
- A process is tied to the session of its first read: after joining another session and reading again,
  it kept its first answer. So vhidd runs a reader child (`vhidd --read-screen-in <session>`) per
  session in front and starts a new one when the session changes (`Sources/vhidd/FrontScreen.swift`).
- `launchctl asuser 88` (`_windowserver`) read at the empty login window but not after fast user
  switching, and `launchctl bsexec` into the front loginwindow read (0, 0): neither is the session.

`scripts/reach` checked every row after the change; the table above is that run.

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
