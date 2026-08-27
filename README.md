# Herdr for Omarchy

A bar widget for [herdr](https://herdr.dev): how many herdr servers are
running, what is inside each one, and one click to open it.

Herdr runs one server per named session. They are easy to start and they never
stop by themselves, because closing a window detaches rather than ends the
session. So they pile up unseen. This widget puts the count in the bar and the
list one click away.

![The Herdr panel open on a desktop, listing four sessions with the agents inside each](assets/screenshot.png)

## What it shows

The bar carries the number of running servers. The badge turns red when an
agent somewhere is blocked and waiting on an answer.

Each row in the panel is one session:

- its name, in bold when a window is already showing it
- the projects open inside it, taken from the workspace labels
- how many agents it holds, and what the most urgent of them is up to
- what every one of those agents is doing, from its terminal title, with its
  own status dot beside it. All of them, however many and wherever herdr keeps
  them: a pane in a second tab counts the same as one sitting in front of you.
  Each of those lines is its own way in
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

Every agent line carries its state as a word, right-aligned in one column down
the edge of the panel, so what the herd is doing is a single glance rather than
a scan. The agents inside a session are ordered by that state rather than by
where they happen to sit - what wants an answer first, then what finished
unseen, then what is busy, then what is only waiting for you to type. That is
herdr's own attention queue, the order its agent panel takes when
`agent_panel_sort = "priority"`. `idle` is written as **ready**, because it is the ordinary resting
state and "idle" reads like a fault.

Both **needs you** and **done** are written bold and in colour, along with the
title beside them; **working** and **ready** stay quiet. The badge in the bar
takes the same colour, so a herd that wants something says so with the panel
closed.

Waiting beats finished beats busy, wherever a session has to be summed up in
one colour.

## What it does

- **Click a row** (or `Enter`, or `o`) to open that session. A session shows at
  most one window, because two windows on one session mirror each other, so
  this focuses the window it already has, wherever it is, and only opens a new
  one when there is none. Without a window one is started, in foot.
- **Click one of the agent lines** to land on that agent rather than on
  whatever the session was last showing: its pane is focused inside the server
  first, then the window comes up. That also marks a finished agent as seen, so
  clicking the line that says **done** is what clears it.
- **The skull** (or `k`) ends that server, and is the only way it is ended from
  here. It asks first, and the dialog opens on **Cancel** rather than on the
  confirming side: a dialog that destroys something on a reflexive Enter is
  worse than no dialog, because it trains the reflex. It is the only action in
  the panel that stops to ask - opening, focusing and deleting a stopped
  session are all recoverable or trivial, and this one is not. `herdr session stop` asks over herdr's own socket, so a server too
  wedged to read that socket never hears the request and the button looks
  broken at exactly the moment you needed it. This signals the process instead:
  TERM first, and KILL a second later if that was not enough. The shared
  session is killed like any other, because it wedges like any other.
- **The bin** (or `x`) throws away a session that is already stopped - the
  directory and the state herdr kept in it - which is what clears it out of the
  list for good. It takes the same slot as the skull, because a session is
  never both running and stopped. The shared session is herdr's own and is
  never deleted from here.
- **`r`** refreshes, and so does a middle click on the bar button.

A row marked **stopped** is a session whose server is not running. The session
itself still exists on disk, under `~/.config/herdr/sessions/<name>/`, which is
why it stays in the list: clicking it starts that server back up, and the bin
throws the session away for good. There is nothing to kill there, so the skull
gives way to the bin.

What survives the server is the layout - herdr keeps it in `session.json` - so
a stopped row still names the workspaces it was holding and the directories
they were opened in, the same names a running session shows. That is the
difference between a session worth starting back up and a name left over from
an afternoon, and it is not something the word "stopped" can tell you. A row
that saved nothing worth naming says **nothing saved**.

The list refreshes every three seconds while the panel is open and every twenty
seconds when it is closed.

## Screenshots

It follows the theme, so it reads the same on a light one:

![The same panel on a light theme, with every status colour still legible](assets/screenshot-light.png)

The data script has a demo mode, so a screenshot never carries real project
names or agent titles and looks the same in a year:

```bash
bin/herdr-sessions demo on
# ... take the screenshot ...
bin/herdr-sessions demo off
```

Every write is a no-op while it is on, so a click during a shoot cannot kill a
real server.

## Installing it

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-herdr
omarchy plugin enable jankeesvw.herdr
omarchy bar move jankeesvw.herdr --section right
```

Needs `herdr`, `jq` and `hyprctl` on `$PATH`. The last one is what pairs a
session with the window showing it; without Hyprland the list still works, but
every session looks like it has no window and a click opens a new one. `ss`
(from iproute2) is what the skull button uses to find the process behind a
session's socket, and a window is opened in `foot`, falling back to
`xdg-terminal-exec`.

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
