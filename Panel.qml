import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Herdr: how many herdr servers are running, and a way into each of them.
//
// Herdr keeps one server per named session. They are easy to start and never
// stop by themselves - closing a window detaches, it does not end the session
// - so they pile up unseen. The bar shows the count; the panel names them,
// says which project and how many agents each one holds, and opens or kills
// one on a click.
//
// A session shows at most one window, because two windows on one session
// mirror each other. So "open" means: focus the window already showing this
// session, wherever it is, and only start a new one when there is none.
// `bin/herdr-sessions` does that matching by reading the herdr client's own
// command line off the processes behind each Hyprland window.
//
// The agent lines under a session are click targets of their own, one step
// further in: the pane is focused inside the server before the window is
// brought up, so a click lands on the piece of work you were reading rather
// than on wherever that session happened to be left.
//
// Project names are directory names and session names are whatever was passed
// to `herdr --session`, so every Text carries `textFormat: Text.PlainText`.
// Left on the default AutoText, Qt decides for itself that a string looks
// like markup and renders it as rich text - and rich text really does load
// `<img src="http://...">`, a request out of the shell process to a server
// someone else picked.
//
// The panel can also be pinned, which takes the same card out of the bar and
// leaves it on screen as a window you drag where you want it. A dropdown is
// something you open to answer a question and close again; a herd you are
// running is something you glance at all afternoon, and a panel that shuts
// the moment you touch anything else cannot be glanced at.
//
// Glyphs are \u escapes rather than literal characters, so the source
// survives editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.herdr"
  ipcTarget: "jankeesvw.herdr"

  // The script sits next to this file, so the plugin runs from wherever it
  // was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/herdr-sessions").toString().replace(/^file:\/\//, "")

  readonly property string iconServer: "\uF233"
  readonly property string iconDot: "\uF111"
  readonly property string iconOpen: "\uF2D2"
  readonly property string iconTrash: "\uF1F8"
  // nf-md-skull, U+F068C. Written as its surrogate pair because a `\u`
  // escape takes exactly four hex digits, and this codepoint is past the
  // point where four is enough - `"\uF068C"` is a different glyph followed
  // by the letter C.
  readonly property string iconKill: "\uDB81\uDE8C"
  // nf-fa-thumb_tack, U+F08D.
  readonly property string iconPin: "\uF08D"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Omarchy themes carry a foreground, an accent and an urgent, and no green.
  // "Finished" is green everywhere there is a build, a test or a task list, and
  // borrowing the accent for it would leave a finished agent looking exactly
  // like a working one - which is the distinction this widget exists to draw.
  // So this one colour is picked rather than themed.
  readonly property color finished: "#5FA46B"
  // Working is amber for the same reason, and because it used to borrow the
  // accent: on a theme whose accent is red or green, "busy" was indistinguish-
  // able from "needs you" or "finished" - the two the badge exists to separate.
  readonly property color working: "#D6A84B"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var sessions: []
  // The enabled SSH machines from `herdr machine list` and whether each one
  // answered the last poll. Sessions carry their machine as machineId; this
  // list is what knows a machine exists when it is down and has no rows.
  property var machines: []
  property int runningCount: 0
  property int agentCount: 0
  property int blockedCount: 0
  property int doneCount: 0
  property int workingCount: 0
  // The three states that turn into each other without you touching anything.
  // They decide the badge's colour, and they decide how often it is worth
  // asking - an idle herd cannot change until you change it.
  readonly property bool badgeActive:
    blockedCount > 0 || doneCount > 0 || workingCount > 0
  property bool reachable: true
  property string errorText: ""
  // Session the script is currently acting on, so its row can dim. Keyed by
  // machine as well as name: two machines can both have a "default".
  property string pendingKey: ""
  // The session the kill dialog is asking about, held while it is open.
  property var killTarget: null
  property bool confirmOpen: false

  // Where the card is: in the bar as a dropdown, or loose on screen as a
  // window of its own. Not a property this widget sets, but one it reads back
  // out of its own settings, so a pinned panel is still pinned after a shell
  // restart and lands where you left it.
  //
  // Every screen carries its own bar and therefore its own copy of this
  // widget, and a pin is a thing in one place, not the same thing repeated on
  // every monitor. So the setting names the output it was pinned on and the
  // copies on the other screens read it as "not me".
  readonly property var barScreen:
    button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property string screenName: barScreen ? barScreen.name : ""
  readonly property bool pinned: setting("pinned", false) === true
    && setting("pinScreen", "") === screenName && screenName !== ""
  readonly property real pinX: Number(setting("pinX", -1))
  readonly property real pinY: Number(setting("pinY", -1))
  // Zero means "not chosen": the width falls back to a default and the height
  // follows whatever is in the herd. Once you have dragged the corner, both
  // are yours and stay that way, which is the point of resizing a panel that
  // is going to sit there all day: it stops changing shape under you every
  // time an agent finishes.
  readonly property real pinW: Number(setting("pinW", 0))
  readonly property real pinH: Number(setting("pinH", 0))

  // Whichever card is on screen, so the cursor scrolls the list it is walking
  // and the kill dialog takes focus in the surface it was opened from. Only
  // one of the two is ever shown, which is what makes picking by `pinned`
  // rather than by asking them enough.
  //
  // Not called `card`, however much it wants to be: the pinned window names
  // its own surface that, and an id beats a property of the same name in every
  // expression in this file. The three calls below would then land on a
  // Rectangle, throw, and be swallowed by the try around the poll, so the
  // panel would report the herd as unreadable while drawing it perfectly.
  readonly property var activeCard: pinned ? pinCard : dropCard

  // Which agent spoke last, as "<session>\u0000<pane>", and every agent that
  // was already asking when we last looked.
  //
  // Herdr plays a sound when an agent starts wanting something, and that
  // sound says only that it happened, not which of them it was. This is the
  // panel's answer to that: whoever turned blocked or done since the previous
  // refresh gets a dot that blinks, so the noise you just heard has a face.
  //
  // Worked out by comparing polls rather than by trusting a number in the
  // payload, because herdr's state_change_seq is documented as a sort field
  // and not as a clock, so whether it counts per server or per agent is not
  // something to build on. It is only used to break a tie when two agents
  // start asking within the same poll.
  property string attentionKey: ""
  property var wantingBefore: ({})
  // The first poll has nothing to compare against, so every agent that is
  // already waiting would look like it just spoke. That first answer only
  // sets the baseline: after a shell restart nothing blinks until something
  // actually changes, which is the honest thing for a signal that means
  // "this just happened".
  property bool attentionPrimed: false
  // Whether the cursor has been put on the best row for this opening of the
  // panel. Without it every refresh would drag the cursor back there, three
  // seconds after you moved it.
  property bool cursorPlaced: false

  // Where the cursor is across the row: 0 is the row itself, 1 the open
  // button, 2 the destructive one. Right and Tab walk out to the buttons,
  // Left walks back. Kept as a number rather than a per-row object so moving
  // up and down holds its place in the row: walking a column of kill buttons
  // is a thing you do on purpose.
  readonly property int columnRow: 0
  readonly property int columnOpen: 1
  readonly property int columnDestroy: 2
  property int column: 0
  property int cursor: -1

  // How wide a card is before anybody resizes one. The list inside is two
  // short columns and a title that elides, so the width is a choice about how
  // much of a terminal title you want to read rather than something the
  // content asks for, and a narrower card sits better next to the work it is
  // describing.
  readonly property int cardWidth: Style.space(300)
  readonly property int cardMinWidth: Style.space(210)
  readonly property int cardMinHeight: Style.space(120)

  // The glyph, plus the few pixels the badge overhangs its corner by. Without
  // them the disc spills onto whatever widget sits next in the bar.
  readonly property int barContentWidth: Style.bar.iconFont + Style.space(4)

  // Panel is a bare Item with no size of its own, so the bar would hand this
  // widget zero width. Set it from the computed content width, never from a
  // child that fills this item: that is a loop where nothing decides the size,
  // the content still paints, and the button quietly stops being clickable.
  readonly property int barSlot: barContentWidth + Style.space(10)

  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Names come back from herdr and go straight back out as an argument. The
  // script checks them too; this is the near end of the same fence.
  function validName(name) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(name))
  }

  // Pane ids are herdr's own opaque handles - "w1:p2" - and travel back out
  // as an argument the same way names do.
  function validPane(pane) {
    return /^[A-Za-z0-9_-]{1,32}:[A-Za-z0-9_-]{1,32}$/.test(String(pane))
  }

  // Machine ids are herdr's own opaque profile ids and travel back out as an
  // argument the same way names do, so they get the same fence.
  function validMachine(id) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(id))
  }

  // Markup stripped rather than escaped: the bar tooltip is the shell's own
  // component, so `textFormat` there is not ours to set.
  function plain(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  function refresh() {
    if (listProc.running) return
    listProc.command = [root.script, "list"]
    listProc.running = true
  }

  // A session row's identity across machines: a name alone stops being an
  // address the moment two machines both have a "default".
  function rowKey(session) {
    return String(session.machineId || "") + "\u0000" + String(session.name)
  }

  function pending(session) {
    return session && pendingKey !== "" && pendingKey === rowKey(session)
  }

  // Every action carries the session's machine with it. What travels is the
  // machine id, not the ssh target - the script resolves the id back against
  // `herdr machine list`, so the target is what herdr says it is right now,
  // not what a stale payload claimed. Kill and delete stay local by policy:
  // the script refuses them for remote sessions too.
  function run(action, session, extra) {
    if (!session || !validName(session.name) || actionProc.running) return
    var remote = session.remote === true
    if (remote && !validMachine(session.machineId)) return
    pendingKey = rowKey(session)
    var command = [root.script, action, session.name]
    if (extra !== undefined && extra !== "") command.push(extra)
    if (remote) command.push(session.machineId)
    actionProc.command = command
    actionProc.running = true
  }

  // A dropdown is in the way of the window you just asked for, so acting from
  // one closes it. A pinned panel is not in the way of anything: you put it
  // where you wanted it, and a panel that vanishes every time you use it is a
  // panel you have to summon again to use twice.
  function dismiss() {
    if (!pinned) close()
  }

  // Focus the window this session is already showing, or open one.
  function openSession(session) {
    if (!session || !validName(session.name)) return
    run("open", session)
    dismiss()
  }

  // One step further in than openSession: the agent's own pane is focused
  // inside the server before the window comes up, so the click lands on the
  // work you were reading rather than on wherever that session was left.
  //
  // Focusing is also what marks a finished agent as seen - herdr turns `done`
  // back into `idle` the moment its pane is targeted - so clicking the line
  // that says "done" is what clears it.
  //
  // A pane herdr has not named yet falls back to opening the session, which
  // is what the click would have done anyway.
  function focusAgent(session, agent) {
    if (!session || !agent) return
    if (!validPane(agent.pane)) { openSession(session); return }
    if (!validName(session.name)) return
    run("focus", session, agent.pane)
    dismiss()
  }

  // Deleting throws away a session that is already stopped - its directory and
  // the state herdr kept in it - which is what clears it out of the list for
  // good. A running server is killed rather than deleted; the two never apply
  // to the same row. The shared session is herdr's own and is not deleted from
  // here at all.
  function removeSession(session) {
    if (!session || session.isDefault || session.running) return
    // Deleting a directory on another machine from a bar widget is a way to
    // lose work you cannot see; remote rows are opened and focused, never
    // ended from here.
    if (session.remote === true) return
    run("delete", session)
  }

  // How a running server is ended here, and the only way: `herdr session stop`
  // asks over herdr's own socket, so a server too wedged to read that socket
  // never hears the request, and the button that sent it looked broken at
  // exactly the moment you needed it. Signalling the process works either way,
  // so there is no reason to keep both.
  //
  // The shared session is killed like any other. It wedges like any other.
  function killSession(session) {
    if (!session || !session.running || !validName(session.name)) return
    if (session.remote === true) return
    run("kill", session)
  }

  // Killing is the one thing here that cannot be taken back: the server is
  // gone and so is everything that was running inside it, without anything
  // being asked to finish first. Opening a session, focusing an agent and even
  // deleting a stopped session are all recoverable or trivial by comparison,
  // so this is the only action that stops to ask.
  //
  // The dialog opens on Cancel rather than on the confirming side, which is
  // ConfirmDialog's own default: a dialog that destroys something on a
  // reflexive Enter is worse than no dialog, because it trains the reflex.
  function askKill(session) {
    if (!session || !session.running || !validName(session.name)) return
    if (session.remote === true) return
    killTarget = session
    confirmOpen = true
    if (activeCard) activeCard.beginConfirm()
  }

  function closeKill() {
    confirmOpen = false
    killTarget = null
    if (activeCard) activeCard.endConfirm()
  }

  function confirmKill() {
    var session = killTarget
    closeKill()
    killSession(session)
  }

  function killMessage() {
    if (!killTarget) return ""
    return "Kill the server for " + sessionLabel(killTarget)
      + "? Nothing running inside it is asked to stop first."
  }

  // Pinning and unpinning are the same click, and neither of them opens or
  // closes anything: `opened` is what the bar button has always meant, and it
  // goes on meaning it. All the pin changes is which surface that state is
  // drawn in. So pinning an open dropdown leaves an open panel, and unpinning
  // a pinned one leaves the dropdown open where the bar button would have put
  // it, which is what makes the two feel like one panel in two places rather
  // than two panels.
  //
  // Pinning never moves the card. Wherever you dragged it to last time is
  // where it comes back, because that spot was a decision you made about your
  // own desktop and re-deciding it on every pin is the panel forgetting
  // something you told it. The position outlives the unpin for exactly that
  // reason: unpinning is putting it away, not throwing it out.
  function togglePin() {
    persistSettings(pinned ? { pinned: false }
                           : { pinned: true, pinScreen: screenName })
  }

  function rememberPin(x, y) {
    if (!pinned) return
    if (Math.round(x) === Math.round(pinX) && Math.round(y) === Math.round(pinY)) return
    persistSettings({ pinX: Math.round(x), pinY: Math.round(y) })
  }

  function rememberPinSize(w, h) {
    if (!pinned) return
    if (Math.round(w) === Math.round(pinW) && Math.round(h) === Math.round(pinH)) return
    persistSettings({ pinW: Math.round(w), pinH: Math.round(h) })
  }

  // Written into this widget's own entry in shell.json, the same entry the
  // bar's settings screen reads, so the two can never disagree and there is no
  // config file of our own to keep. Applied locally first, so the panel
  // redraws on the click rather than on the write coming back.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A pinned panel that came back from a restart is a panel that should be on
  // screen, so the state the bar button drives is set to match what the
  // settings say. Unpinning deliberately leaves it alone: the card goes back
  // to being a dropdown, still open, under the button it came from.
  onPinnedChanged: if (pinned && !opened) open()

  // What the arrow keys walk: the agents, in the order they are drawn, not the
  // servers holding them. A server is a place, an agent is the work, and the
  // work is what you came to reach.
  //
  // A session with no agents still gets a row of its own, or a stopped session
  // and an empty server would drop out of the keyboard entirely and there
  // would be no way to open or delete one without the mouse.
  readonly property var navRows: {
    var rows = []
    for (var i = 0; i < sessions.length; i++) {
      var agents = sessions[i].agentList || []
      if (agents.length === 0) {
        rows.push({ sessionIndex: i, agentIndex: -1 })
        continue
      }
      for (var j = 0; j < agents.length; j++)
        rows.push({ sessionIndex: i, agentIndex: j })
    }
    return rows
  }

  function rowAt(index) {
    if (index < 0 || index >= navRows.length) return null
    return navRows[index]
  }

  function sessionAt(index) {
    var row = rowAt(index)
    return row ? sessions[row.sessionIndex] : null
  }

  function agentAt(index) {
    var row = rowAt(index)
    if (!row || row.agentIndex < 0) return null
    return (sessions[row.sessionIndex].agentList || [])[row.agentIndex] || null
  }

  // How loudly an agent is asking, lowest number first, matching the order the
  // script already sorts them in. Used to pick where the cursor starts.
  function attentionRank(status) {
    if (status === "blocked") return 0
    if (status === "done") return 1
    if (status === "working") return 2
    if (status === "idle") return 3
    return 4
  }

  // Opening the panel puts the cursor on the agent that wants the most, not on
  // the first row: the reason you opened it is almost never the top of the
  // list. Ties go to whoever is drawn first, which is herdr's own order.
  function bestRow() {
    var best = -1
    var bestRank = 99
    for (var i = 0; i < navRows.length; i++) {
      var agent = agentAt(i)
      if (!agent) continue
      var rank = attentionRank(agent.status)
      if (rank < bestRank) { bestRank = rank; best = i }
    }
    return best >= 0 ? best : (navRows.length > 0 ? 0 : -1)
  }

  // The destructive button is not on every row: a stopped shared session has
  // nothing to kill and nothing that may be deleted, so its slot is empty and
  // the cursor must step over it rather than park on a dead control.
  function lastColumnFor(session) {
    if (!session) return root.columnRow
    if (session.running) return root.columnDestroy
    return session.isDefault ? root.columnOpen : root.columnDestroy
  }

  function clampColumn() {
    var last = lastColumnFor(sessionAt(cursor))
    if (column > last) column = last
    if (column < root.columnRow) column = root.columnRow
  }

  function moveColumn(delta) {
    if (navRows.length === 0) return
    if (cursor < 0) cursor = bestRow()
    column += delta
    clampColumn()
  }

  // Tab is the same walk with a wrap, so one key cycles a row without having
  // to know how many buttons it has.
  function cycleColumn(direction) {
    if (navRows.length === 0) return
    if (cursor < 0) { cursor = bestRow(); column = root.columnRow; return }
    var last = lastColumnFor(sessionAt(cursor))
    column += direction
    if (column > last) column = root.columnRow
    if (column < root.columnRow) column = last
  }

  function moveCursor(delta) {
    if (navRows.length === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : navRows.length - 1) : cursor + delta
    if (next < 0) next = 0
    if (next > navRows.length - 1) next = navRows.length - 1
    cursor = next
    clampColumn()
    var row = rowAt(next)
    if (row) showRow(row.sessionIndex)
  }

  function showRow(sessionIndex) {
    if (activeCard) activeCard.showRow(sessionIndex)
  }

  // Enter goes as deep as the cursor is: onto the agent when it is on one, and
  // onto the session when the row is a session with nothing in it.
  function activateCursor() {
    var session = sessionAt(cursor)
    if (!session) return
    if (column === root.columnOpen) { openSession(session); return }
    if (column === root.columnDestroy) {
      if (session.running) askKill(session)
      else removeSession(session)
      return
    }
    var agent = agentAt(cursor)
    if (agent) focusAgent(session, agent)
    else openSession(session)
  }

  // True when the cursor is on the row itself rather than out on a button,
  // which is what the agent lines light up on.
  function cursorInBody() {
    return column === root.columnRow
  }

  // Which nav row a given agent is, so a delegate can tell whether the cursor
  // is on it without knowing anything about the flattening above.
  function cursorOnAgent(sessionIndex, agentIndex) {
    var row = rowAt(cursor)
    return row !== null && row.sessionIndex === sessionIndex
      && row.agentIndex === agentIndex
  }

  // The mouse moves the same cursor the keys do, so leaving the mouse and
  // reaching for the arrows carries on from where you were pointing.
  function cursorToAgent(sessionIndex, agentIndex) {
    column = root.columnRow
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].sessionIndex === sessionIndex && navRows[i].agentIndex === agentIndex) {
        cursor = i
        return
      }
  }

  function cursorToSession(sessionIndex) {
    column = root.columnRow
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].sessionIndex === sessionIndex) {
        cursor = i
        return
      }
  }

  function cursorOnSession(sessionIndex) {
    var row = rowAt(cursor)
    return row !== null && row.sessionIndex === sessionIndex
  }

  // "default" is herdr's own name for the shared session, and it reads as a
  // setting rather than a place. A numbered one is a Hyprland workspace,
  // which is worth saying out loud.
  function sessionLabel(session) {
    if (!session) return ""
    if (session.isDefault) return "Shared session"
    if (/^[0-9]+$/.test(session.name)) return "Workspace " + session.name
    return session.name
  }

  // The machine a session runs on, for the dim prefix in front of its name.
  // Local sessions get none: the panel is about this machine by default, and
  // a label that says so on every row is noise. Herdr itself shows its
  // `machine` token only once more than one machine is present, and a remote
  // row is exactly when there is something to distinguish.
  function machineName(session) {
    if (!session || session.remote !== true) return ""
    return session.machineLabel || session.sshTarget || ""
  }

  // The machines that did not answer the last poll, as one line. A machine
  // that is down has no rows of its own, so without this it would vanish
  // silently - the worst shape for the machine your agents are on.
  function unreachableText() {
    var names = []
    for (var i = 0; i < machines.length; i++) {
      var m = machines[i]
      if (m.ok === true) continue
      var label = m.label || m.target || m.id
      if (m.error && m.error !== "" && m.error !== "unreachable")
        label += " (" + m.error + ")"
      names.push(label)
    }
    if (names.length === 0) return ""
    return "unreachable: " + names.join(", ")
  }

  // A stopped session names what it is holding rather than only saying it is
  // down: herdr keeps the layout in session.json, so the workspaces and the
  // directories they were opened in survive the server. That is the difference
  // between a session worth starting back up and a name left over from an
  // afternoon, and it is not visible from the word "stopped".
  // Only where the agent lines are not already saying it. A running session
  // with agents in it now names its workspaces one per agent, next to the work
  // going on there, so repeating the merged list above them is the same words
  // twice with less meaning.
  function subtitleFor(session) {
    if (!session) return ""
    if (session.running && (session.agentList || []).length > 0) return ""
    var projects = session.projects || []
    if (projects.length > 0) return projects.join("  ·  ")
    return session.running ? "no workspaces yet" : "nothing saved"
  }

  // "stopped" belongs in the right-hand column with the agent counts and the
  // agent states, not in the subtitle: that column is where the panel says
  // what something is doing, and a stopped server is doing nothing.
  function countLabel(session) {
    if (!session) return ""
    if (!session.running) return "stopped"
    var n = session.agents || 0
    if (n === 0) return "no agents"
    return n === 1 ? "1 agent" : n + " agents"
  }

  // The one word worth colouring: blocked means an agent is waiting on you,
  // working means it is busy. Anything else is quiet and says nothing.
  // Waiting beats finished beats busy, everywhere a state has to be reduced
  // to one thing: a question on screen outranks work that has already ended,
  // and both outrank an agent that is simply busy.
  function noteLabel(session) {
    if (!session || !session.running) return ""
    if ((session.blocked || 0) > 0) return session.blocked + " needs you"
    if ((session.done || 0) > 0) return session.done + " done"
    if ((session.working || 0) > 0) return session.working + " working"
    return ""
  }

  // Herdr puts a spinner glyph in front of a title while its agent is working,
  // so the same task moves left and right as it ticks over. Dropping any run
  // of leading symbols keeps the titles in one column; the status dot beside
  // them says the same thing without moving.
  function cleanTitle(title) {
    var s = String(title || "").trim()
    var stripped = s.replace(/^[^0-9A-Za-z\u00C0-\u024F]+/, "").trim()
    return stripped !== "" ? stripped : s
  }

  // Every agent, however many there are and wherever herdr keeps them: a pane
  // in a second tab counts the same as one sitting in front of you, and an
  // agent summarised as "+1 more" is exactly the one you would have wanted to
  // read. The list scrolls when it has to; that is what the card's height cap
  // is for.
  function agentsOf(session) {
    if (!session) return []
    return session.agentList || []
  }

  function agentColor(status) {
    if (status === "blocked") return root.urgent
    if (status === "done") return root.finished
    if (status === "working") return root.accent
    return Qt.darker(root.foreground, 1.9)
  }

  // Every agent says what it is doing, in herdr's own terms: `blocked` is an
  // approval or a question on screen, `done` is work that finished while you
  // were looking elsewhere, `idle` is a prompt waiting for you to type - which
  // reads better as "ready", because "idle" sounds like a problem and it is
  // the ordinary resting state.
  //
  // These run down the right edge in one column, so the question is not "which
  // line has a label" but "what does that column say" - one glance instead of
  // a scan. Two of them are still news and two are not, and that is carried by
  // weight and colour rather than by leaving a word out: the ones that want
  // something are bold and coloured, the rest are quiet grey.
  function agentNote(status) {
    if (status === "blocked") return "needs you"
    if (status === "done") return "done"
    if (status === "working") return "working"
    if (status === "idle") return "ready"
    return "unknown"
  }

  function agentWants(status) {
    return status === "blocked" || status === "done"
  }

  function noteColor(session) {
    if (!session) return root.foreground
    if ((session.blocked || 0) > 0) return root.urgent
    if ((session.done || 0) > 0) return root.finished
    return root.accent
  }

  function statusColor(session) {
    if (!session || !session.running) return Qt.darker(root.foreground, 2.2)
    if ((session.blocked || 0) > 0) return root.urgent
    if ((session.done || 0) > 0) return root.finished
    if ((session.working || 0) > 0) return root.accent
    return Qt.darker(root.foreground, 1.7)
  }

  function badgeColor() {
    if (blockedCount > 0) return root.urgent
    if (doneCount > 0) return root.finished
    return root.working
  }

  function titleText() {
    var s = runningCount === 1 ? " server" : " servers"
    var a = agentCount === 1 ? " agent" : " agents"
    return "Herdr (" + runningCount + s + ", " + agentCount + a + ")"
  }

  // The bar shows a bare number, which says nothing about what it counts. The
  // tooltip is where that gets spelled out, and where a herd that wants
  // something says so before the panel is even open.
  function tooltipText() {
    var parts = [runningCount + (runningCount === 1 ? " herdr server" : " herdr servers"),
                 agentCount + (agentCount === 1 ? " agent" : " agents")]
    if (blockedCount > 0) parts.push(blockedCount + " waiting on you")
    if (doneCount > 0) parts.push(doneCount + " finished")
    return parts.join(", ")
  }

  // Pane ids are scoped to one server, so the machine is part of the key:
  // two machines can both have a "default" session holding a "w1:p1".
  function agentKey(session, pane) {
    return String(session.machineId || "") + "\u0000"
      + String(session.name) + "\u0000" + String(pane)
  }

  // Everything that is asking for something right now, and which of those is
  // new since the previous poll. A tie inside one poll goes to the highest
  // state_change_seq, which is the best herdr can tell us; a tie there too
  // goes to nobody, because a dot that blinks on the wrong agent is worse
  // than one that does not blink at all.
  function updateAttention(sessionList) {
    var wantingNow = {}
    var freshest = null
    for (var i = 0; i < sessionList.length; i++) {
      var session = sessionList[i]
      var agents = session.agentList || []
      for (var j = 0; j < agents.length; j++) {
        if (!root.agentWants(agents[j].status)) continue
        var key = root.agentKey(session, agents[j].pane)
        wantingNow[key] = true
        if (root.wantingBefore[key]) continue
        if (freshest === null || (agents[j].seq || 0) > freshest.seq)
          freshest = { key: key, seq: agents[j].seq || 0 }
      }
    }

    // An agent that stopped asking stops blinking, even if nobody took its
    // place: the blink is about a question still standing, not about history.
    if (root.attentionKey !== "" && !wantingNow[root.attentionKey])
      root.attentionKey = ""
    if (freshest !== null && root.attentionPrimed) root.attentionKey = freshest.key

    root.wantingBefore = wantingNow
    root.attentionPrimed = true
  }

  function blinking(session, agent) {
    if (!session || !agent || root.attentionKey === "") return false
    return root.agentKey(session, agent.pane) === root.attentionKey
  }

  function applyPayload(text) {
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      sessions = data.sessions || []
      machines = data.machines || []
      updateAttention(sessions)
      if (opened && !cursorPlaced) {
        cursor = bestRow()
        cursorPlaced = true
        var row = rowAt(cursor)
        if (row) showRow(row.sessionIndex)
      }
      runningCount = data.running || 0
      agentCount = data.agents || 0
      blockedCount = data.blocked || 0
      doneCount = data.done || 0
      workingCount = data.working || 0
      if (cursor > navRows.length - 1) cursor = navRows.length - 1
    } catch (e) {
      reachable = false
      errorText = "unexpected output from herdr-sessions"
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      // The list may still be the one from the last poll, so place the cursor
      // on what we know now and again when the fresh answer lands.
      cursor = bestRow()
      column = root.columnRow
      cursorPlaced = false
    } else {
      cursor = -1
      column = root.columnRow
      cursorPlaced = false
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      root.pendingKey = ""
      // A stopped server disappears from the list, and a freshly opened
      // window takes a moment to register its agents. One beat, then look
      // again.
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.refresh()
  }

  // Polled rather than subscribed: herdr has an event socket, but one per
  // server, and the count in the bar is the sort of thing that can be a few
  // seconds old. Faster while the panel is open, because the agent states in
  // it are what you came to read, and faster while anything is live, because
  // that is the only time the badge colour can go stale on its own. Idle costs
  // one poll every twenty seconds and catches the moment you start something.
  Timer {
    interval: root.opened ? 3000 : (root.badgeActive ? 5000 : 20000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: root.reachable ? 1 : 0.5
    slotSize: root.barSlot
    opticalSize: root.barContentWidth
    tooltipText: root.plain(root.tooltipText())

    iconComponent: Component {
      Item {
        Text {
          id: serverIcon
          anchors.centerIn: parent
          text: root.iconServer
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          // barForeground, not the theme's foreground: on a transparent bar
          // the shell picks the glyph colour off what is behind it, so the
          // icon turns dark over a light wallpaper the way every other bar
          // icon does. The theme foreground is only right where the panel
          // paints its own background.
          //
          // Nothing here reacts to the panel being open: the bar draws that
          // itself, as an accent line on the module's inner edge, for every
          // widget that has a panel. Tinting the glyph as well says the same
          // thing twice, in the one colour that means something else.
          color: root.barForeground
        }

        // The server count rides the glyph's top-right corner, the way an
        // unread count rides an app icon, and is sized off the icon font so a
        // theme that resizes the bar takes it along. The ratios are what the
        // default 13px icon can carry: a 12px disc around a 9px digit. Three
        // quarters of the glyph leaves the digit on 6px, which is a coloured
        // speck rather than a count - unreadable at two digits - and the badge
        // exists to say how many as much as it says which colour.
        Rectangle {
          id: badge
          anchors.horizontalCenter: serverIcon.horizontalCenter
          anchors.horizontalCenterOffset: Math.round(Style.bar.iconFont * 0.42)
          anchors.verticalCenter: serverIcon.verticalCenter
          anchors.verticalCenterOffset: -Math.round(Style.bar.iconFont * 0.40)
          visible: root.reachable && root.runningCount > 0 && root.badgeActive
          height: Math.round(Style.bar.iconFont * 0.95)
          width: Math.max(height, count.implicitWidth + Math.round(height * 0.45))
          radius: height / 2
          color: root.badgeColor()
          // A rim in the bar's own background separates the badge from the
          // glyph it sits on, so the corner it covers still reads as a corner
          // and not as two shapes fused together.
          border.width: Math.round(Style.bar.iconFont * 0.06)
          border.color: Color.bar.background

          Text {
            id: count
            anchors.centerIn: parent
            // Centring the text item leaves the digit riding high: a line box
            // reserves descender room a digit never uses. Nudge it back down
            // onto the middle of the disc.
            anchors.verticalCenterOffset: Math.round(font.pixelSize * 0.1)
            text: root.runningCount
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Math.round((badge.height - 2 * badge.border.width) * 0.88)
            font.bold: true
            renderType: Text.NativeRendering
            color: Color.background
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }


  // ------------------------------------------------------------- dropdown
  //
  // The card in the bar, under the button, open for as long as you are
  // looking at it. Nothing here is different from before the pin existed
  // except that it stays shut while the pinned window has the card: two
  // copies of the same panel on screen at once is not a second view, it is
  // the same view twice, and the cursor would be walking both.

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && !root.pinned
    focusTarget: dropCard
    contentWidth: panel.fittedContentWidth(root.cardWidth)
    contentHeight: panel.fittedContentHeight(dropCard.bodyHeight)

    Card {
      id: dropCard
      anchors.fill: parent
      panel: root
      maxHeight: panel.availableCardHeight - panel.verticalContentInset
    }
  }

  // --------------------------------------------------------- pinned window
  //
  // The same card, loose on the desktop. A layer-shell surface rather than a
  // real window, because that is what a shell plugin has to work with, and it
  // buys something a real window would not: it is on every workspace at once.
  // A herd you are running does not belong to the workspace you happened to
  // start it from, and a panel you have to switch away to see is a panel you
  // stop looking at.
  //
  // The surface covers the screen and the card is placed inside it, the way
  // the dropdown does it. That is what makes dragging smooth: the card moves
  // within a surface that never moves, so the compositor is never asked to
  // reposition a window sixty times a second. `mask` then hands every pixel
  // that is not the card back to whatever is underneath, so the invisible
  // rest of this surface does not quietly eat a click on your editor.

  PanelWindow {
    id: pinWindow

    screen: root.barScreen
    visible: root.pinned && root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-herdr-pin"
    WlrLayershell.layer: WlrLayer.Overlay

    // Keyboard focus arrives on a click and not a moment earlier. Hyprland
    // hands focus to an OnDemand surface when it first maps, which is right
    // when you just pressed the pin and wrong every other time: a shell
    // restart would take the keyboard out of whatever you were typing in and
    // give it to a panel nobody asked for. So the surface maps as None and
    // becomes OnDemand once it is up, which leaves click-to-focus working and
    // map-to-focus not happening.
    WlrLayershell.keyboardFocus: pinWindow.focusArmed
      ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    property bool focusArmed: false

    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: card }

    readonly property int edge: Style.gapsOut * 2
    // A dropdown is on screen for the seconds it is being used, so it wears
    // the accent border the whole time and that is honest. A pinned card is on
    // screen all day, and a card that says "focused" all day is saying nothing
    // at all, in the loudest colour the theme has. So it follows the keyboard
    // the way every real window on this desktop does: lit when it has it, a
    // quiet line when it does not.
    readonly property real borderWidth: Math.max(1, Style.space(2))
    readonly property bool active: pinCard.activeFocus
    readonly property var borderSpec: active
      ? Border.surfaceSpec("popups", "border", Color.popups.border, borderWidth)
      : Border.flat(Qt.rgba(root.foreground.r, root.foreground.g,
                            root.foreground.b, 0.22), borderWidth)
    readonly property int padding: Style.spacing.popupPadding
    readonly property real verticalInset:
      padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

    // The size you chose, or nothing, in which case the width is the default
    // and the height is however tall the herd happens to be. Written only by
    // the corner, read back out of the settings on the way in.
    property real chosenWidth: root.pinW
    property real chosenHeight: root.pinH

    readonly property real roomWidth: Math.max(root.cardMinWidth, width - edge * 2)
    readonly property real roomHeight: Math.max(root.cardMinHeight, height - edge * 2)

    readonly property real cardWidth: Math.min(roomWidth,
      Math.max(root.cardMinWidth, chosenWidth > 0 ? chosenWidth : root.cardWidth))
    readonly property real cardHeight: Math.min(roomHeight,
      Math.max(root.cardMinHeight, chosenHeight > 0
        ? chosenHeight : pinCard.bodyHeight + verticalInset))

    // Whether this surface knows how big it is yet. A layer-shell window
    // exists before the compositor has told it anything, and through those
    // first frames it reports a hundred pixels square. Every sum below is
    // about fitting a card inside a screen, and against a screen that small
    // there is no position that fits, so all of them answer "the corner".
    //
    // That is what threw a pinned card away: unpinning unmaps the surface, its
    // size collapses, the clamp fires on the way down and overwrites the spot
    // you had dragged it to. The card came back to a corner rather than to
    // where you left it, and the setting it came back from was right all
    // along.
    //
    // The test is the card itself rather than the screen: `cardWidth` already
    // refuses to go below a minimum, so a window too small to hold the card
    // with its margins is a window that has not been told its size.
    readonly property bool sized: width >= card.width + edge * 2
      && height >= card.height + edge * 2

    // Whether the card has been put somewhere for this showing. Until it has,
    // a size change means "try again"; after it has, it means "stay inside the
    // screen", and those are not the same instruction.
    property bool placed: false

    // Keep the card inside the screen whatever changes underneath it: a
    // shorter list, a resized output, a position read back from a settings
    // file somebody edited by hand. `fit` is the only thing that ever decides
    // where the card may sit, so there is one answer rather than three.
    function fit(value, limit) {
      var n = Number(value)
      if (!isFinite(n)) n = 0
      if (!(limit > pinWindow.edge)) return Math.round(n)
      return Math.round(Math.max(pinWindow.edge, Math.min(n, limit)))
    }

    // How much of the screen the bar is already using on its own side. A
    // layer at Overlay is free to sit on top of the bar, and a panel that
    // opens there on its first day looks like a mistake.
    readonly property real barSize: {
      var w = button.QsWindow.window
      if (!w || !root.bar) return 0
      var side = root.bar.position
      return (side === "left" || side === "right") ? w.width : w.height
    }

    readonly property string barSide: root.bar ? root.bar.position : "top"

    // Bottom left, which is the corner a thing you keep an eye on goes in: out
    // of the way of the window you are working in, away from the notifications
    // that come down the other side, and not under the bar.
    readonly property point defaultOrigin: {
      var x = edge + (barSide === "left" ? barSize + Style.gapsOut : 0)
      var y = height - card.height - edge
        - (barSide === "bottom" ? barSize + Style.gapsOut : 0)
      return Qt.point(Math.round(x), Math.round(y))
    }

    function place() {
      if (!sized) return
      var known = isFinite(root.pinX) && root.pinX >= 0
                  && isFinite(root.pinY) && root.pinY >= 0
      card.x = known ? fit(root.pinX, width - card.width - edge) : defaultOrigin.x
      card.y = known ? fit(root.pinY, height - card.height - edge) : defaultOrigin.y
      placed = true
    }

    function reclamp() {
      if (!sized) return
      if (!placed) { place(); return }
      card.x = fit(card.x, width - card.width - edge)
      card.y = fit(card.y, height - card.height - edge)
    }

    onSizedChanged: if (sized && visible && !placed) place()

    // Growing runs down and right from where the card already is, so the
    // corner you are holding is the corner that moves and the other three stay
    // put. That is what stops a resize from also being a small unasked-for
    // drag.
    function resize(w, h) {
      chosenWidth = Math.max(root.cardMinWidth, Math.min(w, width - card.x - edge))
      chosenHeight = Math.max(root.cardMinHeight, Math.min(h, height - card.y - edge))
    }

    onVisibleChanged: {
      focusArmed = false
      // Every showing places the card again, from the setting rather than
      // from wherever the last one left it lying.
      placed = false
      if (visible) {
        Qt.callLater(pinWindow.place)
        armTimer.restart()
      }
    }

    Timer {
      id: armTimer
      interval: 300
      onTriggered: pinWindow.focusArmed = pinWindow.visible
    }

    Connections {
      target: root
      function onPinXChanged() { pinWindow.place() }
      function onPinYChanged() { pinWindow.place() }
      function onPinWChanged() { pinWindow.chosenWidth = root.pinW }
      function onPinHChanged() { pinWindow.chosenHeight = root.pinH }
    }

    BorderSurface {
      id: card
      width: pinWindow.cardWidth
      height: pinWindow.cardHeight
      color: Color.popups.background
      borderSpec: pinWindow.borderSpec
      padding: pinWindow.padding
      radius: Style.cornerRadius

      onHeightChanged: pinWindow.reclamp()
      onWidthChanged: pinWindow.reclamp()

      // Declared before the card's own content, so everything drawn in the
      // card sits on top of this and takes its own clicks first. What is left
      // over inside the strip is the header background around the title, and
      // that is the handle: the pin button on the right of the same row goes
      // on working because it is above this, not because this knows about it.
      //
      // Dragging moves the card inside a surface that stays put, so the drag
      // is a scene-graph translation rather than a stream of window moves, and
      // it keeps up with the pointer.
      MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: card.contentTopInset + pinCard.headerHeight
        acceptedButtons: Qt.LeftButton
        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        drag.target: card
        drag.axis: Drag.XAndYAxis
        drag.threshold: 3
        drag.minimumX: pinWindow.edge
        drag.maximumX: pinWindow.width - card.width - pinWindow.edge
        drag.minimumY: pinWindow.edge
        drag.maximumY: pinWindow.height - card.height - pinWindow.edge
        onReleased: root.rememberPin(card.x, card.y)
      }

      Card {
        id: pinCard
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        panel: root
        // A height you chose is a height the list has to live inside, so the
        // panel keeps the shape you gave it and scrolls instead of growing.
        // Until then the screen is the only limit.
        maxHeight: pinWindow.chosenHeight > 0
          ? pinWindow.chosenHeight - pinWindow.verticalInset
          : pinWindow.roomHeight - pinWindow.verticalInset
      }

      // Last child, above everything, in the corner the card's own padding
      // leaves empty. Six dots stepped down the diagonal, which is the corner
      // every resizable window has had for thirty years.
      //
      // Scene coordinates on both ends of the sum, never the pointer's
      // position inside this item: this item is anchored to the corner it is
      // dragging, so it moves out from under the cursor as the card grows and
      // a local delta would chase itself.
      MouseArea {
        id: resizer
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // The hit area keeps the whole corner, which is what makes it easy to
        // grab. The dots sit further in, clear of the border: a mark that
        // touches the edge reads as part of the edge.
        width: Style.space(24)
        height: Style.space(24)
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.SizeFDiagCursor

        property real startWidth: 0
        property real startHeight: 0
        property point startPoint: Qt.point(0, 0)

        function scenePoint(mouse) {
          return mapToItem(null, mouse.x, mouse.y)
        }

        onPressed: function(mouse) {
          startWidth = card.width
          startHeight = card.height
          startPoint = scenePoint(mouse)
        }

        onPositionChanged: function(mouse) {
          if (!pressed) return
          var now = scenePoint(mouse)
          pinWindow.resize(startWidth + (now.x - startPoint.x),
                           startHeight + (now.y - startPoint.y))
        }

        onReleased: root.rememberPinSize(card.width, card.height)

        Column {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          // Clear of the rounded corner, not tucked against it: the border
          // curves away here, so a mark set tight to the edge ends up reading
          // as part of the border rather than as something you can grab.
          anchors.rightMargin: Style.space(9)
          anchors.bottomMargin: Style.space(9)
          spacing: Math.max(2, Style.space(3))

          Repeater {
            model: 3

            Row {
              id: dotRow
              required property int index
              anchors.right: parent.right
              spacing: Math.max(2, Style.space(3))

              Repeater {
                model: dotRow.index + 1

                Rectangle {
                  width: Math.max(2, Style.space(3))
                  height: width
                  radius: width / 2
                  color: Qt.darker(root.foreground, 2.2)
                }
              }
            }
          }
        }
      }
    }
  }
}
