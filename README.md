# vhid

A keyboard and mouse for your Mac that a script or an AI agent can use, and that macOS
treats as real hardware.

[![test](https://github.com/promptctl/vhid/actions/workflows/test.yaml/badge.svg)](https://github.com/promptctl/vhid/actions/workflows/test.yaml)
[![release](https://img.shields.io/github/v/release/promptctl/vhid)](https://github.com/promptctl/vhid/releases/latest)
[![license](https://img.shields.io/github/license/promptctl/vhid)](LICENSE)

Most tools that automate a Mac fake their keystrokes and clicks, and macOS can tell. It
asks you to grant each tool special permission first. Even then it ignores the fakes in
the places you most want to reach: the lock screen, the login window, password prompts,
and a Terminal that has Secure Keyboard Entry on.

vhid plugs a virtual keyboard and mouse into your Mac instead. macOS sees hardware, so
what vhid types lands wherever your own typing would, those places included, and no
per-app permission is needed. A second tool that comes with it, `eyes`, reads
the screen so a script or an agent knows where to click.

You can use it to:

- let an AI agent such as Claude operate the apps on your Mac,
- unlock or log in to a Mac from another computer over SSH,
- record what you do with the keyboard and mouse and play it back later.

[promptctl.github.io/vhid](https://promptctl.github.io/vhid/) shows it working, filmed.

## Try it

You need macOS 15 or later and an administrator account.

**1. Install it** with [Homebrew](https://brew.sh):

```sh
brew install --cask promptctl/tap/vhid
```

No Homebrew? Download the `.pkg` from the [Releases page](https://github.com/promptctl/vhid/releases/latest) and open it.

**2. Switch on the driver.** One step is left to you, because macOS won't let an installer approve a driver:

1. Open **System Settings > General > Login Items & Extensions**.
2. Click the **(i)** beside **Driver Extensions**.
3. Turn on **org.pqrs.Karabiner-DriverKit-VirtualHIDDevice**.

If you were logged in while it installed, the installer leaves that page open for you.

**3. Check that it's ready:**

```console
$ vhid doctor
ready
```

If it says `not ready`, the lines below it say what is left to do.

**4. Type something.** This opens a new file in TextEdit, types into it, and saves it:

```sh
touch hello.txt && open -e hello.txt && sleep 2
vhid type --into TextEdit "Hello from vhid"
vhid press --into TextEdit leftCommand+s
sleep 1 && cat hello.txt
```

`--into TextEdit` is a safety catch: if some other app has come to the front, vhid types
nothing and tells you which app it found there.

## Give it to an AI agent

In Claude Code, once vhid is installed:

```
/plugin marketplace add promptctl/vhid
/plugin install vhid@vhid
```

Then ask for what you want done, such as *"open TextEdit and write me a haiku"*. Claude
looks at the screen, clicks and types, and looks again to check that it worked. To let it
see the screen, run `eyes grants --ask` once and allow the two permissions macOS asks for.

## Learn more

| If you want to… | read |
|---|---|
| use everything vhid and eyes can do | [the user guide](docs/guide.md) |
| decide whether to trust it on your Mac | [security](docs/security.md) |
| connect it to another AI app | [docs/mcp.md](docs/mcp.md) |
| build it, or understand how it works | [architecture](docs/architecture.md) |

To remove it: `brew uninstall --cask vhid`, or see [the guide](docs/guide.md#installing) if you installed the `.pkg`.

vhid is open source under the [Apache License 2.0](LICENSE); [NOTICE](NOTICE) lists the
third-party software it carries. Its virtual devices are built
on [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
by pqrs.org. Questions and bug reports go in [GitHub issues](https://github.com/promptctl/vhid/issues).
