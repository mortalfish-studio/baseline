import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A new track: its cover, title and "artist · source" for a few seconds,
// near the top of the screen, in the style of Omarchy's own popup. Omarchy's popup only
// takes an icon and words, so Baseline draws this one itself.
Item {
  id: root
  property bool opened: false
  property string title: ""
  property string artist: ""
  property string art: ""

  readonly property int pad: Style.space(14)
  readonly property int cover: Style.space(64)

  function show(t, a, cover) {
    title = t
    artist = a
    art = cover
    opened = true
    hideTimer.restart()
  }

  Timer { id: hideTimer; interval: 3500; onTriggered: root.opened = false }

  OverlayWindow {
    id: panel
    shown: root.opened
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "baseline-track"
    // Only to look at: clicks go through to whatever is underneath.
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + row.implicitWidth + root.pad + card.borderRight
      height: card.borderTop + root.pad + root.cover + root.pad + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      // Near the top, clear of chat boxes and the bar along the bottom.
      anchors.top: parent.top
      anchors.topMargin: Style.space(40)
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: Style.duration(root.opened ? 180 : 120); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      RowLayout {
        id: row
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        height: root.cover
        spacing: Style.space(14)

        Rectangle {
          Layout.preferredWidth: root.cover
          Layout.preferredHeight: root.cover
          color: "black"
          radius: Style.cornerRadius > 0 ? Style.space(3) : 0
          clip: true
          SizedImage {
            anchors.fill: parent
            crop: true
            url: root.art
            visible: url !== ""
          }
          Text {
            anchors.centerIn: parent
            visible: root.art === ""
            text: "󰎆"
            textFormat: Text.PlainText
            font.family: "Iosevka Nerd Font Propo"
            font.pixelSize: Style.font.icon * 1.4
            color: Commons.Color.accent
          }
        }

        ColumnLayout {
          spacing: Style.space(2)
          Layout.maximumWidth: Style.space(420)
          Text {
            Layout.maximumWidth: Style.space(420)
            text: root.title
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            Layout.maximumWidth: Style.space(420)
            visible: root.artist !== ""
            text: root.artist
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            opacity: 0.8
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }
}
