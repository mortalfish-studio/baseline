import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The Baseline card, in the hover card's dress: brand line and mode plate,
// then a tab rail lit amber under the open tab.
Column {
  id: root
  property var host: null
  spacing: Style.space(10)

  readonly property color amber: Commons.Color.accent
  readonly property color teal: host ? host.themeCyan : Commons.Color.foreground
  readonly property var st: host ? host.afterState : null

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  // ---- NEON ROSE (the look) ............ [ DAY ]
  Column {
    width: parent.width
    spacing: Style.space(4)
    RowLayout {
      width: parent.width
      spacing: Style.space(8)
      Label {
        Layout.fillWidth: true
        text: {
          const look = root.st && root.st.looks ? root.st.looks.find(l => l.id === root.st.look) : null
          return look ? strings.t("hover.brandLook").arg(look.name.toUpperCase()) : strings.t("hover.brand")
        }
        font.pixelSize: Style.font.caption
        font.letterSpacing: Style.space(3)
        color: root.amber
      }
      Label {
        visible: !!root.host && root.host.afterBusy
        text: "󰔟"
        color: root.teal
        RotationAnimation on rotation { running: !!root.host && root.host.afterBusy && !Style.reduceMotion; loops: Animation.Infinite; from: 0; to: 360; duration: 1200 }
      }
      Rectangle {
        visible: modeLabel.text !== ""
        implicitWidth: modeLabel.implicitWidth + Style.space(12)
        implicitHeight: modeLabel.implicitHeight + Style.space(4)
        color: "transparent"
        border.width: 1
        border.color: root.amber
        radius: Style.cornerRadius > 0 ? Style.space(3) : 0
        Label {
          id: modeLabel
          anchors.centerIn: parent
          text: root.st && root.st.mode !== "other" ? strings.t("mode." + root.st.mode).toUpperCase() : ""
          font.pixelSize: Style.font.caption
          font.letterSpacing: Style.space(2)
          color: root.amber
        }
      }
    }
    Label {
      text: (root.host && root.host.offBaseline ? strings.t("baseline.glyphOff") : strings.t("baseline.glyphWithin")) + "  "
        + strings.t(root.host && root.host.offBaseline ? "baseline.headerOff" : "baseline.headerWithin").toUpperCase()
      font.pixelSize: Style.font.subtitle
      font.bold: true
      font.letterSpacing: Style.space(2)
      color: root.host && root.host.offBaseline ? Commons.Color.urgent : root.teal
    }
  }

  // ---- Tab rail
  Item {
    width: parent.width
    height: tabs.implicitHeight + Style.space(6)

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.amber }
        GradientStop { position: 1; color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.12) }
      }
    }

    RowLayout {
      id: tabs
      width: parent.width
      spacing: 0
      Repeater {
        model: [
          { value: "system", icon: "󰍛" },
          { value: "player", icon: "󰎆" },
          { value: "status", icon: "󰂚" },
          { value: "wallpapers", icon: "󰸉" },
          { value: "theme", icon: "󰏘" },
          { value: "setup", icon: "󰒓" }
        ]
        delegate: Item {
          id: tab
          required property var modelData
          readonly property bool on: root.host && root.host.tab === modelData.value
          implicitHeight: Style.font.body * 1.5 + Style.space(14)

          // The open tab spells its name; the rest share the row as large icons.
          Layout.fillWidth: !tab.on
          Layout.preferredWidth: tab.on ? tabContent.implicitWidth + Style.space(24) : Style.space(44)
          Row {
            id: tabContent
            anchors.centerIn: parent
            spacing: Style.space(6)
            Label {
              id: tabIcon
              anchors.verticalCenter: parent.verticalCenter
              text: tab.modelData.icon
              // The Propo face draws glyphs at full width; the Mono one squeezes them.
              font.family: "Iosevka Nerd Font Propo"
              font.pixelSize: Style.font.iconLarge
              color: tab.on ? root.amber : tabHover.hovered ? root.teal : Commons.Color.popups.text
              opacity: tab.on || tabHover.hovered ? 1 : 0.75
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              visible: tab.on
              text: strings.t("tab." + tab.modelData.value).toUpperCase()
              font.pixelSize: Style.font.caption
              font.letterSpacing: Style.space(2)
              font.bold: true
              color: root.amber
            }
          }
          // The lit rail under the open tab.
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: -Style.space(6)
            anchors.horizontalCenter: parent.horizontalCenter
            width: tab.on ? tabContent.implicitWidth + Style.space(8) : 0
            height: Style.space(2)
            color: root.amber
            Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          }
          HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
          PanelToolTip { visible: tabHover.hovered && !tab.on; text: strings.t("tab." + tab.modelData.value) }
          TapHandler {
            onTapped: {
              root.host.chooseTab(tab.modelData.value)
              if (tab.modelData.value === "system") root.host.refresh()
            }
          }
        }
      }
    }
  }

  // Tall tabs scroll rather than run off screen. A fade on the edge that has
  // more, and a thin thumb, show there is more to see.
  Item {
    width: parent.width
    height: Math.min(tabLoader.implicitHeight + Style.space(4), Style.space(680))

    Flickable {
      id: scroller
      anchors.fill: parent
      contentHeight: tabLoader.implicitHeight + Style.space(4)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Loader {
        id: tabLoader
        y: Style.space(4)
        width: parent.width
        sourceComponent: {
          switch (root.host ? root.host.tab : "system") {
            case "player": return playerTab
            case "status": return statusTab
            case "wallpapers": return wallpapersTab
            case "theme": return themeTab
            case "setup": return setupTab
            default: return systemTab
          }
        }
        // A new tab starts at its top.
        onSourceComponentChanged: scroller.contentY = 0
      }
      Connections {
        target: root.host
        function onScrollRequestChanged() {
          scroller.contentY = Math.max(0, (scroller.contentHeight - scroller.height) * root.host.scrollRequest)
        }
      }
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: Style.space(28)
      visible: scroller.interactive && !scroller.atYBeginning
      gradient: Gradient {
        GradientStop { position: 0; color: Commons.Color.popups.background }
        GradientStop { position: 1; color: Util.alpha(Commons.Color.popups.background, 0) }
      }
    }
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: Style.space(36)
      visible: scroller.interactive && !scroller.atYEnd
      gradient: Gradient {
        GradientStop { position: 0; color: Util.alpha(Commons.Color.popups.background, 0) }
        GradientStop { position: 1; color: Commons.Color.popups.background }
      }
    }
    Rectangle {
      visible: scroller.interactive
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(8)
      width: Style.space(2)
      radius: width / 2
      color: Commons.Color.accent
      opacity: scroller.moving ? 0.7 : 0.3
      height: Math.max(Style.space(24), parent.height * scroller.visibleArea.heightRatio)
      y: scroller.visibleArea.yPosition * (parent.height - height) / Math.max(0.0001, 1 - scroller.visibleArea.heightRatio)
      Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
    }
  }

  Component { id: systemTab; SystemTab { host: root.host } }
  Component { id: playerTab; PlayerTab { host: root.host } }
  Component { id: statusTab; StatusTab { host: root.host } }
  Component { id: wallpapersTab; WallpapersTab { host: root.host } }
  Component { id: themeTab; ThemeTab { host: root.host } }
  Component { id: setupTab; SetupTab { host: root.host } }
}
