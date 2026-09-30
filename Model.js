// Pure helpers for the Drives bar widget. Imported from BarWidget.qml as
// `import "Model.js" as Model`, and ES5-only so the same file runs under node.

var DEFAULT_ICONS = {
  thumb: "\u{f129e}",     // md-usb_flash_drive
  external: "\u{f02ca}",  // md-harddisk
  internal: "\uf0a0",     // fa-hdd
  sd: "\u{f07dc}",        // md-sd
  optical: "\u{f05ee}",   // md-disc
  image: "\u{f0a23}",     // md-zip_disk
  network: "\u{f048d}",   // md-server_network
  gdrive: "\u{f02b6}",    // md-google_drive
  onedrive: "\u{f03ca}",  // md-microsoft_onedrive
  dropbox: "\u{f01e3}",   // md-dropbox
  cloud: "\u{f015f}"      // md-cloud
}

var KIND_NAMES = {
  thumb: "Thumb drive",
  external: "External drive",
  internal: "Internal drive",
  sd: "SD card",
  optical: "Disc",
  image: "Disk image",
  network: "Network share",
  gdrive: "Google Drive",
  onedrive: "OneDrive",
  dropbox: "Dropbox",
  cloud: "Cloud drive"
}

// `icons` maps kind -> glyph (from the widget settings); blanks fall back.
function kindIcon(drive, icons) {
  var kind = drive && drive.kind ? drive.kind : "internal"
  var custom = icons ? icons[kind] : ""
  if (custom) return String(custom)
  return DEFAULT_ICONS[kind] || DEFAULT_ICONS.internal
}

function kindName(drive) {
  return KIND_NAMES[drive && drive.kind] || "Drive"
}

function humanBytes(n) {
  n = Number(n) || 0
  var units = ["B", "K", "M", "G", "T", "P"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + units[i]
}

// Plain text; the bar tooltip renders PlainText, newlines included.
function tooltip(drive) {
  if (!drive) return ""
  var lines = [drive.label || drive.name || drive.path || "Drive", drive.mountpoint || ""]
  var usage = drive.size > 0
    ? humanBytes(drive.used) + " / " + humanBytes(drive.size) + " (" + drive.pct + "%)"
    : ""
  var detail = [kindName(drive), usage, drive.fstype].filter(function(s) { return !!s }).join(" · ")
  lines.push(detail)
  lines.push(drive.eject
    ? "Click to open · right-click to " + (drive.removable ? "eject" : "unmount")
    : "Click to open")
  return lines.filter(function(s) { return !!s }).join("\n")
}

// "14.5G / 116G  13%", or "" when the size is unknown (gvfs cloud mounts).
function usageText(drive) {
  if (!drive || !(drive.size > 0)) return ""
  return humanBytes(drive.used) + " / " + humanBytes(drive.size) + "  " + drive.pct + "%"
}

// 124584722432 -> "124,584,722,432" (QML's toLocaleString goes exponential).
function groupDigits(n) {
  return String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// [label, value] rows for the Info panel; empty values are dropped.
function infoRows(drive) {
  if (!drive) return []
  var fs = [drive.fstype, drive.fsver].filter(function(s) { return !!s }).join(" ")
  var model = [drive.vendor, drive.model].filter(function(s) { return !!s }).join(" ")
  var device = drive.path && drive.disk && drive.disk !== drive.path
    ? drive.path + " on " + drive.disk : drive.path
  var crypt = ""
  if (drive.encrypted) crypt = "LUKS · " + (drive.locked ? "locked" : "unlocked") +
    (drive.luksPath && drive.luksPath !== drive.path ? " (" + drive.luksPath + ")" : "")
  var rows = [
    ["Type", kindName(drive)],
    ["Device", device],
    ["Filesystem", fs],
    ["UUID", drive.uuid],
    ["Model", model],
    ["Serial", drive.serial],
    ["Connection", drive.connection],
    ["Encryption", crypt],
    ["Access", drive.mounted ? (drive.readOnly ? "Read-only" : "Read-write") : ""],
    ["Size", drive.size > 0 ? humanBytes(drive.size) + " (" + groupDigits(drive.size) + " bytes)" : ""],
    ["Mounted at", drive.mounted ? drive.mountpoint : ""]
  ]
  return rows.filter(function(r) { return !!r[1] })
}

// Stable identity for Repeater diffing: same mount, same button.
function sameDrives(a, b) {
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (tooltip(a[i]) !== tooltip(b[i])) return false
  }
  return true
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_ICONS: DEFAULT_ICONS,
    KIND_NAMES: KIND_NAMES,
    kindIcon: kindIcon,
    kindName: kindName,
    humanBytes: humanBytes,
    tooltip: tooltip,
    usageText: usageText,
    infoRows: infoRows,
    groupDigits: groupDigits,
    sameDrives: sameDrives
  }
}
