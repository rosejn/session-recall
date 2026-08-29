import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Headless half of Session Recall.
//
// Two jobs, both of which must happen without the user ever asking:
//   1. Snapshot the desktop whenever it settles after a change.
//   2. Restore the last snapshot once, on the first shell start after a boot.
//
// Everything real happens in bin/recall; this only decides *when*. Keeping the
// logic in bash means it is testable from a terminal and reviewable on its own,
// which matters for code running unsandboxed inside the shell process.
Item {
  id: root

  property var shell: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/session-recall"
  readonly property string recall: pluginDir + "/bin/recall"

  property bool autoSave: true
  property bool autoRestore: true
  property int debounceSec: 8

  property bool restoring: false
  property string lastSaveAt: ""
  property string lastError: ""

  // Windows opened by a restore keep arriving for a few seconds after the
  // command returns. Saving into that would capture a half-built desktop, so
  // events are ignored until it settles.
  readonly property bool settling: restoring || settleTimer.running

  function applyConfig(raw) {
    try {
      var c = JSON.parse(raw || "{}")
      if (c.autoSave !== undefined) autoSave = c.autoSave === true || c.autoSave === "true"
      if (c.autoRestore !== undefined) autoRestore = c.autoRestore === true || c.autoRestore === "true"
      if (c.autoSaveDebounceSec !== undefined) {
        var n = parseInt(c.autoSaveDebounceSec)
        if (!isNaN(n) && n >= 2 && n <= 120) debounceSec = n
      }
    } catch (e) {
      // A half-written config must never take the service down; the previous
      // values stay in force until the file parses again.
      lastError = "config parse failed: " + e
    }
  }

  function scheduleSave(reason) {
    if (!autoSave || settling) return
    saveTimer.restart()
  }

  function saveNow() {
    if (saveProc.running || settling) return
    saveProc.command = ["bash", "-lc", shellQuote(recall) + " auto-save"]
    saveProc.running = true
  }

  function restoreNow(name, extraArgs) {
    if (restoreProc.running) return
    restoring = true
    var cmd = shellQuote(recall) + " restore " + shellQuote(name || "latest")
    if (extraArgs) cmd += " " + extraArgs
    restoreProc.command = ["bash", "-lc", cmd]
    restoreProc.running = true
  }

  function shellQuote(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }

  FileView {
    id: configFile
    path: root.home + "/.local/state/omarchy-recall/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("{}")
    onFileChanged: reload()
  }

  // Window lifecycle events are the ones that change what a snapshot would
  // contain. Focus and mouse events fire constantly and would keep the
  // debounce permanently hot for no gain.
  readonly property var savedEvents: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "workspace", "workspacev2", "createworkspace", "destroyworkspace",
    "movewindowtoworkspace", "fullscreen", "changefloatingmode",
    "monitoradded", "monitorremoved"
  ]

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      if (root.savedEvents.indexOf(String(event.name)) === -1) return
      root.scheduleSave(String(event.name))
    }
  }

  Timer {
    id: saveTimer
    interval: root.debounceSec * 1000
    repeat: false
    onTriggered: root.saveNow()
  }

  Timer { id: settleTimer; interval: 6000; repeat: false }

  // A desktop that sits untouched for an hour still deserves a fresh snapshot,
  // so a crash never costs more than the heartbeat interval.
  Timer {
    interval: 3600000
    running: root.autoSave
    repeat: true
    onTriggered: root.saveNow()
  }

  Process {
    id: saveProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.lastError = String(text).trim()
    }
    onExited: function(code) {
      if (code === 0) { root.lastSaveAt = new Date().toISOString(); root.lastError = "" }
    }
  }

  Process {
    id: restoreProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.lastError = String(text).trim()
    }
    onExited: function() {
      root.restoring = false
      saveTimer.stop()
      settleTimer.restart()
    }
  }

  // The restore has to wait for the compositor and any autostarted apps to
  // finish arriving; racing them produces duplicate windows that reconcile
  // cannot tell apart yet.
  Timer {
    id: bootTimer
    interval: 4000
    repeat: false
    running: false
    onTriggered: {
      if (!root.autoRestore) return
      root.restoring = true
      bootProc.command = ["bash", "-lc", root.shellQuote(root.recall) + " boot-restore"]
      bootProc.running = true
    }
  }

  Process {
    id: bootProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function() { root.restoring = false; settleTimer.restart() }
  }

  Component.onCompleted: bootTimer.start()

  IpcHandler {
    target: "recall"

    function save(name: string): string {
      var cmd = name && name !== ""
        ? root.shellQuote(root.recall) + " save " + root.shellQuote(name)
        : root.shellQuote(root.recall) + " auto-save"
      Quickshell.execDetached(["bash", "-lc", cmd])
      return "saving"
    }

    function restore(name: string): string {
      root.restoreNow(name && name !== "" ? name : "latest", "")
      return "restoring"
    }

    function status(): string {
      return JSON.stringify({
        autoSave: root.autoSave,
        autoRestore: root.autoRestore,
        debounceSec: root.debounceSec,
        restoring: root.restoring,
        lastSaveAt: root.lastSaveAt,
        lastError: root.lastError
      })
    }

    function pause(): string  { root.autoSave = false; return "paused" }
    function resume(): string { root.autoSave = true;  return "resumed" }
  }
}
