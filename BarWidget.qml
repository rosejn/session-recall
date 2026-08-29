import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus dropdown for Session Recall.
//
// The default path needs none of this — the service saves and restores on its
// own. This is the explicit layer: name a setup, bring one back, and see what
// the automatic snapshots actually captured before trusting them.
Panel {
  id: root
  moduleName: "session-recall"
  // Lets a keybinding open the dropdown:
  //   o.bind("SUPER + SHIFT + S", "Session Recall", "omarchy-shell session-recall toggle")
  ipcTarget: "session-recall"

  readonly property string home: Quickshell.env("HOME")
  readonly property string recall: home + "/.config/omarchy/plugins/session-recall/bin/recall"

  // The bar sizes each slot from the widget's implicit size. Without these the
  // slot collapses to 0x0 and the icon is silently invisible -- no QML error.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var snapshots: []
  property bool autoSave: true
  property bool autoRestore: true
  property bool busy: false
  property string statusLine: ""
  property string suggestedName: ""
  property string coverageNote: ""

  readonly property var latest: snapshots.length > 0 ? snapshots[0] : null

  // The bar icon carries the only always-visible state: whether anything is
  // being remembered at all. A paused recall should look different at a glance.
  readonly property string barGlyph: busy ? "󰔟" : (autoSave ? "󰆓" : "󰏤")

  function q(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }

  function refresh() {
    if (!listProc.running) listProc.running = true
    if (!configProc.running) configProc.running = true
    if (!suggestProc.running) suggestProc.running = true
    if (!coverageProc.running) coverageProc.running = true
  }

  function runRecall(args, thenRefresh) {
    if (actionProc.running) return
    busy = true
    actionProc.refreshAfter = thenRefresh !== false
    actionProc.command = ["bash", "-lc", q(recall) + " " + args]
    actionProc.running = true
  }

  function saveNamed() {
    var name = String(nameField.text || "").trim()
    if (name === "") name = suggestedName
    if (name === "") return
    statusLine = "Saving “" + name + "”…"
    runRecall("save " + q(name))
  }

  function setConfig(key, value) {
    // Written through the CLI so the file stays the one source of truth the
    // service watches; the toggle flips optimistically for feedback.
    Quickshell.execDetached(["bash", "-lc", q(recall) + " config " + q(key) + " " + q(String(value))])
  }

  // Automatic snapshots are identified by when they were taken, so the raw
  // "auto-20260829-110514" stem is noise next to the relative time below it.
  function autoLabel(name) {
    var m = /^auto-\d{8}-(\d{2})(\d{2})(\d{2})$/.exec(String(name || ""))
    return m ? "Automatic · " + m[1] + ":" + m[2] : String(name || "")
  }

  function relativeTime(iso) {
    if (!iso) return ""
    var then = new Date(iso).getTime()
    if (isNaN(then)) return ""
    var mins = Math.round((Date.now() - then) / 60000)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + "m ago"
    var hours = Math.round(mins / 60)
    if (hours < 24) return hours + "h ago"
    return Math.round(hours / 24) + "d ago"
  }

  // Compact by design: both the hero meta and the row subtitles have less room
  // than the wording suggests, and spelling it out just produces an ellipsis.
  function describeShort(s) {
    if (!s) return ""
    var parts = [s.windows + "w"]
    if (s.agents > 0) parts.push(s.agentsResumable + "/" + s.agents + " agents")
    if (s.uncertain > 0) parts.push(s.uncertain + " unsure")
    return parts.join(" · ")
  }

  Process {
    id: listProc
    command: ["bash", "-lc", root.q(root.recall) + " list --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.snapshots = JSON.parse(String(text || "[]")) }
        catch (e) { root.snapshots = [] }
      }
    }
  }

  Process {
    id: configProc
    command: ["bash", "-lc",
      "cat " + root.q(root.home + "/.local/state/omarchy-recall/config.json") + " 2>/dev/null || echo '{}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var c = JSON.parse(String(text || "{}"))
          root.autoSave = c.autoSave !== false
          root.autoRestore = c.autoRestore !== false
        } catch (e) {}
      }
    }
  }

  // Names the apps with no handler, so the gap is visible where people look
  // rather than only in the log.
  Process {
    id: coverageProc
    command: ["bash", "-lc",
      "jq -r '[ .windows[] | select((.launch.handler // \"\") == \"\")"
      + " | select(.launch.tier != \"webapp\") | .class ] | unique | length' "
      + root.q(root.home + "/.local/state/omarchy-recall/latest/snapshot.json") + " 2>/dev/null || echo 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = parseInt(String(text || "0").trim())
        root.coverageNote = (isNaN(n) || n === 0)
          ? "every app has a handler"
          : n + (n === 1 ? " app has no handler yet" : " apps have no handler yet")
      }
    }
  }

  Process {
    id: suggestProc
    command: ["bash", "-lc", root.q(root.recall) + " suggest-name"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.suggestedName = String(text || "").trim()
    }
  }

  Process {
    id: actionProc
    property bool refreshAfter: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.statusLine = t.split("\n")[0]
      }
    }
    onExited: function(code) {
      root.busy = false
      if (code === 0 && root.statusLine.indexOf("Saving") === 0) root.statusLine = "Saved."
      if (refreshAfter) root.refresh()
      clearStatus.restart()
    }
  }

  Timer { id: clearStatus; interval: 4000; onTriggered: root.statusLine = "" }

  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: root.barGlyph
          color: root.autoSave ? root.barForeground : Qt.darker(root.barForeground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }
      }
    }
    onPressed: function(code) {
      // Right-click is the one-key panic button: snapshot right now, before
      // whatever you are about to do.
      if (code === Qt.RightButton) { root.statusLine = "Saving…"; root.runRecall("auto-save") }
      else if (code === Qt.MiddleButton) root.runRecall("restore latest --quiet")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(d) { root.switchPanel(d) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.saveNamed()
        else if (t === "r" || t === "R") root.runRecall("restore latest --quiet")
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Session Recall"
            meta: root.busy ? "Working…"
              : (root.statusLine !== "" ? root.statusLine
                : (root.latest
                    ? "Last saved " + root.relativeTime(root.latest.createdAt) + " · " + root.describeShort(root.latest)
                    : "Nothing saved yet"))
            // Badge-sized by contract — see describeShort above.
            detail: root.autoSave ? "auto" : "paused"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰆓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------------------------------------------------- save as name
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            TextField {
              id: nameField
              width: parent.width - saveButton.width - Style.spacing.controlGap
              foreground: root.foreground
              placeholderText: root.suggestedName !== ""
                ? "Save as “" + root.suggestedName + "”"
                : "Name this setup"
              onAccepted: root.saveNamed()
            }

            PanelActionButton {
              id: saveButton
              iconText: "󰆓"
              tooltipText: "Save the current desktop as a named setup"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.busy
              onClicked: root.saveNamed()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ------------------------------------------------------- behaviour
          Column {
            width: parent.width
            spacing: Style.space(6)

            Toggle {
              width: parent.width
              label: "Save automatically"
              description: "Snapshot whenever the desktop settles after a change"
              checked: root.autoSave
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                root.autoSave = !root.autoSave
                root.setConfig("autoSave", root.autoSave)
              }
            }

            Toggle {
              width: parent.width
              label: "Restore on login"
              description: "Bring the last snapshot back on the first start after a boot"
              checked: root.autoRestore
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                root.autoRestore = !root.autoRestore
                root.setConfig("autoRestore", root.autoRestore)
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // The log is the whole debugging story for an unattended restore, and
          // it names every app that has no handler yet -- which is how someone
          // finds out there is a gap they could fill.
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            PanelActionButton {
              iconText: "󰈙"
              tooltipText: "Open the save/restore log"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                root.close()
                if (root.bar) root.bar.run(
                  "omarchy-launch-or-focus-tui " + root.q(
                    "bash -c " + root.q(root.q(root.recall) + " logs -n 500 | less -R +G")))
              }
            }

            PanelActionButton {
              iconText: "󰋽"
              tooltipText: "What this machine can capture (recall doctor)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                root.close()
                if (root.bar) root.bar.run(
                  "omarchy-launch-or-focus-tui " + root.q(
                    "bash -c " + root.q(root.q(root.recall) + " doctor; read -n 1")))
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.coverageNote
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "SAVED SETUPS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.snapshots.length === 0
            width: parent.width
            text: "No snapshots yet. They appear here as soon as the desktop changes."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }


          Column {
            id: rows
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.snapshots.slice(0, 10)
              delegate: CursorSurface {
                id: rowSurface
                required property var modelData
                required property int index
                width: rows.width
                implicitHeight: rowCol.implicitHeight + Style.spacing.md * 2
                foreground: root.foreground
                hasCursor: rowMouse.containsMouse

                Row {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.md
                  spacing: Style.spacing.controlGap

                  Column {
                    id: rowCol
                    width: parent.width - restoreBtn.width - deleteBtn.width - Style.spacing.controlGap * 2
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: rowSurface.modelData.kind === "auto"
                        ? root.autoLabel(rowSurface.modelData.name)
                        : rowSurface.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.relativeTime(rowSurface.modelData.createdAt)
                        + "  ·  " + root.describeShort(rowSurface.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    id: restoreBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰑓"
                    tooltipText: "Restore this setup"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: {
                      root.statusLine = "Restoring “" + rowSurface.modelData.name + "”…"
                      root.runRecall("restore " + root.q(rowSurface.modelData.name) + " --quiet")
                    }
                  }

                  PanelActionButton {
                    id: deleteBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰆴"
                    tooltipText: "Delete this snapshot"
                    foreground: root.foreground
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.runRecall("delete " + root.q(rowSurface.modelData.name))
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }
              }
            }
          }
        }
      }
    }
  }
}
