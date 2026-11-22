# maiden repl keybindings

## global

the built-in TUI REPL (`maiden repl`) uses these shortcuts in the main view:

| key | action |
|:----|:-------|
| tab | switch between norns and supercollider output |
| ctrl+b | focus the script browser (shows it if hidden) |
| ctrl+shift+b | show/hide the script browser pane |
| esc | return focus to the input line |
| ctrl+p | play focused script |
| ctrl+x | stop script |
| ctrl+e | edit focused script in `$EDITOR` |
| ctrl+u | update selected project (catalog / git) |
| ctrl+n | new script (script pane must be focused) |
| ctrl+backspace | delete selected project directory |
| ctrl+l | redraw |
| ctrl+c / ctrl+q | quit |
| page up / page down | scroll output |

(note: many terminals send ctrl+backspace as ctrl+h.)

## script browser

when the script pane has focus:

| key | action |
|:----|:-------|
| ↑ / k | previous item |
| ↓ / j | next item |
| enter | play focused script |
| ← / → / space / o | expand or collapse folder |
| e | edit focused script in `$EDITOR` |
| r | rescan scripts |

## input

when the input line has focus:

| key | action |
|:----|:-------|
| enter | send line to the active repl |
| ↑ / ↓ | older / newer history |
| ← / → / home / end | move cursor |
| backspace / delete | edit text |

## dialogs

confirm and name-prompt overlays:

| key | action |
|:----|:-------|
| enter | accept (confirm: only if Yes is selected) |
| y / n | accept / cancel confirm |
| ← / → / tab | toggle Yes / No on confirm |
| esc | cancel |
| ctrl+c / ctrl+q | cancel |

## special commands

lines starting with `;` are special commands:

| command | action |
|:--------|:-------|
| `;install <url>` | install a project via the maiden server |
| `;restart` | restart the active unit |
| `;start` | start the active unit |
| `;stop` | stop the active unit |
