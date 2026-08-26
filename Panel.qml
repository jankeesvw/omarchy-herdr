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
// says which project and how many agents each one holds, and opens or stops
// one on a click.
//
// A session shows at most one window, because two windows on one session
// mirror each other. So "open" means: focus the window already showing this
// session, wherever it is, and only start a new one when there is none.
// `bin/herdr-sessions` does that matching by reading the herdr client's own
// command line off the processes behind each Hyprland window.
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
  readonly property string iconStop: "\uF011"
  readonly property string iconTrash: "\uF1F8"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var sessions: []
  property int runningCount: 0
  property int agentCount: 0
  property int blockedCount: 0
  property int workingCount: 0
  property bool reachable: true
  property string errorText: ""
  // Session the script is currently acting on, so its row can dim.
  property string pendingName: ""
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

  function run(action, name) {
    if (!validName(name) || actionProc.running) return
    pendingName = name
    actionProc.command = [root.script, action, name]
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

  // Stopping ends the server; a session that was already stopped is deleted
  // instead, which is what clears it out of the list for good.
  function removeSession(session) {
    if (!session || session.isDefault) return
    run(session.running ? "stop" : "delete", session.name)
  }

  function moveCursor(delta) {
    if (sessions.length === 0) return
    var next = cursor + delta
    if (next < 0) next = 0
    if (next > sessions.length - 1) next = sessions.length - 1
    cursor = next
    list.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= sessions.length) return
    openSession(sessions[cursor])
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

  function subtitleFor(session) {
    if (!session) return ""
    if (!session.running) return "stopped"
    var projects = session.projects || []
    if (projects.length > 0) return projects.join("  ·  ")
    return "no workspaces yet"
  }

  function countLabel(session) {
    if (!session || !session.running) return ""
    var n = session.agents || 0
    if (n === 0) return "no agents"
    return n === 1 ? "1 agent" : n + " agents"
  }

  // The one word worth colouring: blocked means an agent is waiting on you,
  // working means it is busy. Anything else is quiet and says nothing.
  function noteLabel(session) {
    if (!session || !session.running) return ""
    if ((session.blocked || 0) > 0) return session.blocked + " blocked"
    if ((session.working || 0) > 0) return session.working + " working"
    return ""
  }

  function noteColor(session) {
    if (!session) return root.foreground
    return (session.blocked || 0) > 0 ? root.urgent : root.accent
  }

  function statusColor(session) {
    if (!session || !session.running) return Qt.darker(root.foreground, 2.2)
    if ((session.blocked || 0) > 0) return root.urgent
    if ((session.working || 0) > 0) return root.accent
    return Qt.darker(root.foreground, 1.7)
  }

  function titleText() {
    var s = runningCount === 1 ? " server" : " servers"
    var a = agentCount === 1 ? " agent" : " agents"
    return "Herdr (" + runningCount + s + ", " + agentCount + a + ")"
  }

  function applyPayload(text) {
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      sessions = data.sessions || []
      runningCount = data.running || 0
      agentCount = data.agents || 0
      blockedCount = data.blocked || 0
      workingCount = data.working || 0
      if (cursor > sessions.length - 1) cursor = sessions.length - 1
    } catch (e) {
      reachable = false
      errorText = "unexpected output from herdr-sessions"
    }
  }

  onOpenedChanged: {
    if (opened) refresh()
    else cursor = -1
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
    tooltipText: root.plain(root.titleText())

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
            color: root.blockedCount > 0 ? root.urgent : root.accent

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
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      // Only activateRequested, never returnRequested as well: Enter fires
      // both, and a handler on each runs the action twice.
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        var onCursor = root.cursor >= 0 && root.cursor < root.sessions.length
        if (t === "o" && onCursor) root.openSession(root.sessions[root.cursor])
        else if (t === "x" && onCursor) root.removeSession(root.sessions[root.cursor])
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

            readonly property bool active: root.cursor === row.index || rowMouse.containsMouse

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
              onContainsMouseChanged: if (containsMouse) root.cursor = row.index
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
                  text: root.subtitleFor(row.modelData)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: Qt.darker(root.foreground, 1.9)
                }
              }

              // The buttons keep their slot on every row, so the names stay
              // in one column. Faint until the row is under the cursor: a
              // control where you are looking, and almost nothing where you
              // are not.
              Row {
                id: actions
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                opacity: row.active ? 1 : 0.25

                Behavior on opacity { NumberAnimation { duration: 80 } }

                PanelActionButton {
                  iconText: root.iconOpen
                  tooltipText: row.modelData.windowAddress !== ""
                    ? "Focus this session" : "Open this session"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.iconSmall
                  onClicked: root.openSession(row.modelData)
                }

                // The shared session is not stopped from here: it is the one
                // herdr expects to keep, and its key is on the keyboard.
                // The slot stays so the rows line up.
                Item {
                  width: stopButton.width
                  height: stopButton.height

                  PanelActionButton {
                    id: stopButton
                    visible: !row.modelData.isDefault
                    iconText: row.modelData.running ? root.iconStop : root.iconTrash
                    tooltipText: row.modelData.running
                      ? "Stop this server" : "Delete this session"
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
    }
  }
}
