# Herdr for Omarchy

A bar widget for [herdr](https://herdr.dev): how many herdr servers are
running, what is inside each one, and one click to open it.

Herdr runs one server per named session. They are easy to start and they never
stop by themselves, because closing a window detaches rather than ends the
session. So they pile up unseen. This widget puts the count in the bar and the
list one click away.

## What it shows

The bar carries the number of running servers. The badge turns red when an
agent somewhere is blocked and waiting on an answer.

Each row in the panel is one session:

- its name, in bold when a window is already showing it
- the projects open inside it, taken from the workspace labels
- how many agents it holds, and what the most urgent of them is up to
- what each of those agents is doing, from its terminal title, with its own
  status dot beside it - three at most, the rest counted
- a dot in the session's colour, taking the state of its loudest agent

## The states

Herdr classifies every agent, and two of those states are the reason to look
at all:

| | | |
|---|---|---|
| **needs you** | red | herdr recognised an approval or a question on screen: that agent is waiting on an answer |
| **done** | green | it finished work you have not seen yet. Focusing the tab turns it back into plain idle |
| working | accent | busy |
| idle | grey | ready for input, and already seen |

Both **needs you** and **done** are written at full strength with the word
beside them; the rest of the list stays dimmed. The badge in the bar takes the
same colour, so a herd that wants something says so with the panel closed.

Waiting beats finished beats busy, wherever a session has to be summed up in
one colour.

## What it does

- **Click a row** (or `Enter`, or `o`) to open that session. A session shows at
  most one window, because two windows on one session mirror each other, so
  this focuses the window it already has, wherever it is, and only opens a new
  one when there is none.
- **The power button** (or `x`) stops that server. On a session that is already
  stopped it deletes the session instead, which is what clears it out of the
  list for good. The shared default session has no such button: it is the one
  herdr expects to keep.
- **`r`** refreshes, and so does a middle click on the bar button.

The list refreshes every three seconds while the panel is open and every twenty
seconds when it is closed.

## Screenshots

The data script has a demo mode, so a screenshot never carries real project
names or agent titles and looks the same in a year:

```bash
bin/herdr-sessions demo on
# ... take the screenshot ...
bin/herdr-sessions demo off
```

Every write is a no-op while it is on, so a click during a shoot cannot stop a
real server.

## Installing it

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-herdr
omarchy plugin enable jankeesvw.herdr
omarchy bar move jankeesvw.herdr --section right
```

Needs `herdr`, `jq` and `hyprctl` on `$PATH`. The last one is what pairs a
session with the window showing it; without Hyprland the list still works, but
every session looks like it has no window and a click opens a new one.

## Removing it

```bash
omarchy plugin disable jankeesvw.herdr
omarchy plugin remove jankeesvw.herdr
```

The widget keeps no cache of your work: every value on screen is read from
herdr at the moment it is drawn, and nothing about your projects, agents or
titles is ever written to disk.

The one file it can create is the demo flag, and only if you turned demo mode
on. It is empty and holds nothing about you, but it outlives the plugin:

```bash
rm -rf ~/.cache/omarchy-herdr
```

Your herdr sessions are untouched by removing the plugin - they live in
`~/.config/herdr/` and are herdr's, not this widget's.

## License

MIT
