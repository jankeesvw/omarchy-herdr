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
- how many agents it holds, and how many of those are working or blocked
- what each of those agents is doing, from its terminal title, with its own
  status dot beside it - three at most, the rest counted
- a dot in the session's colour: red for blocked, accent for working, grey
  for idle, faint for a stopped server

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

Nothing is left behind. The widget writes no cache, no config and no state of
its own: every value on screen is read from herdr at the moment it is drawn.
Your herdr sessions are untouched by removing the plugin - they live in
`~/.config/herdr/` and are herdr's, not this widget's.

## License

MIT
