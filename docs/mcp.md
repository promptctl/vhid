# vhid over MCP

One MCP server over stdio that reads the screen and drives the devices. This page covers what it serves, how to add it to a client, and which app has to hold the grants.

`vhid mcp` serves the verbs as MCP tools over stdio: `look`, `type`, `press`, `gesture`,
`click`, `move`, `scroll`, `drag`, `play`, `cursor` and `doctor`. `play` takes the script
as its `script` argument where the command line reads it from stdin.

`look` takes the options `vhid look` takes, by the same names: `text`, `exact`, `edits`,
`near`, `until`, `timeout`, at most one place of `display`, `window`, `page`, `rect` and
`app`, `limit`, `source` and `role`, or `x` and `y` with nothing else. With no `text` it
answers with the displays, the windows front to back, and the text read in the place, or
`No text was read:` and why; with `text`, the scope line and the matching rows alone; with
`x` and `y`, what a click there would land on. [cli.md](cli.md) has each argument and
[eyes.md](eyes.md) the reading behind it. A `look` asks nothing of the daemon, so it waits
behind no device call and needs no daemon to be ready.

`type` and `press` take `into`, an app's name as `look` prints the frontmost application,
and refuse, sending nothing, when another app is in front; [cli.md](cli.md) has the
rule.

Each device tool call connects to the daemon and leaves when it returns, so a session
holds nothing between calls and a `vhid click` from a shell still gets through. Stdout
carries only JSON-RPC; diagnostics go to stderr. An argument a tool will not act on comes
back as a tool error naming it, before anything is connected.

The server's answer to a client's initialize carries instructions,
[mcp-instructions.txt](mcp-instructions.txt): the one screen-point space and the loop
below. It ends them with its name and version, as `This is vhid 0.5.0.`, the version
`--version` prints, so an agent reads which release it is driving. Any MCP client learns
the loop from that, with or without the Claude Code plugin, whose look-click-look skill
opens with the same text; tests hold the server's copy and the skill's to that file.

In Claude Code, the vhid plugin adds the server, a skill that teaches the loop below,
a skill that invokes an app's menu item by its name, and a check at the start of each
session that tells the agent when vhid is missing, not `ready`, or without a grant `look`
needs:

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

The device tools need what `vhid doctor` checks and no grant of the client's. `look`
lists the displays and windows with no grant. Its text needs Accessibility for the tree and
Screen Recording for pixels, and `x` and `y` need Accessibility, held by the app macOS
counts as responsible for the server: Claude Desktop, or the terminal app running
`claude` - under tmux, SSH or an editor's terminal, whichever app started that. `doctor`
ends with whether each is held and names that app, read fresh on every call and never
prompting; `eyes grants --ask`, run by a person, is the only thing that raises macOS's
dialog. Add the app under **System Settings > Privacy & Security > Accessibility** and
**Screen Recording**; `look` reads the grants the same fresh way, so a grant switched on
while the server runs counts from its next call. A reader without its grant is named in
the scope line; with neither, a `look` with `text` answers with a tool error saying so,
and one without says so in place of the text.

Every coordinate a tool prints or takes is the same screen point, so one loop closes
without conversion:

| step | tool | what it answers |
|---|---|---|
| what is in front | `look` | each display's id and bounds, negative left of or above the main display; each window's owner and bounds, and the frontmost application; the text read in front |
| where the text is | `look` `{"text": "Save", "display": 3}` | the point to click, the box around the run, then the run it read: `-700,605	-724,596,48,17	Save	AXButton` on a display left of the main one |
| press it | `click` `{"box": "-724,596,48,17"}`, or `{"x": -700, "y": 604}` | where it clicked, or the reason it could not |
| what changed | `look` again | the run gone, or still there, with a scope line saying where it looked |

No tool decides the next step. `click` presses the point it is given whatever is
there, and `look` reports what is on screen, not whether the click did what was meant.
