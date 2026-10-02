import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "robertstevenson.omaovercast"
  ipcTarget: "robertstevenson.omaovercast"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string backend: String(Qt.resolvedUrl("bin/overcast")).replace(/^file:\/\//, "")
  readonly property string loginScript: String(Qt.resolvedUrl("bin/overcast-login")).replace(/^file:\/\//, "")
  readonly property bool showArtwork: setting("showArtwork", false) === true
  readonly property color fg: bar ? bar.foreground : Color.foreground
  // Overcast's orange (as used by its web player), or the theme's accent.
  readonly property bool themeColors: setting("accentColor", "Overcast") === "Theme"
  readonly property string olderEpisodes: String(setting("olderEpisodes", "4"))
  // Re-list the open podcast when the count changes.
  onOlderEpisodesChanged: if (view === "episodes" && currentPodcast) openPodcast(currentPodcast)
  readonly property color brand: themeColors ? Color.accent : "#fc7e0f"
  readonly property string sansFamily: "Noto Sans"
  readonly property string monoFamily: bar ? bar.fontFamily : "monospace"
  // Overcast's speed ids; 0 means 1x.
  readonly property var speedOptions: [
    { id: 750, label: "0.75×" }, { id: 0, label: "1×" }, { id: 1250, label: "1.25×" }, { id: 1500, label: "1.5×" },
    { id: 1750, label: "1.75×" }, { id: 2000, label: "2×" }, { id: 2500, label: "2.5×" }, { id: 3000, label: "3×" }
  ]
  property bool speedMenuOpen: false
  property bool settingsOpen: false
  readonly property bool needsLogin: error === "not_logged_in"
  // The sign-in page replaces whatever was showing.
  onNeedsLoginChanged: if (needsLogin) view = "podcasts"
  readonly property string loginCommand: loginScript.replace(Quickshell.env("HOME"), "~")
  onViewChanged: speedMenuOpen = false

  // "podcasts", "episodes" or "playing"
  property string view: "podcasts"
  property var podcastList: []
  property var episodeList: []
  property var currentPodcast: null
  readonly property bool loading: podcastsQuery.running || episodesQuery.running
  property string error: ""
  property var nowPlaying: ({ active: false })
  // Playback takes a moment to start; don't treat the gap as "stopped".
  property real playRequestedAt: 0

  readonly property string tooltip: nowPlaying.active
    ? (nowPlaying.paused ? "Paused: " : "Playing: ") + nowPlaying.title
    : "Overcast"

  function open() { openFromHotkey() }

  function openFromHotkey() {
    root.controller.show()
    if (podcastList.length === 0) loadPodcasts()
    if (nowPlaying.active && !needsLogin) view = "playing"
    pollStatus()
  }

  function close() {
    settingsOpen = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // --- Backend calls ----------------------------------------------------------

  function loadPodcasts() {
    podcastsQuery.request(["podcasts"], function(data) { root.podcastList = data })
  }

  function openPodcast(podcast) {
    currentPodcast = podcast
    episodeList = []
    view = "episodes"
    episodesQuery.request(["episodes", podcast.path, olderEpisodes], function(data) { root.episodeList = data })
  }

  function back() {
    view = "podcasts"
    currentPodcast = null
  }

  function showPlaying() {
    if (nowPlaying.active && !needsLogin) view = "playing"
  }

  // Breadcrumb from the now-playing view back to that episode's podcast.
  function openPlayingPodcast() {
    var path = nowPlaying.podcastPath || ""
    for (var i = 0; !path && i < podcastList.length; i++)
      if (podcastList[i].title === nowPlaying.podcast) path = podcastList[i].path
    if (path) openPodcast({ title: nowPlaying.podcast, path: path })
    else back()
  }

  function applyStatus(data) {
    if (!data.active && Date.now() - playRequestedAt < 8000) return
    // Playback ended: leave the now-playing view for its podcast.
    if (nowPlaying.active && !data.active && view === "playing") openPlayingPodcast()
    nowPlaying = data
  }

  function refresh() {
    if (view === "episodes" && currentPodcast) openPodcast(currentPodcast)
    else loadPodcasts()
  }

  function action(args) {
    Quickshell.execDetached([backend].concat(args))
    statusDelay.restart()
  }

  function play(episode) {
    playRequestedAt = Date.now()
    nowPlaying = {
      active: true, title: episode.title, path: episode.path,
      podcast: currentPodcast ? currentPodcast.title : "",
      podcastPath: currentPodcast ? currentPodcast.path : "",
      art: "", position: 0, duration: 0, paused: false
    }
    view = "playing"
    action(["play", episode.path])
  }
  function togglePause() { if (nowPlaying.active) action(["toggle"]) }
  function seek(seconds) { action(["seek", String(seconds)]) }

  function setSpeed(speedId) {
    speedMenuOpen = false
    nowPlaying = Object.assign({}, nowPlaying, { speedId: speedId })
    action(["speed", String(speedId)])
  }

  function speedLabel(speedId) {
    for (var i = 0; i < speedOptions.length; i++)
      if (speedOptions[i].id === speedId) return speedOptions[i].label
    return speedId ? (speedId / 1000) + "×" : "1×"
  }

  function pollStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  // Settings live on this widget's entry in shell.json. Applied locally first
  // so controls respond on the click; the entry is merged from the current
  // settings because updateEntryInline replaces it whole.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    else if (root.bar)
      for (var k in values) root.bar.run("omarchy bar set robertstevenson.omaovercast " + k + " " + root.bar.shellQuote(JSON.stringify(values[k])) + " --json")
  }

  function showSettings(open) {
    settingsOpen = open === true
    speedMenuOpen = false
  }

  function openOvercastSite() {
    Quickshell.execDetached(["omarchy-launch-browser", "https://overcast.fm"])
    root.close()
  }

  function login() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + bar.shellQuote(bar.shellQuote(loginScript)))
    close()
  }

  function logout() {
    if (!logoutProc.running) logoutProc.running = true
  }

  function copyLoginCommand() {
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "copy", loginScript])
    loginCopiedTimer.restart()
  }

  function clock(seconds) {
    var s = Math.max(0, Math.floor(seconds || 0))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
    var mm = (h > 0 && m < 10 ? "0" : "") + m
    return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" : "") + sec
  }

  // One backend call at a time per list. A request made while one is running
  // waits for it, and the superseded result is dropped rather than applied.
  component Query: Process {
    id: q
    property var callback: null
    property var pending: null
    running: false
    command: []
    stdout: StdioCollector { id: qOut; waitForEnd: true }

    function request(args, callback) {
      root.error = ""
      if (running) {
        pending = { args: args, callback: callback }
        return
      }
      q.callback = callback
      command = [root.backend].concat(args)
      running = true
    }

    onExited: function(exitCode) {
      if (pending) {
        var next = pending
        pending = null
        Qt.callLater(function() { q.request(next.args, next.callback) })
        return
      }
      var data = null
      try { data = JSON.parse(String(qOut.text || "")) } catch (e) {}
      if (exitCode === 2) root.error = "not_logged_in"
      else if (exitCode !== 0 || data === null) root.error = (data && data.error) || "Couldn't reach Overcast"
      else if (callback) callback(data)
    }
  }

  Query { id: podcastsQuery }
  Query { id: episodesQuery }

  Process {
    id: logoutProc
    running: false
    command: [root.backend, "logout"]
    onExited: {
      root.podcastList = []
      root.episodeList = []
      root.currentPodcast = null
      root.nowPlaying = { active: false }
      root.view = "podcasts"
      root.settingsOpen = false
      root.error = "not_logged_in"
    }
  }

  // While the sign-in page is showing, keep checking so the panel recovers
  // on its own once the login in the terminal succeeds. With no cookie saved
  // this fails locally without contacting Overcast.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened && root.needsLogin
    onTriggered: if (!root.loading) root.loadPodcasts()
  }

  Timer {
    id: loginCopiedTimer
    interval: 1500
  }

  Process {
    id: statusProc
    running: false
    command: [root.backend, "status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      var data = null
      try { data = JSON.parse(String(statusOut.text || "")) } catch (e) {}
      if (data) root.applyStatus(data)
    }
  }

  // Fast while the panel is open and something is playing; slow otherwise so
  // the tooltip and middle-click stay accurate.
  Timer {
    interval: root.opened && root.nowPlaying.active ? 1000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollStatus()
  }

  Timer {
    id: statusDelay
    interval: 700
    onTriggered: root.pollStatus()
  }

  // --- UI ---------------------------------------------------------------------

  component LinkText: Text {
    id: link
    signal clicked()
    readonly property bool hovered: linkArea.containsMouse
    color: hovered ? root.brand : root.fg
    font.family: root.sansFamily
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    MouseArea {
      id: linkArea
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }

  // A Material Design icon from the Nerd Font Omarchy ships, in the accent color.
  component Glyph: Text {
    property int glyph: 0
    text: String.fromCodePoint(glyph)
    color: root.brand
    font.family: root.monoFamily
    font.pixelSize: Math.round(Math.min(width, height))
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  // A bare icon button, like the web player's: no chrome, shrinks when pressed.
  component IconButton: Item {
    id: iconButton
    property int glyph: 0
    property real iconScale: 0.9
    signal clicked()
    scale: iconArea.pressed ? 0.92 : 1
    opacity: iconArea.containsMouse ? 0.85 : 1
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }

    Glyph {
      anchors.centerIn: parent
      width: parent.width * iconButton.iconScale
      height: parent.height * iconButton.iconScale
      glyph: iconButton.glyph
    }

    MouseArea {
      id: iconArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: iconButton.clicked()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: root.needsLogin && !root.settingsOpen
      ? panel.fittedContentHeight(content.implicitHeight)
      : root.settingsOpen
      ? panel.fittedContentHeight(settingsPage.implicitHeight + (olderDropdown.popupOpen ? olderDropdown.popupRowHeight * 7 + Style.space(16) : 0))
      : root.view === "playing"
      ? panel.fittedContentHeight(header.height + headerSeparator.height + content.spacing * 2 + playingView.implicitHeight)
      : panel.fittedContentHeight(Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.settingsOpen) root.showSettings(false)
        else if (root.speedMenuOpen) root.speedMenuOpen = false
        else if (root.view === "episodes") root.back()
        else root.close()
      }
      onActivateRequested: if (root.view === "playing" && !root.settingsOpen) root.togglePause()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.fill: parent
        visible: !root.settingsOpen
        spacing: Style.space(10)

        // ---- Header
        Item {
          id: header
          width: parent.width
          height: Style.space(24)

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Glyph {
              visible: root.view === "podcasts"
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              height: width
              glyph: 0xF0994 // md-podcast
              scale: siteLinkArea.containsMouse ? 1.1 : 1
              Behavior on scale { NumberAnimation { duration: 80 } }
            }

            LinkText {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, header.width - headerActions.width - Style.space(40))
              elide: Text.ElideRight
              font.pixelSize: Style.font.title
              font.bold: true
              color: root.view === "podcasts" || hovered ? root.brand : root.fg
              font.underline: root.view === "podcasts" && siteLinkArea.containsMouse
              text: root.view === "playing" ? "‹  " + (root.nowPlaying.podcast || "Overcast")
                : root.view === "episodes" && root.currentPodcast ? "‹  " + root.currentPodcast.title
                : "Overcast"
              onClicked: {
                if (root.view === "playing") root.openPlayingPodcast()
                else if (root.view === "episodes") root.back()
                else root.openOvercastSite()
              }
            }
          }

          // On the podcast list, the logo and "Overcast" are one link to overcast.fm.
          MouseArea {
            id: siteLinkArea
            visible: root.view === "podcasts"
            x: titleRow.x - Style.space(4)
            y: titleRow.y - Style.space(4)
            width: titleRow.width + Style.space(8)
            height: titleRow.height + Style.space(8)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openOvercastSite()
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(14)

            LinkText {
              visible: root.view !== "playing" && root.nowPlaying.active === true && !root.needsLogin
              anchors.verticalCenter: parent.verticalCenter
              text: "▶ Now playing"
              color: root.brand
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              onClicked: root.showPlaying()
            }
            LinkText {
              visible: root.view !== "playing" && !root.needsLogin
              anchors.verticalCenter: parent.verticalCenter
              text: root.loading ? "…" : "↻"
              onClicked: root.refresh()
            }
            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒓"
              tooltipText: "Overcast settings"
              foreground: root.fg
              hoverColor: root.brand
              fontFamily: root.monoFamily
              onClicked: root.showSettings(true)
            }
          }
        }

        PanelSeparator {
          id: headerSeparator
          width: parent.width
          foreground: root.fg
        }

        // ---- Now playing
        Column {
          id: playingView
          visible: root.view === "playing" && !root.needsLogin
          width: parent.width
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          spacing: Style.space(14)

          Image {
            visible: root.showArtwork && source != ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(200)
            height: visible ? width : 0
            source: root.showArtwork ? (root.nowPlaying.art || "") : ""
            sourceSize.width: Style.space(400)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: root.nowPlaying.title || ""
            color: root.fg
            font.family: root.sansFamily
            font.pixelSize: Math.round(Style.font.title * 1.3)
            font.weight: Font.Bold
            textFormat: Text.PlainText
          }

          Column {
            width: parent.width
            spacing: Style.space(5)

            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.fg, 0.15)

              Rectangle {
                height: parent.height
                radius: parent.radius
                color: root.brand
                width: root.nowPlaying.duration > 0
                  ? parent.width * Math.min(1, root.nowPlaying.position / root.nowPlaying.duration) : 0
              }
            }

            Item {
              width: parent.width
              height: elapsed.implicitHeight

              Text {
                id: elapsed
                text: root.clock(root.nowPlaying.position)
                color: root.fg
                opacity: 0.55
                font.family: root.monoFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                anchors.right: parent.right
                text: "−" + root.clock(Math.max(0, root.nowPlaying.duration - root.nowPlaying.position))
                color: root.fg
                opacity: 0.55
                font.family: root.monoFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // Same proportions as the web player: three 15%-wide buttons,
          // seek buttons inset 12% from the edges.
          Item {
            width: parent.width
            height: width * 0.15

            IconButton {
              x: parent.width * 0.12
              width: parent.width * 0.15
              height: parent.height
              glyph: 0xF1946 // md-rewind-15
              onClicked: root.seek(-15)
            }
            IconButton {
              x: parent.width * 0.425
              width: parent.width * 0.15
              height: parent.height
              iconScale: 1.0
              glyph: root.nowPlaying.paused ? 0xF040A : 0xF03E4 // md-play / md-pause
              onClicked: root.togglePause()
            }
            IconButton {
              x: parent.width * 0.73
              width: parent.width * 0.15
              height: parent.height
              glyph: 0xF0D06 // md-fast-forward-30
              onClicked: root.seek(30)
            }
          }

          // Speed pill, styled after the web player's .speedmenu.
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: speedRow.implicitWidth + Style.space(24)
            height: speedRow.implicitHeight + Style.space(10)
            radius: height / 2
            color: speedArea.containsMouse || root.speedMenuOpen ? Util.alpha(root.brand, 0.12) : "transparent"
            border.color: root.brand
            border.width: 1

            Row {
              id: speedRow
              anchors.centerIn: parent
              spacing: Style.space(7)

              Glyph {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                height: width
                glyph: 0xF0F85 // md-speedometer-medium
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.speedLabel(root.nowPlaying.speedId || 0)
                color: root.brand
                font.family: root.sansFamily
                font.pixelSize: Style.font.body
                font.bold: true
                font.features: { "tnum": 1 }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.speedMenuOpen ? "▴" : "▾"
                color: root.brand
                font.pixelSize: Style.font.body
              }
            }

            MouseArea {
              id: speedArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.speedMenuOpen = !root.speedMenuOpen
            }
          }

          Grid {
            visible: root.speedMenuOpen
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 4
            spacing: Style.space(6)

            Repeater {
              model: root.speedOptions

              delegate: Rectangle {
                id: chip
                required property var modelData
                readonly property bool selected: (root.nowPlaying.speedId || 0) === modelData.id
                width: Style.space(64)
                height: Style.space(26)
                radius: height / 2
                color: selected ? root.brand : chipArea.containsMouse ? Util.alpha(root.brand, 0.12) : "transparent"
                border.color: Util.alpha(root.brand, selected ? 1 : 0.45)
                border.width: 1

                Text {
                  anchors.centerIn: parent
                  text: chip.modelData.label
                  color: chip.selected ? (root.bar ? root.bar.background : Color.background) : root.brand
                  font.family: root.sansFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                MouseArea {
                  id: chipArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSpeed(chip.modelData.id)
                }
              }
            }
          }
        }

        // ---- Sign in
        Column {
          id: loginPage
          visible: root.needsLogin
          width: parent.width
          spacing: Style.space(10)
          topPadding: Style.space(18)
          bottomPadding: Style.space(18)

          Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(48)
            height: width
            glyph: 0xF0994 // md-podcast
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Please sign in"
            color: root.fg
            font.family: root.sansFamily
            font.pixelSize: Math.round(Style.font.title * 1.2)
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "Your Overcast session isn't set up or has expired."
            color: root.fg
            opacity: 0.6
            font.family: root.sansFamily
            font.pixelSize: Style.font.body
          }

          Item { width: 1; height: Style.space(4) }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Sign in to Overcast…"
            bordered: true
            foreground: root.fg
            background: Color.popups.background
            accent: root.brand
            fontFamily: root.monoFamily
            fontSize: Style.font.body
            onClicked: root.login()
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "or run in a terminal:"
            color: root.fg
            opacity: 0.5
            font.family: root.monoFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            width: parent.width
            implicitHeight: loginCommandRow.implicitHeight + Style.space(4)

            Row {
              id: loginCommandRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              Text {
                text: root.loginCommand
                color: root.fg
                opacity: 0.5
                font.family: root.monoFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: loginCopiedTimer.running ? "󰄬" : "󰆏"
                color: loginCopiedTimer.running ? root.brand : root.fg
                opacity: loginCopiedTimer.running ? 1 : 0.5
                font.family: root.monoFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: loginCommandMouse
              anchors.fill: loginCommandRow
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copyLoginCommand()
            }

            PanelToolTip {
              visible: loginCommandMouse.containsMouse
              text: loginCopiedTimer.running ? "Copied" : "Copy to clipboard"
              fontFamily: root.monoFamily
            }
          }
        }

        // ---- Errors
        Text {
          visible: root.error !== "" && !root.needsLogin
          width: parent.width
          wrapMode: Text.Wrap
          color: root.fg
          font.family: root.sansFamily
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
          text: root.error
        }

        // ---- List
        ListView {
          id: list
          visible: root.error === "" && root.view !== "playing"
          width: parent.width
          height: parent.height - y
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.space(2)
          model: root.view === "episodes" ? root.episodeList : root.podcastList

          delegate: Rectangle {
            id: row
            required property var modelData
            readonly property bool isEpisode: root.view === "episodes"
            readonly property bool playing: root.nowPlaying.active && isEpisode && root.nowPlaying.path === modelData.path
            readonly property bool fresh: modelData.new === true || modelData.unplayed === true
            width: list.width
            height: rowContent.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: rowArea.containsMouse ? Util.alpha(root.brand, 0.1) : "transparent"

            Row {
              id: rowContent
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(10)

              Image {
                visible: root.showArtwork && !row.isEpisode
                width: visible ? Style.space(32) : 0
                height: width
                source: visible ? (row.modelData.art || "") : ""
                sourceSize.width: Style.space(64)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }

              Column {
                width: parent.width - x - dot.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: (row.playing ? "▶  " : "") + (row.modelData.title || "")
                  color: row.playing || row.fresh ? root.brand : root.fg
                  opacity: row.modelData.played ? 0.45 : 1
                  font.family: root.sansFamily
                  font.pixelSize: Style.font.body + 1
                  font.weight: row.playing || row.fresh ? Font.DemiBold : Font.Normal
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
                Text {
                  visible: row.isEpisode
                  width: parent.width
                  text: row.modelData.caption || ""
                  color: root.fg
                  opacity: 0.45
                  font.family: root.monoFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              // Overcast's unplayed indicator.
              Rectangle {
                id: dot
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.brand
                visible: row.fresh && !row.playing
              }
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: row.isEpisode ? root.play(row.modelData) : root.openPodcast(row.modelData)
            }
          }
        }
      }

      // ---- Settings
      Column {
        id: settingsPage
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        visible: root.settingsOpen
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: settingsBackButton.implicitHeight

          PanelActionButton {
            id: settingsBackButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰁍"
            tooltipText: "Back"
            foreground: root.fg
            hoverColor: root.brand
            fontFamily: root.monoFamily
            onClicked: root.showSettings(false)
          }

          Text {
            anchors.left: settingsBackButton.right
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: "SETTINGS"
            color: root.fg
            font.family: root.monoFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.fg
        }

        Toggle {
          width: parent.width
          label: "Show artwork"
          description: "Podcast artwork in the list and on the now-playing screen."
          checked: root.showArtwork
          foreground: root.fg
          accent: root.brand
          fontFamily: root.monoFamily
          onClicked: root.persistSettings({ showArtwork: !root.showArtwork })
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "ACCENT COLOR"
            color: root.fg
            opacity: 0.6
            font.family: root.monoFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "Overcast", label: "Overcast orange" },
              { value: "Theme", label: "Theme accent" }
            ]
            value: root.themeColors ? "Theme" : "Overcast"
            foreground: root.fg
            background: Color.popups.background
            accent: root.brand
            fontFamily: root.monoFamily
            onChanged: function(value) { root.persistSettings({ accentColor: value }) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "OLDER EPISODES"
            color: root.fg
            opacity: 0.6
            font.family: root.monoFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Dropdown {
            id: olderDropdown
            width: parent.width
            showLabel: false
            options: ["None", "1", "2", "3", "4", "5", "All"]
            value: root.olderEpisodes
            foreground: root.fg
            accent: root.brand
            fontFamily: root.monoFamily
            onChanged: function(value) { root.persistSettings({ olderEpisodes: value }) }
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Shown below the episodes still in your Overcast library."
            color: root.fg
            opacity: 0.5
            font.family: root.monoFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          visible: !root.needsLogin
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "ACCOUNT"
            color: root.fg
            opacity: 0.6
            font.family: root.monoFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Item {
            width: parent.width
            implicitHeight: logoutButton.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.right: logoutButton.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.Wrap
              text: "Stops playback (saving your place) and signs this computer out of Overcast."
              color: root.fg
              opacity: 0.5
              font.family: root.monoFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: logoutButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: logoutProc.running ? "Logging out…" : "Log out"
              bordered: true
              enabled: !logoutProc.running
              foreground: root.fg
              background: Color.popups.background
              accent: root.brand
              fontFamily: root.monoFamily
              fontSize: Style.font.body
              onClicked: root.logout()
            }
          }
        }
      }
    }
  }
}
