import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Omarchy themes carry a foreground, an accent and an urgent, and no green.
  // "Finished" is green everywhere there is a build, a test or a task list, and
  // borrowing the accent for it would leave a finished agent looking exactly
  // like a working one - which is the distinction this widget exists to draw.
  // So this one colour is picked rather than themed.
  readonly property color finished: "#5FA46B"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var sessions: []
  property int runningCount: 0
  property int agentCount: 0
  property int blockedCount: 0
  property int doneCount: 0
  property int workingCount: 0
  property bool reachable: true
  property string errorText: ""
  // Session the script is currently acting on, so its row can dim.
  property string pendingName: ""
  // The session the kill dialog is asking about, held while it is open.
  property var killTarget: null
  property bool confirmOpen: false

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

  readonly property int badgeCount: runningCount

  // Width of the badge and of the whole icon+badge row. Computed here rather
  // than read off the Row, because iconComponent is a Component with its own
  // scope: ids inside it are not visible out here.
  readonly property int badgeWidth: badgeCount > 0
    ? Math.max(Style.space(12), String(badgeCount).length * Style.space(6) + Style.space(8))
    : 0
  readonly property int barContentWidth: Style.bar.iconFont + badgeWidth + Style.space(5)

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

  function run(action, name, extra) {
    if (!validName(name) || actionProc.running) return
    pendingName = name
    var command = [root.script, action, name]
    if (extra !== undefined && extra !== "") command.push(extra)
    actionProc.command = command
    actionProc.running = true
  }

  // Focus the window this session is already showing, or open one. Closing
  // the panel is part of the action: the point of the click is to end up in
  // herdr, and a panel left hanging over the window you just asked for is in
  // the way.
  function openSession(session) {
    if (!session || !validName(session.name)) return
    run("open", session.name)
    close()
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
    run("focus", session.name, agent.pane)
    close()
  }

  // Deleting throws away a session that is already stopped - its directory and
  // the state herdr kept in it - which is what clears it out of the list for
  // good. A running server is killed rather than deleted; the two never apply
  // to the same row. The shared session is herdr's own and is not deleted from
  // here at all.
  function removeSession(session) {
    if (!session || session.isDefault || session.running) return
    run("delete", session.name)
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
    run("kill", session.name)
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
    killTarget = session
    killConfirm.selectedIndex = 0
    confirmOpen = true
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  // Focus goes back to the panel by hand on the way out. The key catcher gave
  // it up when the dialog took over, and nothing hands it back on its own -
  // the panel would still be open with the arrow keys doing nothing.
  function closeKill() {
    confirmOpen = false
    killTarget = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
    if (row) list.positionViewAtIndex(row.sessionIndex, ListView.Contain)
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
    return root.accent
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

  function agentKey(sessionName, pane) {
    return String(sessionName) + "\u0000" + String(pane)
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
        var key = root.agentKey(session.name, agents[j].pane)
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

  function blinking(sessionName, agent) {
    if (!agent || root.attentionKey === "") return false
    return root.agentKey(sessionName, agent.pane) === root.attentionKey
  }

  function applyPayload(text) {
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      sessions = data.sessions || []
      updateAttention(sessions)
      if (opened && !cursorPlaced) {
        cursor = bestRow()
        cursorPlaced = true
        var row = rowAt(cursor)
        if (row) list.positionViewAtIndex(row.sessionIndex, ListView.Contain)
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
      root.pendingName = ""
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
  // it are what you came to read.
  Timer {
    interval: root.opened ? 3000 : 20000
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
    // The icon component is loaded into a square canvas of opticalSize, meant
    // for one glyph. Widen it too, or the icon falls outside it and only the
    // badge survives.
    opticalSize: root.barContentWidth
    tooltipText: root.plain(root.tooltipText())

    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconServer
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.opened ? root.accent : root.foreground
          }

          // The badge carries the alarm as well as the number: red when an
          // agent somewhere is blocked on a question, so a herd that needs
          // you says so without the panel being open.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.reachable && root.badgeCount > 0
            height: Style.space(12)
            width: root.badgeWidth
            radius: height / 2
            color: root.badgeColor()

            Text {
              anchors.centerIn: parent
              text: root.badgeCount
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
              color: Color.background
            }
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the dialog is up the panel's own keys are off, so Escape closes
      // the question rather than the whole panel, and Enter answers it rather
      // than opening whatever the cursor was on.
      blocked: root.confirmOpen
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveColumn(dx)
      }
      onTabRequested: function(direction) { root.cycleColumn(direction) }
      // Only activateRequested, never returnRequested as well: Enter fires
      // both, and a handler on each runs the action twice.
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        // The letter keys stay about the server, wherever inside it the
        // cursor happens to be: you kill a server, never an agent.
        var session = root.sessionAt(root.cursor)
        if (t === "o" && session) root.openSession(session)
        else if (t === "k" && session) root.askKill(session)
        else if (t === "x" && session) root.removeSession(session)
        else if (t === "r") root.refresh()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(6)

        // ------------------------------------------------------- header

        PanelSectionHeader {
          width: parent.width
          text: root.titleText()
          textFormat: Text.PlainText
          elide: Text.ElideRight
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        PanelSeparator { width: parent.width }

        Item {
          width: parent.width
          height: root.reachable ? 0 : staleWarning.implicitHeight + Style.space(6)
          visible: !root.reachable

          Text {
            id: staleWarning
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: root.errorText !== "" ? root.errorText : "Could not reach herdr."
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.urgent
          }
        }

        // --------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          visible: root.sessions.length > 0
          clip: true
          model: root.sessions
          spacing: Style.space(1)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // Grows with what it holds and stops at whatever the card has left
          // once the header and the footer have had their share.
          readonly property int cap: {
            var chrome = Style.space(80)
            if (!root.reachable) chrome += Style.space(24)
            return Math.max(Style.space(140),
                            panel.availableCardHeight - panel.verticalContentInset - chrome)
          }
          height: Math.min(contentHeight, cap)

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index

            // The session is lit whenever the cursor is anywhere inside it, so
            // the action buttons on the right stay reachable while you walk
            // the agents underneath.
            readonly property bool active: root.cursorOnSession(row.index) || rowMouse.containsMouse

            width: list.width - (list.interactive ? Style.space(10) : 0)
            height: rowContent.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            opacity: root.pendingName === modelData.name ? 0.4 : 1
            color: active
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent"

            Behavior on color { ColorAnimation { duration: 80 } }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.cursorToSession(row.index)
              onClicked: root.openSession(row.modelData)
            }

            Row {
              id: rowContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(7)

              // The dot is the session's own state at a glance: red when an
              // agent in there is blocked, accent while one is working, grey
              // when it is idle and fainter still when the server is down.
              Item {
                width: Style.space(14)
                height: Style.space(14)
                anchors.top: parent.top
                anchors.topMargin: Style.space(3)

                Text {
                  anchors.centerIn: parent
                  text: root.iconDot
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(7)
                  color: root.statusColor(row.modelData)
                }
              }

              Column {
                id: agentColumn
                width: parent.width - Style.space(21) - actions.width - rowContent.spacing
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: name.implicitHeight

                  Text {
                    id: name
                    anchors.left: parent.left
                    anchors.right: counts.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.sessionLabel(row.modelData)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    // The window a session is showing is the one you would
                    // switch to; a session without one still has to be opened.
                    font.bold: row.modelData.windowAddress !== ""
                    color: row.modelData.running
                      ? root.foreground
                      : Qt.darker(root.foreground, 1.6)
                  }

                  Row {
                    id: counts
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.noteLabel(row.modelData) !== ""
                      text: root.noteLabel(row.modelData)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.noteColor(row.modelData)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.countLabel(row.modelData) !== ""
                      text: root.countLabel(row.modelData)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: Qt.darker(root.foreground, 1.7)
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  height: visible ? implicitHeight : 0
                  text: root.subtitleFor(row.modelData)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: Qt.darker(root.foreground, 1.9)
                }

                // What each agent in there is actually doing. The title is
                // whatever the agent wrote to the terminal, so it is external
                // text: plain, elided, and never markup.
                Repeater {
                  model: root.agentsOf(row.modelData)

                  // A row rather than a Row: the note is right-aligned so the
                  // titles keep one left edge down the whole panel, and the
                  // title elides into whatever is left between the two.
                  //
                  // Each line is its own click target, so the panel is a way
                  // into a particular piece of work rather than into a
                  // session. A little taller than the text it holds, because
                  // three lines of caption text stacked tight is not
                  // something you can reliably hit.
                  Item {
                    id: agentRow
                    required property var modelData
                    required property int index
                    width: agentColumn.width
                    height: (agentWorkspace.visible
                             ? agentWorkspace.implicitHeight + agentTitle.implicitHeight + Style.space(1)
                             : agentTitle.implicitHeight) + Style.space(5)

                    // Three greys down the row, and that is the whole trick:
                    // the workspace is the name of the place and sits at the
                    // top, the terminal title is what happens to be running
                    // there and sits under it a shade back, and the state sits
                    // out right in its own colour. Give any two of them the
                    // same weight and the panel turns into a wall of text.
                    readonly property bool lit: agentMouse.containsMouse
                      || (root.cursorInBody() && root.cursorOnAgent(row.index, agentRow.index))
                    readonly property bool wants: root.agentWants(modelData.status)

                    // Bleeds past the text on both sides so the highlight
                    // reads as a row of the list rather than a box drawn
                    // around a sentence.
                    Rectangle {
                      anchors.fill: parent
                      anchors.leftMargin: -Style.space(4)
                      anchors.rightMargin: -Style.space(4)
                      radius: Style.cornerRadius
                      color: agentRow.lit
                        ? Qt.rgba(root.foreground.r, root.foreground.g,
                                  root.foreground.b, 0.13)
                        : "transparent"

                      Behavior on color { ColorAnimation { duration: 80 } }
                    }

                    // The dot of the agent that spoke last pulses. Opacity
                    // only, never size or colour: a dot that grows drags the
                    // line it sits on, and the colour is already carrying the
                    // state. It fades rather than flicks, because a hard
                    // on-off in the corner of your eye reads as a fault.
                    //
                    // The animation is bound to `running`, so it stops the
                    // moment that agent is answered instead of being left
                    // spinning behind a dot nobody is looking at.
                    Text {
                      id: agentDot
                      anchors.left: parent.left
                      // Sits on the first line rather than between the two, so
                      // a two-line agent still reads as one entry starting at
                      // the top instead of a bracket around a paragraph.
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(3)
                      text: root.iconDot
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.space(5)
                      color: root.agentColor(agentRow.modelData.status)

                      SequentialAnimation on opacity {
                        running: root.blinking(row.modelData.name, agentRow.modelData)
                        loops: Animation.Infinite
                        alwaysRunToEnd: true
                        NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutQuad }
                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
                        onStopped: agentDot.opacity = 1
                      }
                    }

                    // An agent that wants something is written at full
                    // strength; the rest stay dimmed, so the line worth
                    // reading is the one that stands out of the column.
                    // Which workspace inside the server this agent sits in.
                    // Herdr names them and the name is how you think about the
                    // work, but until now it only appeared merged into the
                    // session subtitle, where it said nothing about which
                    // agent was where.
                    //
                    // Dimmed and capped at a share of the row, because it is
                    // the address and the title is the thing: a long workspace
                    // name must never be what pushes the title out.
                    Text {
                      id: agentWorkspace
                      anchors.left: agentDot.right
                      anchors.leftMargin: Style.space(5)
                      anchors.right: agentNote.visible ? agentNote.left : parent.right
                      anchors.rightMargin: agentNote.visible ? Style.space(6) : 0
                      anchors.top: parent.top
                      visible: text !== ""
                      text: agentRow.modelData.workspace || ""
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: agentRow.wants || agentRow.lit
                        ? root.foreground
                        : Qt.darker(root.foreground, 1.3)
                    }

                    Text {
                      id: agentTitle
                      anchors.left: agentDot.right
                      anchors.leftMargin: Style.space(5)
                      anchors.right: agentWorkspace.visible
                        ? parent.right
                        : (agentNote.visible ? agentNote.left : parent.right)
                      anchors.rightMargin: agentWorkspace.visible
                        ? 0 : (agentNote.visible ? Style.space(6) : 0)
                      anchors.top: agentWorkspace.visible ? agentWorkspace.bottom : parent.top
                      anchors.topMargin: agentWorkspace.visible ? Style.space(1) : 0
                      text: root.cleanTitle(agentRow.modelData.title)
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      // Always a step behind the workspace above it, lit or
                      // not: what the agent called itself is the detail, the
                      // place is the heading.
                      color: agentRow.wants || agentRow.lit
                        ? Qt.darker(root.foreground, 1.5)
                        : Qt.darker(root.foreground, 2.1)
                    }

                    Text {
                      id: agentNote
                      anchors.right: parent.right
                      anchors.top: parent.top
                      visible: root.agentNote(agentRow.modelData.status) !== ""
                      text: root.agentNote(agentRow.modelData.status)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      // Only the two that are news carry weight. Bold on every
                      // line would put the column back where it started.
                      font.bold: root.agentWants(agentRow.modelData.status)
                      color: root.agentColor(agentRow.modelData.status)
                    }

                    // Last child, so it is above the labels rather than
                    // under them. It takes the click instead of the row
                    // behind it, and keeps that row's cursor state honest -
                    // hovering a child steals hover from the parent, which
                    // would otherwise drop the row highlight the moment you
                    // reached for an agent inside it.
                    MouseArea {
                      id: agentMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onContainsMouseChanged: if (containsMouse) root.cursorToAgent(row.index, agentRow.index)
                      onClicked: root.focusAgent(row.modelData, agentRow.modelData)
                    }
                  }
                }

              }

              // The buttons keep their slot on every row, so the names stay
              // in one column. Faint until the row is under the cursor: a
              // control where you are looking, and almost nothing where you
              // are not.
              Row {
                id: actions
                anchors.top: parent.top
                spacing: Style.space(2)
                opacity: row.active ? 1 : 0.25
                // The buttons stay faint until the row is under the cursor,
                // and `active` already covers that for both mouse and keys.

                Behavior on opacity { NumberAnimation { duration: 80 } }

                // hasCursor makes the button render its hover state for the
                // keyboard too, so the cursor looks the same whether it got
                // there by pointing or by pressing Right.
                PanelActionButton {
                  hasCursor: root.cursorOnSession(row.index)
                    && root.column === root.columnOpen
                  iconText: root.iconOpen
                  tooltipText: row.modelData.windowAddress !== ""
                    ? "Focus this session" : "Open this session"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.iconSmall
                  onClicked: root.openSession(row.modelData)
                }

                // One destructive slot, holding whichever of the two applies
                // to this row: a running server is killed, a stopped session is
                // deleted, and nothing is ever both. Sharing the slot rather
                // than giving each its own keeps the names in one column and
                // leaves no gap where the other button would have been.
                //
                // The shared session is herdr's own, so it can be killed but
                // never deleted - hence the empty slot there once it is down.
                Item {
                  width: killButton.width
                  height: killButton.height

                  PanelActionButton {
                    id: killButton
                    hasCursor: root.cursorOnSession(row.index)
                      && root.column === root.columnDestroy
                    visible: row.modelData.running
                    iconText: root.iconKill
                    tooltipText: "Kill this server"
                    foreground: Qt.darker(root.foreground, 1.4)
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.iconSmall
                    onClicked: root.askKill(row.modelData)
                  }

                  PanelActionButton {
                    hasCursor: root.cursorOnSession(row.index)
                      && root.column === root.columnDestroy
                    visible: !row.modelData.running && !row.modelData.isDefault
                    iconText: root.iconTrash
                    tooltipText: "Delete this session"
                    foreground: Qt.darker(root.foreground, 1.4)
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.iconSmall
                    onClicked: root.removeSession(row.modelData)
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------- empty

        Item {
          width: parent.width
          height: root.sessions.length === 0 && root.reachable
            ? empty.implicitHeight + Style.space(16) : 0
          visible: height > 0

          Text {
            id: empty
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No herdr sessions"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: Qt.darker(root.foreground, 1.8)
          }
        }
      }

      // ------------------------------------------------------- confirm

      // The dialog carries its own key handling, because PanelKeyCatcher
      // defines `Keys.onPressed` in the component itself: declaring it again
      // out here would replace that handler rather than run before it, and
      // every arrow key in the panel with it. So the catcher is blocked
      // instead and this takes the focus while the question is up.
      //
      // Only alive while it is asking - an invisible item cannot hold focus,
      // which is what keeps the panel's own keys working the rest of the time.
      Item {
        id: confirmKeys
        anchors.fill: parent
        z: 10
        visible: root.confirmOpen
        focus: root.confirmOpen

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (killConfirm.handleKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: killConfirm
          anchors.fill: parent
          opened: root.confirmOpen
          // ConfirmDialog draws the message with the shell's own Text, so
          // `textFormat` there is not ours to set and the session name - which
          // is whatever was passed to `herdr --session` - is stripped instead.
          message: root.plain(root.killMessage())
          confirmText: "Kill"
          background: Color.background
          foreground: root.foreground
          fontFamily: root.fontFamily
          onCanceled: root.closeKill()
          onConfirmed: root.confirmKill()
        }
      }
    }
  }
}
