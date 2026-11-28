import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons

// A song's whole waveform (Beatport draws one for every track), as a deck in
// DJ software shows it: what's played lit in the song's colour, what's to
// come dim, a band where the mix runs in this song, and the playhead.
Item {
  id: strip
  property string source: ""
  property real progress: 0             // 0-1 through the song
  property real litFrom: 0              // 0-1: where it was heard from (a mix brought it in later)
  property color tone: Commons.Color.accent
  property color ink: Commons.Color.popups.text
  property real bandFrom: -1            // 0-1: the mix in this song
  property real bandTo: -1
  property bool bandFaint: false        // only planned, not under way
  property real mark: -1                // 0-1: the takeover
  property bool playhead: true
  readonly property bool ready: wave.status === Image.Ready
  implicitHeight: 40

  // The waveform, as a mask: the colours come from what's drawn through it.
  Image {
    id: wave
    anchors.fill: parent
    source: strip.source
    sourceSize: Qt.size(1500, 250)
    fillMode: Image.Stretch
    smooth: true
    asynchronous: true
    visible: false
    layer.enabled: true
  }
  // To come: the whole song, faint.
  Rectangle {
    id: faint
    anchors.fill: parent
    visible: false
    layer.enabled: true
    color: Qt.rgba(strip.ink.r, strip.ink.g, strip.ink.b, 0.3)
  }
  MultiEffect {
    anchors.fill: parent
    visible: strip.ready
    source: faint
    maskEnabled: true
    maskSource: wave
    maskThresholdMin: 0.5
    maskSpreadAtMin: 0.05
  }
  // Played: lit, fading from the song's colour as it goes.
  Item {
    anchors.top: parent.top; anchors.bottom: parent.bottom
    readonly property real from: Math.max(0, Math.min(strip.progress, strip.litFrom))
    x: parent.width * from
    width: parent.width * Math.max(0, Math.min(1, strip.progress) - from)
    clip: true
    visible: strip.ready
    Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
    Rectangle {
      id: lit
      width: strip.width; height: strip.height
      visible: false
      layer.enabled: true
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: Qt.rgba(strip.tone.r, strip.tone.g, strip.tone.b, 0.55) }
        GradientStop { position: 1; color: strip.tone }
      }
    }
    MultiEffect {
      x: -parent.x
      width: strip.width; height: strip.height
      source: lit
      maskEnabled: true
      maskSource: wave
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.05
    }
  }
  // Where the mix runs in this song, and where the new one takes over.
  Rectangle {
    visible: strip.bandFrom >= 0 && strip.bandTo > strip.bandFrom
    x: strip.width * strip.bandFrom
    width: Math.max(2, strip.width * (strip.bandTo - strip.bandFrom))
    height: strip.height
    radius: 3
    color: Qt.rgba(strip.tone.r, strip.tone.g, strip.tone.b, strip.bandFaint ? 0.06 : 0.13)
  }
  Rectangle {
    visible: strip.mark >= 0
    x: strip.width * strip.mark - 1
    width: 2; height: strip.height
    color: strip.tone
    opacity: strip.bandFaint ? 0.5 : 0.8
  }
  // The playhead.
  Rectangle {
    visible: strip.playhead
    x: strip.width * Math.max(0, Math.min(1, strip.progress)) - 1
    y: -3
    width: 2; height: strip.height + 6
    radius: 1
    color: strip.ink
    Behavior on x { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
  }
}
