import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One glyph per drive. Hover: a card with usage, activity and actions
// (DriveCard.qml). Left-click opens (or mounts / unlocks), right-click ejects.
// Past `groupAt` drives the icons collapse into one with a count and a card
// listing them all.
//
// Icon states: dimmed = plugged in but not mounted; urgent colour = at least
// `fullWarnPct` full; pulsing = being written to, or rclone still uploading.
BarWidget {
  id: root
  moduleName: "jgarza.drives"

  property var drives: []
  // lsblk name (disk, partition, mapper) -> {writing, rate}; only writing
  // devices are listed. Kernel dirty+writeback bytes.
  property var activity: ({})
  property real cached: 0
  // drive.key -> {message, procs}; drive.key -> true. Reassigned, not
  // mutated, so bindings notice.
  property var busy: ({})
  property var infoOpen: ({})
  property int openCards: 0

  // kind -> glyph override; "" falls back to Model.DEFAULT_ICONS.
  readonly property var icons: ({
    thumb: setting("iconThumb", ""),
    external: setting("iconExternal", ""),
    internal: setting("iconInternal", ""),
    sd: setting("iconSd", ""),
    optical: setting("iconOptical", ""),
    image: setting("iconImage", ""),
    network: setting("iconNetwork", ""),
    gdrive: setting("iconGdrive", ""),
    onedrive: setting("iconOnedrive", ""),
    dropbox: setting("iconDropbox", ""),
    cloud: setting("iconCloud", "")
  })
  readonly property real thumbMaxGb: Number(setting("thumbMaxGb", 256)) || 256
  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property bool showNetwork: setting("showNetwork", true) !== false
  readonly property bool showUnmounted: setting("showUnmounted", true) !== false
  readonly property real minUnmountedMb: Number(setting("minUnmountedMb", 64))
  readonly property int fullWarnPct: Number(setting("fullWarnPct", 90)) || 90
  readonly property int groupAt: Number(setting("groupAt", 4))
  readonly property int pollMs: Math.max(2, Number(setting("pollIntervalSec", 10)) || 10) * 1000

  readonly property bool grouped: groupAt > 0 && drives.length >= groupAt
  readonly property bool anyWriting: drives.some(function(d) { return isActive(d) })
  readonly property bool anyFull: drives.some(function(d) { return isFull(d) })
  readonly property bool hasBlockDrives: drives.some(function(d) { return !!d.diskName })

  function isFull(d) { return d.mounted && d.size > 0 && d.pct >= fullWarnPct }
  // Write activity for this filesystem's own device (partition / mapper),
  // not its disk — sibling partitions must not light up.
  function activityFor(d) {
    return (d.name && activity[d.name]) || null
  }
  function isActive(d) {
    var a = activityFor(d)
    return !!(a && a.writing && d.mounted) || d.pending > 0
  }

  function script(name) {
    var value = String(Qt.resolvedUrl("bin/" + name))
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.substring(7)) : value
  }

  // ---- data ---------------------------------------------------------------

  function refresh() {
    if (lister.running) { refreshAgain = true; return }
    var cmd = [script("drives-list"), "--thumb-max-gb", String(thumbMaxGb)]
    if (showNetwork) cmd.push("--network")
    if (showUnmounted) cmd.push("--unmounted", "--min-unmounted-mb", String(minUnmountedMb))
    lister.command = cmd
    lister.running = true
  }
  property bool refreshAgain: false

  // Keep delegates alive across refreshes (an open card must not be torn
  // down because the used-bytes figure moved): update the ListModel in place,
  // keyed by drive.key.
  function syncModel(next) {
    var keys = next.map(function(d) { return d.key })
    for (var i = driveModel.count - 1; i >= 0; i--) {
      if (keys.indexOf(driveModel.get(i).key) < 0) driveModel.remove(i)
    }
    for (var j = 0; j < next.length; j++) {
      var json = JSON.stringify(next[j])
      var at = -1
      for (var k = j; k < driveModel.count; k++) {
        if (driveModel.get(k).key === next[j].key) { at = k; break }
      }
      if (at < 0) driveModel.insert(j, { key: next[j].key, json: json })
      else {
        if (at !== j) driveModel.move(at, j, 1)
        if (driveModel.get(j).json !== json) driveModel.setProperty(j, "json", json)
      }
    }
    root.drives = next
    // Forget UI state for drives that went away.
    var busy = {}, info = {}
    for (var n = 0; n < keys.length; n++) {
      if (root.busy[keys[n]]) busy[keys[n]] = root.busy[keys[n]]
      if (root.infoOpen[keys[n]]) info[keys[n]] = true
    }
    root.busy = busy
    root.infoOpen = info
  }

  ListModel { id: driveModel }

  Process {
    id: lister
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.syncModel(JSON.parse(text).drives || [])
        } catch (e) {
          console.warn("jgarza.drives: bad lister output", e)
        }
      }
    }
    onExited: if (root.refreshAgain) { root.refreshAgain = false; root.refresh() }
  }

  // Write activity, streamed. Only needed while a block drive is listed.
  Process {
    id: activityWatch
    command: [root.script("drives-activity")]
    running: root.hasBlockDrives
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var data = JSON.parse(line)
          root.activity = data.disks || {}
          root.cached = Number(data.cached) || 0
        } catch (e) {}
      }
    }
    onRunningChanged: if (!running) { root.activity = ({}); root.cached = 0 }
  }

  // Kernel block events (plug, unplug, media change). Mount itself lands a
  // moment after the add event, so debounce and also re-check shortly after.
  Process {
    id: monitor
    command: ["udevadm", "monitor", "--kernel", "--subsystem-match=block"]
    running: true
    stdout: SplitParser {
      onRead: function() { debounce.restart(); settle.restart() }
    }
  }
  Timer { id: debounce; interval: 500; onTriggered: root.refresh() }
  Timer { id: settle; interval: 2500; onTriggered: root.refresh() }
  // Poll faster while a card is open or something is writing, so the usage
  // figures move.
  Timer {
    interval: root.openCards > 0 || root.anyWriting ? 2000 : root.pollMs
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // ---- actions ------------------------------------------------------------

  function displayName(d) { return d.label || d.name || Model.kindName(d) }

  function open(d) {
    if (d.locked) return unlock(d)
    if (!d.mounted) return mount(d, true)
    run(["xdg-open", d.mountpoint])
  }

  function mount(d, thenOpen) {
    run([script("drives-action"), "mount", "--dev", d.path, "--name", displayName(d)], function(result) {
      if (thenOpen && result.status === "ok" && result.mountpoint) run(["xdg-open", result.mountpoint])
    })
  }

  // Passphrase goes into a terminal (udisksctl prompts on its tty), never
  // through the shell.
  function unlock(d) {
    var q = function(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    run(["omarchy-launch-floating-terminal-with-presentation",
         q(script("drives-action")) + " unlock --dev " + q(d.path) + " --name " + q(displayName(d))])
  }

  function lock(d) {
    run([script("drives-action"), "lock", "--dev", d.path, "--luks", d.luksPath,
         "--mount", d.mountpoint, "--name", displayName(d)], function(result) { setBusy(d, result) })
  }

  function eject(d, kill) {
    if (!d.mounted || !d.eject) return
    var cmd = [script("drives-action"), "eject", "--mode", d.eject, "--mount", d.mountpoint,
               "--name", displayName(d)]
    if (d.path && d.eject !== "fuse" && d.eject !== "gio") cmd.push("--dev", d.path)
    if (d.disk) cmd.push("--disk", d.disk)
    if (d.encrypted && d.luksPath) cmd.push("--luks", d.luksPath)
    if (d.removable) cmd.push("--removable")
    if (kill) cmd.push("--kill")
    run(cmd, function(result) { setBusy(d, result) })
  }

  function setBusy(d, result) {
    var next = Object.assign({}, root.busy)
    if (result.status === "busy") next[d.key] = { message: result.message, procs: result.procs || [] }
    else delete next[d.key]
    root.busy = next
  }

  function toggleInfo(d) {
    var next = Object.assign({}, root.infoOpen)
    if (next[d.key]) delete next[d.key]
    else next[d.key] = true
    root.infoOpen = next
  }

  // Short-lived process; `done(result)` gets the JSON line drives-action prints.
  function run(cmd, done) {
    var p = actionProcess.createObject(root, { command: cmd, done: done || null })
    p.running = true
  }

  Component {
    id: actionProcess
    Process {
      property var done: null
      stdout: StdioCollector { id: out }
      onExited: {
        if (done) {
          var result = { status: "error", message: "" }
          try { result = JSON.parse(out.text.trim().split("\n").pop()) } catch (e) {}
          done(result)
        }
        root.refresh()
        destroy()
      }
    }
  }

  IpcHandler {
    target: "drives"
    function refresh(): void { root.refresh() }
    function list(): string { return JSON.stringify(root.drives) }
    // Show a card without a pointer (screenshots, testing): peek(0), peek(1)…
    function peek(index: int): void {
      var item = root.grouped ? groupSlot : repeater.itemAt(index)
      if (item) item.peek()
    }
    function info(index: int): void { if (root.drives[index]) root.toggleInfo(root.drives[index]) }
    function eject(index: int): void { if (root.drives[index]) root.eject(root.drives[index], false) }
  }

  Component.onCompleted: refresh()
  Component.onDestruction: {
    if (monitor.running) monitor.running = false
    if (activityWatch.running) activityWatch.running = false
  }

  // ---- bar ----------------------------------------------------------------

  implicitWidth: vertical ? barSize : row.implicitWidth
  implicitHeight: vertical ? row.implicitHeight : barSize
  visible: drives.length > 0 || alwaysShow

  // Hover-card plumbing shared by per-drive slots and the group slot: open on
  // hover at once, close a beat after leaving so the pointer can cross into
  // the card.
  component HoverSlot: Item {
    id: slot
    property alias icon: icon
    property alias card: card
    default property alias cardContent: card.contentItem
    property bool pulsing: false
    property int cardWidth: Style.space(320)
    property real cardContentHeight: 0
    readonly property bool hovered: icon.tooltipHovered || card.containsMouse
    signal clicked(int button)

    function peek() { closeDelay.interval = 4000; card.open = true; closeDelay.restart() }

    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    onHoveredChanged: {
      if (hovered) { closeDelay.stop(); card.open = true }
      else { closeDelay.interval = 250; closeDelay.restart() }
    }
    Timer { id: closeDelay; interval: 250; onTriggered: card.open = false }

    Connections {
      target: card
      function onOpenChanged() { root.openCards += card.open ? 1 : -1; if (card.open) root.refresh() }
    }
    Component.onDestruction: if (card.open) root.openCards -= 1

    // Pulse lives on a wrapper: WidgetButton binds its own opacity.
    Item {
      id: pulse
      anchors.fill: parent
      SequentialAnimation on opacity {
        running: slot.pulsing
        loops: Animation.Infinite
        onRunningChanged: if (!running) pulse.opacity = 1
        NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
      }

      WidgetButton {
        id: icon
        anchors.fill: parent
        bar: root.bar
        fontSize: Style.font.iconLarge
        horizontalMargin: 5
        onPressed: function(button) { card.open = false; slot.clicked(button) }
      }
    }

    PopupCard {
      id: card
      anchorItem: icon
      bar: root.bar
      owner: slot
      triggerMode: "hover"
      contentWidth: card.fittedContentWidth(slot.cardWidth)
      contentHeight: card.fittedContentHeight(slot.cardContentHeight)
    }
  }

  Grid {
    id: row
    anchors.centerIn: parent
    columns: root.vertical ? 1 : 64
    spacing: 0

    WidgetButton {
      id: placeholder
      bar: root.bar
      visible: root.drives.length === 0 && root.alwaysShow
      text: root.icons.internal || Model.DEFAULT_ICONS.internal
      fontSize: Style.font.iconLarge
      dimmed: true
      pressable: false
      tooltipText: "No drives"
    }

    // One icon per drive.
    Repeater {
      id: repeater
      model: root.grouped ? null : driveModel
      delegate: HoverSlot {
        id: driveSlot
        required property string json
        readonly property var drive: JSON.parse(json)

        pulsing: root.isActive(drive)
        icon.text: Model.kindIcon(drive, root.icons)
        icon.dimmed: !drive.mounted
        icon.active: root.isFull(drive)
        cardContentHeight: driveCard.implicitHeight

        onClicked: function(button) {
          if (button === Qt.RightButton) root.eject(drive, false)
          else if (button === Qt.LeftButton) root.open(drive)
        }

        DriveCard {
          id: driveCard
          width: parent.width
          drive: driveSlot.drive
          widget: root
          onDismiss: driveSlot.card.open = false
        }
      }
    }

    // Many drives: one icon with a count, every drive in the card.
    HoverSlot {
      id: groupSlot
      visible: root.grouped
      pulsing: root.anyWriting
      icon.text: (root.icons.external || Model.DEFAULT_ICONS.external) + " " + root.drives.length
      icon.active: root.anyFull
      cardWidth: Style.space(340)
      cardContentHeight: groupColumn.implicitHeight

      onClicked: function(button) {
        if (button === Qt.LeftButton) groupSlot.peek()
      }

      Flickable {
        width: parent.width
        height: parent.height
        contentHeight: groupColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: groupColumn
          width: parent.width
          spacing: Style.space(12)

          Repeater {
            model: root.grouped ? driveModel : null
            delegate: Column {
              id: groupEntry
              required property string json
              required property int index
              width: groupColumn.width
              spacing: Style.space(12)

              PanelSeparator {
                visible: groupEntry.index > 0
                width: parent.width
              }

              DriveCard {
                width: parent.width
                drive: JSON.parse(groupEntry.json)
                widget: root
                onDismiss: groupSlot.card.open = false
              }
            }
          }
        }
      }
    }
  }
}
