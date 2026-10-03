# vhid and eyes over MCP

Two MCP servers over stdio, one for input and one for reading the screen. This page covers what each serves, how to add them to a client, and which app has to hold the grants.

`vhid mcp` serves the same verbs as MCP tools over stdio: `type`, `press`, `gesture`,
`click`, `move`, `scroll`, `drag`, `play`, `cursor` and `doctor`, run as `vhid mcp`. `play` takes
the script as its `script` argument where the command line reads it from stdin.

Each tool call connects to the daemon and leaves when it returns, so a session holds
nothing between calls and a `vhid click` from a shell still gets through. Stdout carries
only JSON-RPC; diagnostics go to stderr. An argument a tool will not act on comes back as
a tool error naming it, before anything is connected.

`eyes mcp` serves `windows`, `displays`, `find`, `read` and `grants` the same way. The two are
separate servers, and a client runs both.

In Claude Code, the vhid plugin adds both servers, a skill that teaches the loop below,
a skill that invokes an app's menu item by its name, and a check at the start of each
session that tells the agent when vhid is missing or not `ready`:

```
/plugin marketplace add promptctl/vhid
/plugin install vhid@vhid
```

The plugin does not install vhid; the pkg or the cask does. It follows this repository's
`master`, so it can teach a tool the latest release does not have yet.

In Claude Code without the plugin:

```sh
claude mcp add --scope user vhid -- /usr/local/bin/vhid mcp
claude mcp add --scope user eyes -- /usr/local/bin/eyes mcp
```

In Claude Desktop, merged into the `mcpServers` object of
`~/Library/Application Support/Claude/claude_desktop_config.json` (keeping any servers
already there), then quit and reopen it:

```json
{
  "mcpServers": {
    "vhid": { "command": "/usr/local/bin/vhid", "args": ["mcp"] },
    "eyes": { "command": "/usr/local/bin/eyes", "args": ["mcp"] }
  }
}
```

vhid's tools need what `vhid doctor` checks and no grant of the client's. eyes'
`windows` and `displays` need nothing. `find` and `read` need Accessibility for the tree
and Screen Recording for pixels, held by
the app macOS counts as responsible for the server: Claude Desktop, or the terminal app
running `claude` - under tmux, SSH or an editor's terminal, whichever app started that.
The `grants` tool says whether each is held and names that app, read fresh on every call
and never prompting; `eyes grants --ask`, run by a person, is the only thing that raises
macOS's dialog. Add the app under **System Settings > Privacy & Security >
Accessibility** and **Screen Recording**; `find` and `read` read the grants the same fresh
way, so a grant switched on while the server runs counts from its next call. A reader
without its grant is named in the scope line;
with neither, `find` and `read` answer with a tool error saying so.

Every coordinate either server prints or takes is the same screen point, so one loop
closes without conversion:

| step | tool | what it answers |
|---|---|---|
| where the displays are | eyes `displays` | each id and its bounds, negative left of or above the main display |
| what is in front | eyes `windows` | each window's owner and bounds, and the frontmost application |
| where the text is | eyes `find` `{"text": "Save", "display": 3}` | the point to click, then the run it read: `-700,604	Save` on a display left of the main one |
| press it | vhid `click` `{"x": -700, "y": 604}` | where it clicked, or the reason it could not |
| what changed | eyes `find` again | the run gone, or still there, with a scope line saying where it looked |

Neither server decides the next step. `click` presses the point it is given whatever is
there, and `find` reports what is on screen, not whether the click did what was meant.
