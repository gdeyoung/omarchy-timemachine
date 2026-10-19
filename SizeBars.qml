import QtQuick
import qs.Commons
import qs.Ui

// SizeBars — compact bar chart for snapshot sizes (MB). Chart idiom adapted
// from gdeyoung.sysmon HistBars (MIT, forked chain). Newest bar highlighted;
// zero-height safe with empty input.
Rectangle {
  id: chart

  property var values: []          // numbers, oldest → newest
  property color barColor: "#7aa2f7"
  property color lastColor: "#3fb950"
  property real barHeight: 52

  implicitHeight: barHeight
  color: "transparent"

  readonly property real vMax: {
    var m = 0
    for (var i = 0; i < values.length; i++) m = Math.max(m, Number(values[i]) || 0)
    return m > 0 ? m : 1
  }
  readonly property int n: values.length
  readonly property real gap: n > 1 ? 3 : 0
  readonly property real barW: n > 0 ? (width - gap * (n - 1)) / n : width

  // explicit positioning (no Row): positioners forbid anchored children,
  // and bars must grow up from the baseline
  Repeater {
    model: chart.n

    Rectangle {
      required property int index
      readonly property real v: Number(chart.values[index]) || 0
      x: index * (chart.barW + chart.gap)
      width: chart.barW
      height: Math.max(2, chart.barHeight * v / chart.vMax)
      radius: 2
      color: index === chart.n - 1 ? chart.lastColor : chart.barColor
      opacity: 0.45 + 0.55 * (index + 1) / chart.n
      anchors.bottom: parent.bottom
    }
  }

  // baseline
  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: 1
    color: Qt.alpha(Color.foreground, 0.15)
  }
}
