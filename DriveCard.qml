import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Hover-card body for one drive:
//
//   Name 󰌾 RO  /mount/point            (muted)
//   14.5G / 116G  13%
//   [██████░░░░░░░░░░░░░░]
//   󰏫 Writing… 23 MB/s — wait before unplugging
//   Busy — in use by nvim (123)  [Retry] [Close apps & eject]
//   [Open] [Eject] [Info]
//   ┌ Info: device, filesystem, UUID, model, serial, connection, … ┐
//
// All actions and per-drive UI state (busy, info expanded) live on `widget`
// (the BarWidget), keyed by drive.key, so they survive list refreshes.
Column {
  id: card

  required property var drive
  required property var widget
  signal dismiss()

  readonly property var activity: widget.activityFor(drive)
  // Only a mounted filesystem is "writing".
  readonly property bool writing: !!(activity && activity.writing) && drive.mounted
  readonly property var busy: widget.busy[drive.key] || null
  readonly property bool infoOpen: widget.infoOpen[drive.key] === true
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property color muted: Color.muted

  spacing: Style.space(8)

  // Kind icon, name, badges, state (unmounted/locked only). The mountpoint
  // lives in the Info panel.
  Row {
    width: parent.width
    spacing: Style.space(8)

    Text {
      id: kindIcon
      anchors.verticalCenter: nameText.verticalCenter
      textFormat: Text.PlainText
      text: Model.kindIcon(card.drive, card.widget.icons)
      color: card.drive.mounted ? Color.accent : card.muted
      font.family: card.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Text {
      id: nameText
      textFormat: Text.PlainText
      text: card.drive.label || card.drive.name || Model.kindName(card.drive)
      color: Color.popups.text
      font.family: card.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      width: Math.min(implicitWidth, parent.width - kindIcon.width - parent.spacing
        - (badges.visible ? badges.width + parent.spacing : 0)
        - (stateText.visible ? stateText.implicitWidth + parent.spacing : 0))
      elide: Text.ElideRight
    }

    Text {
      id: badges
      textFormat: Text.PlainText
      visible: text !== ""
      text: (card.drive.encrypted ? "\u{f033e}" : "") + (card.drive.readOnly ? (card.drive.encrypted ? " " : "") + "RO" : "")
      color: card.drive.readOnly ? Color.urgent : Color.popups.text
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.baseline: nameText.baseline
    }

    Text {
      id: stateText
      textFormat: Text.PlainText
      visible: !card.drive.mounted
      text: card.drive.locked ? "locked" : "not mounted"
      color: card.muted
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
      anchors.baseline: nameText.baseline
    }
  }

  // used / size  pct%
  Text {
    textFormat: Text.PlainText
    visible: text !== ""
    text: card.drive.mounted
      ? Model.usageText(card.drive)
      : (card.drive.size > 0 ? Model.humanBytes(card.drive.size) + " " + (card.drive.fstype || "") : "")
    color: card.drive.mounted ? Color.popups.text : card.muted
    font.family: card.fontFamily
    font.pixelSize: Style.font.caption
  }

  // [███████------]
  Rectangle {
    id: track
    visible: card.drive.mounted && card.drive.size > 0
    width: parent.width
    height: Style.space(8)
    radius: height / 2
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

    Rectangle {
      width: Math.max(height, track.width * Math.min(100, card.drive.pct) / 100)
      height: parent.height
      radius: parent.radius
      color: card.drive.pct >= card.widget.fullWarnPct ? Color.urgent : Color.accent
    }
  }

  // Activity: device writes, kernel write cache, rclone uploads.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: text !== ""
    text: {
      if (card.writing)
        return "\u{f0cb6}  Writing… " + Model.humanBytes(card.activity.rate) + "/s — wait before unplugging"
      if (card.drive.pending > 0)
        return "\u{f0167}  Uploading " + card.drive.pending + " file" + (card.drive.pending === 1 ? "" : "s") + "…"
      if (card.drive.pending === 0)
        return "\u{f0160}  Synced"
      return ""
    }
    color: card.writing || card.drive.pending > 0 ? Color.accent : card.muted
    font.family: card.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: card.drive.mounted && card.drive.removable && !card.writing
      && card.widget.cached >= 8 * 1024 * 1024
    text: Model.humanBytes(card.widget.cached) + " system-wide not yet flushed to disk — Eject writes it out first"
    color: card.muted
    font.family: card.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Busy: something still has files open on the drive.
  Column {
    visible: card.busy !== null
    width: parent.width
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: "\u{f0026}  Busy — " + (card.busy ? card.busy.message : "")
      color: Color.urgent
      font.family: card.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      spacing: Style.space(6)

      Button {
        iconText: "\u{f0450}"
        text: "Retry"
        bordered: true
        foreground: Color.popups.text
        onClicked: card.widget.eject(card.drive, false)
      }

      Button {
        visible: !!(card.busy && card.busy.procs && card.busy.procs.length > 0)
        iconText: "\u{f0156}"
        text: "Close apps & eject"
        bordered: true
        foreground: Color.urgent
        onClicked: card.widget.eject(card.drive, true)
      }
    }
  }

  // [Open] [Eject] [Info]  /  [Mount] [Info]  /  [Unlock] [Info]
  Row {
    spacing: Style.space(6)

    Button {
      visible: card.drive.mounted
      iconText: "\u{f0770}"
      text: "Open"
      bordered: true
      foreground: Color.popups.text
      onClicked: { card.dismiss(); card.widget.open(card.drive) }
    }

    Button {
      visible: card.drive.mounted && !!card.drive.eject
      iconText: "\u{f01ea}"
      text: card.drive.removable ? "Eject" : "Unmount"
      bordered: true
      foreground: Color.popups.text
      onClicked: card.widget.eject(card.drive, false)
    }

    Button {
      visible: !card.drive.mounted && !card.drive.locked
      iconText: "\u{f104b}"
      text: "Mount"
      bordered: true
      foreground: Color.popups.text
      onClicked: card.widget.mount(card.drive)
    }

    Button {
      visible: card.drive.locked
      iconText: "\u{f0306}"
      text: "Unlock"
      bordered: true
      foreground: Color.popups.text
      onClicked: { card.dismiss(); card.widget.unlock(card.drive) }
    }

    Button {
      iconText: "\u{f02fd}"
      text: "Info"
      bordered: true
      selected: card.infoOpen
      foreground: Color.popups.text
      onClicked: card.widget.toggleInfo(card.drive)
    }
  }

  // The nerdy bits.
  Rectangle {
    visible: card.infoOpen
    width: parent.width
    height: infoGrid.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)

    Column {
      id: infoGrid
      x: Style.space(8)
      y: Style.space(8)
      width: parent.width - Style.space(16)
      spacing: Style.space(3)

      Repeater {
        model: Model.infoRows(card.drive)
        delegate: Row {
          required property var modelData
          width: infoGrid.width
          spacing: Style.space(10)

          Text {
            id: infoLabel
            textFormat: Text.PlainText
            text: modelData[0]
            color: card.muted
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
            width: Style.space(78)
          }

          Text {
            textFormat: Text.PlainText
            text: modelData[1]
            color: Color.popups.text
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
            width: parent.width - infoLabel.width - parent.spacing
            elide: Text.ElideMiddle
          }
        }
      }
    }
  }

  Button {
    visible: card.infoOpen && card.drive.encrypted && !card.drive.locked && card.drive.eject === "udisks"
    iconText: "\u{f033e}"
    text: "Lock"
    bordered: true
    foreground: Color.popups.text
    onClicked: card.widget.lock(card.drive)
  }
}
