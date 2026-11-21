# vhid over MCP

One MCP server over stdio, `vhid mcp`, that reads the screen and drives the keyboard and mouse. This page covers what it serves, how to add it to a client, and which app has to hold the grants.

It serves `look`, `type`, `press`, `gesture`, `click`, `move`, `scroll`, `drag`, `play`,
`cursor` and `doctor`. Each but `look` is a vhid verb as an MCP tool, with the verb's
arguments; `play` takes the script as its `script` argument where the command line reads it
from stdin. `look` is `vhid look`: the screen as eyes reads it.

`look` alone lists the displays and the windows, front to back, names the frontmost
application, and reads the text of the app in front. With `text` it answers only where
that text is: the point to click, the box around the run, the run, and a scope line saying
what it read. `app` reads a named app instead, and `display`, `window`, `rect` or `page`
one place; `near`, `role`, `exact` and `edits` narrow the matches, and `until` with a
`timeout` waits for the text to appear or go. `x` and `y`, alone, say what a click at that
point would land on. [eyes.md](eyes.md) has what each reader sees.

`type` and `press` take `into`, an app's name as `look` prints the frontmost application,
and refuse, sending nothing, when another app is in front; [cli.md](cli.md) has the
rule.

Each call that drives connects to the daemon and leaves when it returns, so a session
holds nothing between calls and a `vhid click` from a shell still gets through; `look`
asks nothing of the daemon. Calls that drive run one at a time, in no promised order when
sent together; a `look` runs beside them, so one waiting on a change holds up no act. Stdout
carries only JSON-RPC; diagnostics go to stderr. An argument a tool will not act on comes
back as a tool error naming it, before anything is connected.

The server's answer to a client's initialize carries its instructions: the one
screen-point space and the loop below, ending with its version, as `This is vhid 0.6.0.`,
the version its `--version` prints, so an agent reads which release it is driving. Any MCP
client learns the loop from that, with or without the Claude Code plugin, whose
look-click-look skill opens with the same text; a test holds the skill's copy to the
server's.

In Claude Code, the vhid plugin adds the server, a skill that teaches the loop below, a
skill that invokes an app's menu item by its name, and a check at the start of each
session that tells the agent when vhid is missing or not `ready`:

```
/plugin marketplace add promptctl/vhid
/plugin install vhid@vhid
```

The plugin does not install vhid; the pkg or the cask does. It comes from vhid's newest
release, so it can teach a tool an older vhid does not have yet.

In Claude Code without the plugin:

```sh
claude mcp add --scope user vhid -- /usr/local/bin/vhid mcp
```

In Claude Desktop, merged into the `mcpServers` object of
`~/Library/Application Support/Claude/claude_desktop_config.json` (keeping any servers
already there), then quit and reopen it:

```json
{
  "mcpServers": {
    "vhid": { "command": "/usr/local/bin/vhid", "args": ["mcp"] }
  }
}
```

The tools that drive need what `vhid doctor` checks and no grant of the client's. `look`
needs Accessibility for the tree and Screen Recording for pixels, held by the app macOS
counts as responsible for the server: Claude Desktop, or the terminal app running
`claude` - under tmux, SSH or an editor's terminal, whichever app started that. A look at
a point needs Accessibility. `doctor` ends by saying whether each grant is held and naming
that app, read fresh on every call and never prompting; `eyes grants --ask`, run by a
person, is the only thing that raises macOS's dialog. Add the app under **System Settings
> Privacy & Security > Accessibility** and **Screen Recording**; `look` reads the grants
the same fresh way, so a grant switched on while the server runs counts from its next
call. A reader without its grant is named in the scope line; with neither, `look` answers
with a tool error saying so.

Every coordinate the server prints or takes is the same screen point, so one loop closes
without conversion:

| step | tool | what it answers |
|---|---|---|
| what is on screen | `look` `{}` | the displays, negative left of or above the main one; the windows, their owners and bounds, and the frontmost application; the text of the app in front |
| where the text is | `look` `{"text": "Save", "display": 3}` | the point to click, the box around the run, then the run it read: `-700,604	-724,596,48,17	Save	AXButton` on a display left of the main one |
| press it | `click` `{"box": "-724,596,48,17"}`, or `{"x": -700, "y": 604}` | where it clicked, or the reason it could not |
| what changed | `look` for the text again | the run gone, or still there, with a scope line saying where it looked |

Nothing here decides the next step. `click` presses the point it is given whatever is
there, and `look` reports what is on screen, not whether the click did what was meant.
