pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Always-on UniFi Protect air quality readout.
Panel {
  id: root
  readonly property string pluginId: "lane.unifi-air"
  moduleName: pluginId
  ipcTarget: pluginId
  manageIpc: false

  property var sensor: null
  property var sensors: []
  property string lastError: ""
  property bool needsLogin: false
  property bool initialized: false
  property bool refreshing: false
  property real lastUpdatedAt: 0
  property real nowMs: Date.now()

  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property bool showCo2: boolSetting("showCo2", true)
  readonly property bool fahrenheit: boolSetting("fahrenheit", true)
  readonly property bool compact: boolSetting("compact", false)
  readonly property int refreshIntervalMs: intSetting("refreshSec", 30, 10, 300) * 1000
  readonly property string wantedName: String(setting("sensorName", "") || "")

  readonly property string backendPath:
    Qt.resolvedUrl("unifi-air-fetch").toString().replace(/^file:\/\//, "")
  readonly property string loginPath:
    Qt.resolvedUrl("unifi-air-login").toString().replace(/^file:\/\//, "")

  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.75)

  function metricValue(obj) {
    if (!obj || obj.value === undefined || obj.value === null) return null
    var n = Number(obj.value)
    return isFinite(n) ? n : null
  }

  function metricStatus(obj) {
    return obj && obj.status ? String(obj.status) : ""
  }

  readonly property var aqi: sensor ? metricValue(sensor.aqi) : null
  readonly property var co2: sensor ? metricValue(sensor.co2) : null
  readonly property string aqiStatus: sensor ? metricStatus(sensor.aqi) : ""
  readonly property string co2Status: sensor ? metricStatus(sensor.co2) : ""

  function bandFromAqi(n) {
    if (n === null) return "unknown"
    if (n <= 50) return "good"
    if (n <= 100) return "moderate"
    if (n <= 150) return "poor"
    return "bad"
  }

  function bandFromCo2(n) {
    if (n === null) return "unknown"
    if (n < 1000) return "good"
    if (n < 1500) return "moderate"
    return "poor"
  }

  readonly property string airBand: {
    var a = bandFromAqi(aqi)
    var c = bandFromCo2(co2)
    if (a === "bad" || c === "poor") return "bad"
    if (a === "poor" || c === "moderate") return "poor"
    if (a === "moderate") return "moderate"
    if (a === "good" && c === "good") return "good"
    return "unknown"
  }

  readonly property bool airAlert: airBand === "poor" || airBand === "bad"

  readonly property string barLabel: {
    if (needsLogin) return "Air · setup"
    if (lastError !== "" && !sensor) return "Air · !"
    if (aqi === null && co2 === null) return initialized ? "Air · —" : "Air"
    var aqiText = aqi === null ? "—" : String(Math.round(aqi))
    if (!showCo2 || co2 === null)
      return compact ? aqiText : "AQI " + aqiText
    var co2Text = String(Math.round(co2))
    return compact ? (aqiText + " · " + co2Text) : ("AQI " + aqiText + "  " + co2Text + "ppm")
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "UniFi Air: not signed in"
    if (lastError !== "") return "UniFi Air: " + lastError
    if (!sensor) return "UniFi Air: loading…"
    var parts = [sensor.name || "Air Quality"]
    if (aqi !== null) parts.push("AQI " + Math.round(aqi))
    if (co2 !== null) parts.push(Math.round(co2) + " ppm CO₂")
    if (sensor && sensor.temperature)
      parts.push(root.formatTemp(sensor.temperature) + " " + (root.fahrenheit ? "°F" : "°C"))
    return parts.join(" · ")
  }

  function formatMetric(obj, digits) {
    var n = metricValue(obj)
    if (n === null) return "—"
    if (digits === 0) return String(Math.round(n))
    return n.toFixed(digits)
  }

  function formatTemp(obj) {
    var c = metricValue(obj)
    if (c === null) return "—"
    if (!fahrenheit) return c.toFixed(1)
    return ((c * 9 / 5) + 32).toFixed(1)
  }

  function signIn() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(loginPath))
    close()
  }

  function refresh() {
    if (fetchProcess.running) return
    refreshing = true
    var cmd = [backendPath]
    if (wantedName !== "")
      cmd.push("--sensor-name=" + wantedName)
    fetchProcess.command = cmd
    fetchProcess.running = true
  }

  function applyOutput(text) {
    refreshing = false
    initialized = true
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The air helper returned something unreadable"
      return
    }
    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      needsLogin = parsed.needsLogin === true
      return
    }
    lastError = ""
    needsLogin = false
    sensors = (parsed && parsed.sensors) ? parsed.sensors : []
    sensor = (parsed && parsed.sensor) ? parsed.sensor : null
    lastUpdatedAt = Date.now()
  }

  IpcHandler {
    target: root.pluginId
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: fetchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }
    onExited: function() { root.refreshing = false }
  }

  Timer {
    interval: root.refreshIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    tooltipText: root.tooltipSummary
    dimmed: root.needsLogin || (root.lastError !== "" && !root.sensor)
    active: root.airAlert
    activeColor: Color.urgent
    horizontalMargin: 8.75
    verticalPadding: 8.75
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: airPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: airPanel.fittedContentWidth(Style.space(360))
    contentHeight: airPanel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      property string heldKey: ""
      Keys.onReleased: function(event) { if (!event.isAutoRepeat) keyCatcher.heldKey = "" }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (heldKey === key) return
        heldKey = key
        if (key === "r") root.refresh()
        if (key === "s") root.signIn()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          textFormat: Text.PlainText
          width: parent.width
          text: root.sensor && root.sensor.name ? "UniFi Air · " + root.sensor.name : "UniFi Air"
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsLogin

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== "" ? root.lastError : "No Protect login for the air quality sensor."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Use a local UniFi OS username and password (option 1). The Network API key cannot read AQI/CO2 from current Protect."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Set up"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.signIn()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !root.needsLogin && root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.initialized && !root.needsLogin && root.lastError === ""
          text: "Loading…"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.sensor !== null && !root.needsLogin

          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(12)
            rowSpacing: Style.space(6)

            Repeater {
              model: [
                { label: "AQI", value: root.formatMetric(root.sensor && root.sensor.aqi, 0), unit: "", status: root.aqiStatus },
                { label: "CO₂", value: root.formatMetric(root.sensor && root.sensor.co2, 0), unit: "ppm", status: root.co2Status },
                { label: "Temp", value: root.formatTemp(root.sensor && root.sensor.temperature), unit: root.fahrenheit ? "°F" : "°C", status: root.sensor ? root.metricStatus(root.sensor.temperature) : "" },
                { label: "Humidity", value: root.formatMetric(root.sensor && root.sensor.humidity, 0), unit: "%", status: root.sensor ? root.metricStatus(root.sensor.humidity) : "" },
                { label: "PM2.5", value: root.formatMetric(root.sensor && root.sensor.pm25, 1), unit: "µg/m³", status: root.sensor ? root.metricStatus(root.sensor.pm25) : "" },
                { label: "PM10", value: root.formatMetric(root.sensor && root.sensor.pm10, 1), unit: "µg/m³", status: root.sensor ? root.metricStatus(root.sensor.pm10) : "" },
                { label: "PM1", value: root.formatMetric(root.sensor && root.sensor.pm1, 1), unit: "µg/m³", status: root.sensor ? root.metricStatus(root.sensor.pm1) : "" },
                { label: "VOC", value: root.formatMetric(root.sensor && root.sensor.voc, 0), unit: "", status: root.sensor ? root.metricStatus(root.sensor.voc) : "" },
                { label: "TVOC", value: root.formatMetric(root.sensor && root.sensor.tvoc, 0), unit: "", status: root.sensor ? root.metricStatus(root.sensor.tvoc) : "" },
                { label: "Vape", value: root.formatMetric(root.sensor && root.sensor.vape, 0), unit: "", status: root.sensor ? root.metricStatus(root.sensor.vape) : "" }
              ]

              Column {
                id: metric
                required property var modelData
                width: (parent.width - Style.space(12)) / 2
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: metric.modelData.label
                  color: root.detailColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: metric.modelData.value + (metric.modelData.unit ? " " + metric.modelData.unit : "")
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: metric.modelData.label === "AQI" || metric.modelData.label === "CO₂"
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.sensor && root.sensor.connected === false
            text: "Sensor reports disconnected"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.initialized && !root.needsLogin
          text: root.refreshing ? "Refreshing…" : "R refresh · click the bar to close"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
