import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Everything inside the card: the herd, the keys that walk it, and the one
// question that has to be asked before a server is killed.
//
// It lives in its own file because there are two places to put it. The bar
// button opens it as a dropdown, and the pin opens it as a window that stays
// on screen while you work. Those are two surfaces around one card, and the
// moment that card is written twice the two start to differ: a fix lands in
// one of them, a colour is changed in the other, and the pinned panel becomes
// a worse copy of the dropdown rather than the same thing in another place.
//
// So this file knows nothing about where it is. It is handed the widget that
// owns the data and a height it may grow to, and everything else follows.
PanelKeyCatcher {
  id: card

  // The widget that owns the data, the colours and every action. Everything
  // in here reads through it rather than keeping a copy, so the two cards
  // never drift apart.
  property var panel: null

  // How tall the content may grow, handed in by whichever surface is holding
  // this card: a dropdown has the screen minus the bar, a pinned window has
  // the screen minus its own margins. The chrome around the list is worked
  // out here, because that is a fact about this card and not about the
  // surface it happens to be sitting in.
  property real maxHeight: Style.space(400)

  // Everything in the column that is not the list, measured rather than
  // guessed at. A constant was close enough while the only card was a dropdown
  // that grew to fit its content, because being twenty pixels out just meant
  // twenty pixels of headroom nobody saw. On a card whose height you set
  // yourself those twenty pixels are a band of empty card under the last row,
  // and they are the difference between a panel that fits its box and one that
  // does not.
  //
  // None of these depend on the list, so there is no loop: the header and the
  // rule are always there, the warning and the empty line only sometimes, and
  // a Column puts a gap under each of them.
  readonly property real chrome: {
    var count = 2
    var height = headerRow.height + rule.height
    if (staleBox.visible) { count += 1; height += staleBox.height }
    if (machineBox.visible) { count += 1; height += machineBox.height }
    if (emptyBox.visible) { count += 1; height += emptyBox.height }
    return height + content.spacing * count
  }

  readonly property real listCap:
    Math.max(Style.space(40), card.maxHeight - card.chrome)

  // What the host measures its card against.
  readonly property real bodyHeight: content.implicitHeight

  // How deep the drag handle reaches. The header is the strip that moves a
  // pinned card, and only the host knows where the card's own padding puts it,
  // so it asks.
  readonly property real headerHeight: headerRow.height

  // The cursor scrolls the list it is actually walking, which is whichever of
  // the two cards is on screen. The widget picks; this is how it reaches in.
  function showRow(index) {
    list.positionViewAtIndex(index, ListView.Contain)
  }

  function beginConfirm() {
    killConfirm.selectedIndex = 0
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  // Focus goes back to the card by hand on the way out. The key catcher gave
  // it up when the dialog took over, and nothing hands it back on its own.
  function endConfirm() {
    Qt.callLater(function() { card.forceActiveFocus() })
  }

  anchors.fill: parent
  // While the dialog is up the panel's own keys are off, so Escape closes
  // the question rather than the whole panel, and Enter answers it rather
  // than opening whatever the cursor was on.
  blocked: panel.confirmOpen
  onCloseRequested: panel.close()
  onMoveRequested: function(dx, dy) {
    if (dy !== 0) panel.moveCursor(dy)
    else if (dx !== 0) panel.moveColumn(dx)
  }
  onTabRequested: function(direction) { panel.cycleColumn(direction) }
  // Only activateRequested, never returnRequested as well: Enter fires
  // both, and a handler on each runs the action twice.
  onActivateRequested: panel.activateCursor()
  onTextKey: function(t) {
    // The letter keys stay about the server, wherever inside it the
    // cursor happens to be: you kill a server, never an agent.
    var session = panel.sessionAt(panel.cursor)
    if (t === "o" && session) panel.openSession(session)
    else if (t === "k" && session) panel.askKill(session)
    else if (t === "x" && session) panel.removeSession(session)
    else if (t === "p") panel.togglePin()
    else if (t === "r") panel.refresh()
  }

  Column {
    id: content
    anchors.fill: parent
    spacing: Style.space(6)

    // ------------------------------------------------------- header
    //
    // Also the handle. A pinned card is dragged by whatever in it does not
    // take a click of its own, and this row is the widest such stretch, so it
    // is what a hand reaches for. Nothing says so in words: the cursor turns
    // into a hand over it, which is the promise every other draggable thing
    // on the desktop makes.

    Item {
      id: headerRow
      width: parent.width
      height: Math.max(title.implicitHeight, pinButton.implicitHeight)

      // Six dots, drawn rather than looked up in a font, because this one has
      // to be exactly right at three pixels and a glyph at that size is
      // whatever the family felt like. Two rows wider than tall, which is the
      // mark every draggable strip on every desktop carries, and it appears
      // only on the card that can actually be moved: an affordance on a thing
      // that does not do it is worse than none.
      Row {
        id: grip
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: panel.pinned
        spacing: Math.max(2, Style.space(3))

        Repeater {
          model: 3

          Column {
            spacing: Math.max(2, Style.space(3))

            Repeater {
              model: 2

              Rectangle {
                width: Math.max(2, Style.space(3))
                height: width
                radius: width / 2
                color: Qt.darker(panel.foreground, 2.2)
              }
            }
          }
        }
      }

      PanelSectionHeader {
        id: title
        anchors.left: grip.visible ? grip.right : parent.left
        anchors.leftMargin: grip.visible ? Style.space(8) : 0
        anchors.right: pinButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: panel.titleText()
        textFormat: Text.PlainText
        elide: Text.ElideRight
        foreground: panel.foreground
        fontFamily: panel.fontFamily
      }

      // Pinning is this card coming loose from the bar: the same card, in the
      // same spot, that stays there while you work. So the button sits in the
      // header of both and does not move, and the accent is the whole of what
      // says which of the two you are looking at.
      PanelActionButton {
        id: pinButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: panel.iconPin
        tooltipText: panel.pinned
          ? "Put it back in the bar (p)"
          : "Keep this panel on screen (p)"
        foreground: panel.pinned ? panel.accent : Qt.darker(panel.foreground, 1.5)
        hoverColor: panel.accent
        fontFamily: panel.fontFamily
        fontSize: Style.font.iconSmall
        onClicked: panel.togglePin()
      }
    }

    PanelSeparator { id: rule; width: parent.width }

    Item {
      id: staleBox
      width: parent.width
      height: panel.reachable ? 0 : staleWarning.implicitHeight + Style.space(6)
      visible: !panel.reachable

      Text {
        id: staleWarning
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        text: panel.errorText !== "" ? panel.errorText : "Could not reach herdr."
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        color: panel.urgent
      }
    }

    // Machines that did not answer the last poll. A machine that is down
    // has no rows of its own, so without this line it would vanish silently
    // - the worst shape for the machine your agents are on.
    Item {
      id: machineBox
      width: parent.width
      visible: panel.unreachableText() !== ""
      height: visible ? machineWarning.implicitHeight + Style.space(6) : 0

      Text {
        id: machineWarning
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        text: panel.unreachableText()
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        color: Qt.darker(panel.urgent, 1.2)
      }
    }

    // --------------------------------------------------------- list

    ListView {
      id: list
      width: parent.width
      visible: panel.sessions.length > 0
      clip: true
      model: panel.sessions
      spacing: Style.space(1)
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      // Grows with what it holds and stops at whatever the card has left
      // once the header and the footer have had their share.
      height: Math.min(contentHeight, card.listCap)

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index

        // The session is lit whenever the cursor is anywhere inside it, so
        // the action buttons on the right stay reachable while you walk
        // the agents underneath.
        readonly property bool active: panel.cursorOnSession(row.index) || rowMouse.containsMouse

        width: list.width - (list.interactive ? Style.space(10) : 0)
        height: rowContent.implicitHeight + Style.space(10)
        radius: Style.cornerRadius
        opacity: panel.pending(modelData) ? 0.4 : 1
        color: active
          ? Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.08)
          : "transparent"

        Behavior on color { ColorAnimation { duration: 80 } }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) panel.cursorToSession(row.index)
          onClicked: panel.openSession(row.modelData)
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
              text: panel.iconDot
              textFormat: Text.PlainText
              font.family: panel.fontFamily
              font.pixelSize: Style.space(7)
              color: panel.statusColor(row.modelData)
            }
          }

          Column {
            id: agentColumn
            width: parent.width - Style.space(21) - actions.width - rowContent.spacing
            spacing: Style.space(2)

            Item {
              width: parent.width
              height: name.implicitHeight

              // The machine a remote session runs on, as a dim prefix in
              // front of its name. Local rows get nothing: the panel is
              // about this machine by default, and a label that says so on
              // every row is noise.
              Text {
                id: machine
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== ""
                text: panel.machineName(row.modelData)
                textFormat: Text.PlainText
                font.family: panel.fontFamily
                font.pixelSize: Style.font.body
                color: Qt.darker(panel.foreground, 1.7)
              }

              Text {
                id: name
                anchors.left: machine.visible ? machine.right : parent.left
                anchors.leftMargin: machine.visible ? Style.space(4) : 0
                anchors.right: counts.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: panel.sessionLabel(row.modelData)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: panel.fontFamily
                font.pixelSize: Style.font.body
                // The window a session is showing is the one you would
                // switch to; a session without one still has to be opened.
                font.bold: row.modelData.windowAddress !== ""
                color: row.modelData.running
                  ? panel.foreground
                  : Qt.darker(panel.foreground, 1.6)
              }

              Row {
                id: counts
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(5)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: panel.noteLabel(row.modelData) !== ""
                  text: panel.noteLabel(row.modelData)
                  textFormat: Text.PlainText
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  color: panel.noteColor(row.modelData)
                }

                // Only when there is nothing louder to say. "2 done" and
                // "3 agents" side by side costs half the width of a narrow
                // card, and the second half of that is the half you already
                // know: the agents are listed underneath, one line each. So
                // the count steps aside for the state, and the name it was
                // pushing out of view gets the room back.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: panel.noteLabel(row.modelData) === ""
                    && panel.countLabel(row.modelData) !== ""
                  text: panel.countLabel(row.modelData)
                  textFormat: Text.PlainText
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  color: Qt.darker(panel.foreground, 1.7)
                }
              }
            }

            Text {
              width: parent.width
              visible: text !== ""
              height: visible ? implicitHeight : 0
              text: panel.subtitleFor(row.modelData)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(panel.foreground, 1.9)
            }

            // What each agent in there is actually doing. The title is
            // whatever the agent wrote to the terminal, so it is external
            // text: plain, elided, and never markup.
            Repeater {
              model: panel.agentsOf(row.modelData)

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

                // The slack around the text, on both sides of it. It used to
                // be added to the height and left there, which put all of it
                // under the last line: invisible while the only thing drawn
                // behind a row was a hover tint you saw for half a second, and
                // plainly wrong the moment a row that wants something carries
                // a block of colour all day.
                readonly property real pad: Style.space(3)

                height: (agentWorkspace.visible
                         ? agentWorkspace.implicitHeight + agentTitle.implicitHeight + Style.space(1)
                         : agentTitle.implicitHeight) + pad * 2

                // Three greys down the row, and that is the whole trick:
                // the workspace is the name of the place and sits at the
                // top, the terminal title is what happens to be running
                // there and sits under it a shade back, and the state sits
                // out right in its own colour. Give any two of them the
                // same weight and the panel turns into a wall of text.
                readonly property bool lit: agentMouse.containsMouse
                  || (panel.cursorInBody() && panel.cursorOnAgent(row.index, agentRow.index))
                readonly property bool wants: panel.agentWants(modelData.status)

                // An agent that wants something colours its whole line and not
                // only its dot and the word at the end. A dot is something you
                // have to be looking at; a wash of colour across a row is
                // something you catch out of the corner of your eye, and a
                // panel that sits on the desktop all day is read out of the
                // corner of your eye or it is not read at all.
                //
                // Red for a question, green for work that has finished, and
                // nothing whatever for the rest. Tint the busy ones too and the
                // panel is a stripe of colours again, which is the state it was
                // in before any of this meant anything.
                readonly property color tint: agentRow.wants
                  ? panel.agentColor(modelData.status) : panel.foreground
                readonly property real tintAlpha: agentRow.wants
                  ? (agentRow.lit ? 0.30 : 0.18)
                  : (agentRow.lit ? 0.13 : 0)

                // Bleeds past the text on both sides so the highlight
                // reads as a row of the list rather than a box drawn
                // around a sentence.
                Rectangle {
                  anchors.fill: parent
                  anchors.leftMargin: -Style.space(4)
                  anchors.rightMargin: -Style.space(4)
                  radius: Style.cornerRadius
                  color: agentRow.tintAlpha > 0
                    ? Qt.rgba(agentRow.tint.r, agentRow.tint.g,
                              agentRow.tint.b, agentRow.tintAlpha)
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
                  anchors.topMargin: agentRow.pad + Style.space(3)
                  text: panel.iconDot
                  textFormat: Text.PlainText
                  font.family: panel.fontFamily
                  font.pixelSize: Style.space(5)
                  color: panel.agentColor(agentRow.modelData.status)

                  SequentialAnimation on opacity {
                    running: panel.blinking(row.modelData, agentRow.modelData)
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
                  anchors.topMargin: agentRow.pad
                  visible: text !== ""
                  text: agentRow.modelData.workspace || ""
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  color: agentRow.wants || agentRow.lit
                    ? panel.foreground
                    : Qt.darker(panel.foreground, 1.3)
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
                  anchors.topMargin: agentWorkspace.visible ? Style.space(1) : agentRow.pad
                  text: panel.cleanTitle(agentRow.modelData.title)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  // Always a step behind the workspace above it, lit or
                  // not: what the agent called itself is the detail, the
                  // place is the heading.
                  color: agentRow.wants || agentRow.lit
                    ? Qt.darker(panel.foreground, 1.5)
                    : Qt.darker(panel.foreground, 2.1)
                }

                Text {
                  id: agentNote
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.topMargin: agentRow.pad
                  visible: panel.agentNote(agentRow.modelData.status) !== ""
                  text: panel.agentNote(agentRow.modelData.status)
                  textFormat: Text.PlainText
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  // Only the two that are news carry weight. Bold on every
                  // line would put the column back where it started.
                  font.bold: panel.agentWants(agentRow.modelData.status)
                  color: panel.agentColor(agentRow.modelData.status)
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
                  onContainsMouseChanged: if (containsMouse) panel.cursorToAgent(row.index, agentRow.index)
                  onClicked: panel.focusAgent(row.modelData, agentRow.modelData)
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
              hasCursor: panel.cursorOnSession(row.index)
                && panel.column === panel.columnOpen
              iconText: panel.iconOpen
              tooltipText: row.modelData.windowAddress !== ""
                ? "Focus this session" : "Open this session"
              foreground: panel.foreground
              hoverColor: panel.accent
              fontFamily: panel.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: panel.openSession(row.modelData)
            }

            // One destructive slot, holding whichever of the two applies
            // to this row: a running server is killed, a stopped session is
            // deleted, and nothing is ever both. Sharing the slot rather
            // than giving each its own keeps the names in one column and
            // leaves no gap where the other button would have been.
            //
            // The shared session is herdr's own, so it can be killed but
            // never deleted - hence the empty slot there once it is down.
            // Remote rows leave the slot empty too: ending something on
            // another machine, from a bar, is a way to lose work you cannot
            // see, so the panel offers it for local sessions only.
            Item {
              width: killButton.width
              height: killButton.height

              PanelActionButton {
                id: killButton
                hasCursor: panel.cursorOnSession(row.index)
                  && panel.column === panel.columnDestroy
                visible: row.modelData.running && !row.modelData.remote
                iconText: panel.iconKill
                tooltipText: "Kill this server"
                foreground: Qt.darker(panel.foreground, 1.4)
                hoverColor: panel.urgent
                fontFamily: panel.fontFamily
                fontSize: Style.font.iconSmall
                onClicked: panel.askKill(row.modelData)
              }

              PanelActionButton {
                hasCursor: panel.cursorOnSession(row.index)
                  && panel.column === panel.columnDestroy
                visible: !row.modelData.running && !row.modelData.isDefault
                  && !row.modelData.remote
                iconText: panel.iconTrash
                tooltipText: "Delete this session"
                foreground: Qt.darker(panel.foreground, 1.4)
                hoverColor: panel.urgent
                fontFamily: panel.fontFamily
                fontSize: Style.font.iconSmall
                onClicked: panel.removeSession(row.modelData)
              }
            }
          }
        }
      }
    }

    // -------------------------------------------------------- empty

    Item {
      id: emptyBox
      width: parent.width
      height: panel.sessions.length === 0 && panel.reachable
        ? empty.implicitHeight + Style.space(16) : 0
      visible: height > 0

      Text {
        id: empty
        anchors.centerIn: parent
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "No herdr sessions"
        textFormat: Text.PlainText
        font.family: panel.fontFamily
        font.pixelSize: Style.font.caption
        color: Qt.darker(panel.foreground, 1.8)
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
    visible: panel.confirmOpen
    focus: panel.confirmOpen

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (killConfirm.handleKey(event)) event.accepted = true
    }

    ConfirmDialog {
      id: killConfirm
      anchors.fill: parent
      opened: panel.confirmOpen
      // ConfirmDialog draws the message with the shell's own Text, so
      // `textFormat` there is not ours to set and the session name - which
      // is whatever was passed to `herdr --session` - is stripped instead.
      message: panel.plain(panel.killMessage())
      confirmText: "Kill"
      background: Color.background
      foreground: panel.foreground
      fontFamily: panel.fontFamily
      onCanceled: panel.closeKill()
      onConfirmed: panel.confirmKill()
    }
  }
}
