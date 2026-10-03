# Menu items: which route reaches them

An agent invokes a menu item that has no shortcut best through the Help menu's search: click Help, type the start of the item's name, check the results, then press Down and Return. Clicking down the menu path is the fallback, needed for items in the Help menu itself. Giving the item an App Shortcut in System Settings works too, but it makes a lasting change to the user's keyboard settings for a gain that only repeated use repays. This note records how each route did, and where each fails.

Measured on studious on 2026-10-03: macOS 15.0.1, TextEdit 1.20, Finder, Chrome 154, VS Code 1.139.1 (Electron), Calculator; vhid 0.2.0, eyes 0.3.0-dev+a5e9794. Every act went through vhid's devices, aimed by eyes. Each invocation was checked by what it opened: a sheet, a panel, a tab, or a window resized.

## The routes

1. **Path.** Find the menu title in the menu bar, click it, find the item in the open menu, click it.
2. **Help search.** Click the Help menu, type the item's name into its search field, read the "Menu Items" results, press Down to select the first, then Return.
3. **App Shortcut.** In System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts, add the app, the item's title and a key combination, then `vhid press` it.

| App, item | Path | Help search | App Shortcut |
| --- | --- | --- | --- |
| TextEdit, File > Export as PDF… | worked | worked | worked |
| TextEdit, File > Save As… (shown only with Option held) | worked, with Option held through `vhid play` | worked: listed without Option held | not tried |
| TextEdit, Edit > Substitutions > Show Substitutions | not tried | not tried | worked, given as the path `Edit->Substitutions->Show Substitutions` |
| Finder, View > Customize Toolbar… | not tried | worked | not tried |
| Chrome, Window > Task Manager | not tried | worked | worked |
| VS Code, Help > Welcome | worked | not tried | worked |
| VS Code, Help > Show Release Notes | not tried | **failed**: "No Results Found" | not tried |
| TextEdit, Help > TextEdit Help | not tried | **failed**: Help Topics only, no Menu Items | not tried |
| VS Code, File > New Window | not tried | worked; also listed the submenu item "New Window with Profile > New Profile…" | not tried |
| Calculator in French, Présentation > Scientifique | not tried | not tried | worked under the French title; the English title "Scientific" did nothing |

No app tested ignored App Shortcuts: TextEdit, Chrome, Electron's VS Code and Calculator all took them.

## Why Help search

It takes one aimed click, the Help title, and after that only typing and two keys. It finds an item at any depth without the agent knowing its path. Its result rows show a nested item's path ("New Window with Profile > New Profile…"), so the agent can confirm the match before pressing Return. It lists items that appear only with Option held, so nothing needs holding. And because the agent types a prefix of the name, the "…" a title ends with never has to be matched.

It changes nothing on the machine, which the App Shortcut route cannot say.

## Where each route fails

**Help search does not search the Help menu.** In VS Code, "Show Release Notes" sits in the Help menu and the search answered "No Results Found"; File's "New Window" was found. In TextEdit, a search for its Help menu's "TextEdit Help" listed Help Topics and no Menu Items. An item in the Help menu needs the path route.

**⇧⌘/ is not a reliable way to open Help search.** In TextEdit it opened the TextEdit User Guide in Tips: the app's own "TextEdit Help ⌘?" took the keystroke before the system's Show Help menu shortcut did. Click the Help title instead; it worked every time.

**Down picks the first menu result, which may not be the one meant.** Read the rows between "Menu Items" and "Help Topics" before pressing Return. A search with no menu result still has Help Topics below it.

**eyes reads menus by pixels only.** The tree reader walks an app's windows (`kAXWindowsAttribute` in [TreeReader.swift](../../eyes/Sources/Tree/TreeReader.swift)) and never its menu bar, and an open menu is not one of those windows. So every menu title and item comes from Vision. Four things follow:

- Pixels reads "…" as "...", so `eyes find "Export as PDF…"` answers "not found", one edit off. Search for the name without its ellipsis.
- A menu bar can read as one run ("TextEdit File Edit Format View"). `eyes find File --rect 0,0,800,30` still answered File's own point.
- A title can sit inside another: `eyes find Edit --rect 0,0,800,30` in TextEdit answered two points, "TextEdit" first and "Edit" second, and `--exact Edit` answered "not found". Take the match whose text is the title alone, not the first.
- Case and glyphs drift: VS Code's "Go" read as "GO", and ⌘N as "g8 N".

**The path route clicks blind under Option unless the hold runs in the background.** A script that holds `leftOption` for a few seconds, run in the background with the File menu open, left eyes free to read the menu: "Save As..." stood where Duplicate had been. The Save As… click in the table went in blind, aimed at Duplicate's place from a read taken before Option was down; reading under the hold confirms the row before the click.

**An App Shortcut changes the user's machine.** It stays in the user's keyboard settings, shows up in System Settings, and rebinds the item for the person as well as the agent. Assigning it took about ten aimed acts in System Settings. The add sheet was read by pixels alone, because the tree left it unwalked. Its Application pop-up lists every app; typing the app's name with `vhid type` selected it.

**Nothing confirms an App Shortcut's title matched.** The sheet accepts any text. A title in the wrong language binds nothing: in French Calculator, "Scientific" did nothing and "Scientifique" switched modes. "Export as PDF..." with three dots did match "Export as PDF…".

**A global hotkey beats an App Shortcut.** ⌃⌥⌘N, given to Calculator's Scientifique, opened Little Snitch's Network Monitor instead. The menu showed the shortcut beside the item all the same.

**The App Shortcut route took effect without a relaunch.** Assignments made in System Settings worked at once in the running TextEdit, VS Code and Chrome, and removing them did too.

## Localized menus

An app shows its menus in its own language, and every route uses those words. In French, Calculator's menus read "Calculette", "Édition", "Présentation", "Fenêtre", "Aide", and `eyes windows` named its owner "Calculette". To find Help in an unknown language, use its place: in every app here it was the last menu title. `--rect 0,0,800,30` reached it in each; an app with more titles needs a wider rect.

## Repeating it

On studious, with vhid at `/usr/local/bin/vhid` and eyes at hand. For each app, bring it to the front with `open -a`, check `Frontmost` in `eyes windows`, then:

- Path: `eyes find <title> --rect 0,0,800,30`, click it, then `eyes read --window <id>` on the app's layer-101 window, which is the open menu, and click the item.
- Help search: as for the path, with `Help` as the title; `vhid type` the name; read the layer-101 window; `vhid press down`, then `return`.
- App Shortcut: `open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"`, click Keyboard Shortcuts…, App Shortcuts, then Add. Read the sheet with `--source pixels`. `defaults read <bundle id> NSUserKeyEquivalents` shows what was stored, the path form as `\033Edit\033Substitutions\033Show Substitutions`.

Two traps cost time. A keystroke meant for a sheet or menu that did not open lands in the document behind it: one Help-search attempt typed its query into an open TextEdit document. And a sheet left open from a previous step takes the next shortcut: check that it is gone before pressing again.
