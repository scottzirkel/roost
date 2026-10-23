import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Roost on the Omarchy bar: every Roost window's agent state, and a click to
// jump to one. Left click lists the windows; right click jumps to the one that
// wants you most.
//
// The data comes from `roost status --all --watch`, which prints one line of
// JSON now and again whenever any window changes. One long-running process,
// rather than one per poll. Lives in the Roost repo (integrations/omarchy);
// scripts/install-omarchy-widget.sh copies it into the shell's plugins.
BarWidget {
  id: root
  moduleName: "dev.scottzirkel.roost"

  // [{ pid, project, name, branch, state }], sorted by name, from `roost`.
  property var windows: []
  property bool popupOpen: false

  readonly property string command: String(setting("command", "roost"))
  readonly property int waiting: count("needs-input")
  readonly property int working: count("working")
  readonly property int finished: count("done")

  readonly property string label: "󱗆"
    + (waiting > 0 ? "  󰂚 " + waiting : "")
    + (working > 0 ? "  ● " + working : "")
    + (finished > 0 ? "  ✓ " + finished : "")

  readonly property string tooltip: {
    var lines = []
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      var words = stateWords(w.state)
      lines.push(title(w) + (w.branch ? " · " + w.branch : "") + (words ? " — " + words : ""))
    }
    return lines.join("\n")
  }

  function count(state) {
    var n = 0
    for (var i = 0; i < windows.length; i++) if (windows[i].state === state) n++
    return n
  }

  function update(line) {
    try {
      var parsed = JSON.parse(line)
      windows = Array.isArray(parsed.windows) ? parsed.windows : []
    } catch (e) {
      // A line we can't read changes nothing; the next one will say.
    }
  }

  function glyph(state) {
    if (state === "needs-input") return "󰂚"
    if (state === "working") return "●"
    if (state === "done") return "✓"
    return ""
  }

  function stateWords(state) {
    if (state === "needs-input") return "needs you"
    if (state === "working") return "working"
    if (state === "done") return "done"
    if (state === "idle") return "idle"
    return ""
  }

  // A window on an older Roost build doesn't answer, so all we have is its pid.
  function title(w) { return w.name ? w.name : "Roost window " + w.pid }

  function detail(w) {
    if (!w.name) return "Reload it to show its project"
    var words = stateWords(w.state)
    if (w.branch && words) return w.branch + " · " + words
    return w.branch || words
  }

  // The window that wants you most: one that needs you, then one that's done.
  function mostUrgent() {
    var order = ["needs-input", "done"]
    for (var s = 0; s < order.length; s++) {
      for (var i = 0; i < windows.length; i++) if (windows[i].state === order[s]) return windows[i]
    }
    return null
  }

  function focusWindow(w) {
    popupOpen = false
    if (!w) return
    var pid = Number(w.pid)
    if (!(pid > 0)) return
    Util.execArgv(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "pid:' + pid + '" })'])
  }

  function close() { popupOpen = false }

  visible: windows.length > 0
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: barSize

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A vertical bar has room for one glyph.
    text: root.vertical ? (root.waiting > 0 ? "󰂚" : "󱗆") : root.label
    active: root.waiting > 0
    tooltipText: root.popupOpen ? "" : root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.focusWindow(root.mostUrgent())
      else root.popupOpen = !root.popupOpen
    }
  }

  Process {
    id: watcher
    // pdeathsig: the watcher goes when the shell does.
    command: ["setpriv", "--pdeathsig", "TERM", root.command, "status", "--all", "--watch"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.update(line) }
    }
    onExited: {
      root.windows = []
      restartTimer.restart()
    }
  }

  // `roost` missing, or killed: try again rather than stay blank until the
  // next shell reload.
  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: if (!watcher.running) watcher.running = true
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(list.implicitHeight)

    Column {
      id: list
      anchors.fill: parent
      spacing: Style.space(4)

      PanelSectionHeader {
        text: "Roost windows"
        foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      Repeater {
        model: root.windows

        BorderSurface {
          id: row
          required property var modelData

          readonly property bool hovered: rowMouse.containsMouse
          readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground

          width: list.width
          height: rowInner.implicitHeight + Style.space(10)
          radius: Style.spacing.labelGap
          color: hovered ? Style.selectedFillFor(fg, Commons.Color.accent) : "transparent"
          borderSpec: hovered ? Border.controlSpec("normal", fg, Commons.Color.accent) : Border.none()

          Row {
            id: rowInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: row.borderLeft + Style.space(8)
            anchors.rightMargin: row.borderRight + Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.glyph(row.modelData.state)
              color: row.modelData.state === "needs-input" && root.bar ? root.bar.urgent : row.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              width: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(26)
              spacing: Style.space(1)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                text: root.title(row.modelData)
                color: row.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.detail(row.modelData)
                color: Qt.darker(row.fg, 1.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
                visible: text !== ""
              }
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.focusWindow(row.modelData)
          }
        }
      }
    }
  }
}
