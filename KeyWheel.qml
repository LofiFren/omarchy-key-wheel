import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Wheel.js" as Wheel

// The key wheel: every keybinding, laid out as a dial of faces.
//
// On every face a key is a spoke and a modifier is a ring: plain Super is the
// rim, Shift / Ctrl / both step one ring in, and Alt flips the wheel to the
// same rings with Alt added. Core (the curated twelve) opens first; further
// faces hold every other key with a Super binding; the last face, Beyond
// Super, lists bindings without Super and the Caps Lock compose sequences.
//
// Summoned like the built-in emoji picker (dev-install.sh binds Super + R):
//   omarchy-shell shell toggle lofifren.key-wheel '{}'
// Inside it you don't hold Super. Press any key to turn to it; arrows move
// around a face; PgUp/PgDn or the scroll wheel turn faces; hold Shift, Ctrl
// or Alt to light a ring or flip; / searches by name; Enter or a click runs
// the selection; Esc closes.
//
// Running reuses Omarchy's own keybindings menu, so every binding runs exactly
// as Omarchy would run it. The menu asks `omarchy-menu-select` which line was
// picked; bin/omarchy-menu-select in this plugin answers once from a private
// one-shot file, then hands every later call to Omarchy's real picker. Compose entries are typed with
// Omarchy's emoji-insert helper.
//
// Bindings come from `omarchy menu keybindings --print` on every open, and
// the compose table from Omarchy's xcompose plus ~/.XCompose. If the bindings
// can't be read it falls back to Omarchy's Core defaults and says so.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "lofifren.key-wheel"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  // Injected by the shell (Omarchy assigns it), so it must stay writable.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false

  // ---------------------------------------------------------------- data
  property string bindText: ""
  property string composeDefault: ""
  property string composeUser: ""
  property var binds: []
  property var layout: Wheel.buildModel([], [])
  property bool usingFallback: true
  property var cells: []

  // ----------------------------------------------------------- selection
  property int face: 0
  property bool altFace: false          // the side currently drawn
  property bool shiftHeld: false
  property bool ctrlHeld: false
  property bool altHeld: false
  property bool altPinned: false        // a search result on the Alt side
  property int pinnedRing: -1           // set by hovering, ↑ ↓ or search
  property int selectedSpoke: -1
  property int selectedRow: -1          // on the Beyond Super face
  property string notice: ""

  property bool searching: false
  property string query: ""
  property var results: []
  property int resultIndex: 0

  // Keyboard wins until the mouse really moves. Qt re-sends hover events when
  // the scene repaints under a resting pointer.
  property bool keyboardDriven: false
  property real lastMouseX: -1
  property real lastMouseY: -1
  property real wheelAccum: 0

  readonly property var faceObj: layout.faces[Math.min(face, layout.faces.length - 1)]
  readonly property bool onList: faceObj.kind === "list"
  readonly property var spokes: onList ? [] : faceObj.spokes
  readonly property int spokeCount: Math.max(1, spokes.length)
  readonly property real stepDeg: 360 / spokeCount
  readonly property bool altShown: altHeld || altPinned
  readonly property int displayedRing: pinnedRing > 0 ? pinnedRing : Wheel.ringFor(shiftHeld, ctrlHeld)
  readonly property var current: selectedSpoke >= 0 ? Wheel.cell(cells, selectedSpoke, displayedRing) : null
  readonly property var currentRow: onList && selectedRow >= 0 ? layout.beyond[selectedRow] : null
  readonly property var result: searching && results.length ? results[resultIndex] : null
  readonly property int resultStart: Math.max(0, Math.min(resultIndex - 2, results.length - 5))

  // ----------------------------------------------------------- animation
  // bloom grows the rings from the hub out on open; the rim marker glides to
  // the selected spoke; pulse flashes a newly lit ring; dial turns the wheel
  // between faces; flip squeezes it edge-on and back when Alt changes sides.
  property real bloom: 0
  property real needleAngle: 0
  property real pulse: 1
  property real dial: 0
  property real flip: 1
  property int pendingFace: 0
  property int pendingSpoke: -1

  // Theme tokens, so the wheel follows whatever Omarchy theme is active.
  readonly property color accent: Color.accent
  readonly property color ink: Color.menu.text
  readonly property color surface: Color.menu.background
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.family

  // Geometry in the units of the 1040×1040 slide artwork, scaled by wheel.u.
  readonly property var radii: ({ 1: [335, 445], 2: [238, 335], 3: [152, 238], 4: [72, 152] })
  readonly property var labelSize: ({ 1: 24, 2: 21, 3: 18, 4: 16 })
  readonly property real capRadius: 482

  // ------------------------------------------------------------ lifecycle
  function open(payloadJson) {
    root.shiftHeld = false
    root.ctrlHeld = false
    root.altHeld = false
    root.altPinned = false
    root.altFace = false
    root.pinnedRing = -1
    root.selectedSpoke = -1
    root.selectedRow = -1
    root.keyboardDriven = true
    root.lastMouseX = -1
    root.lastMouseY = -1
    root.notice = ""
    root.endSearch()
    root.face = 0
    root.dial = 0
    root.flip = 1
    root.opened = true
    root.fetch()
    bloomAnim.restart()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function fetch() {
    keysProc.running = false
    keysProc.running = true
    composeDefaultFile.reload()
    composeUserFile.reload()
  }

  function rebuild() {
    var live = Wheel.parse(root.bindText)
    if (live.length > 0) {
      root.binds = live
      root.usingFallback = false
    } else if (root.binds.length === 0) {
      root.binds = Wheel.parse(Wheel.FALLBACK)
      root.usingFallback = true
    }
    var compose = Wheel.parseCompose(root.composeDefault + "\n" + root.composeUser)
    root.layout = Wheel.buildModel(root.binds, compose)
    if (root.face >= root.layout.faces.length) root.face = 0
    root.recompute()
    if (root.searching) root.setQuery(root.query)
  }

  function recompute() {
    root.cells = Wheel.faceCells(root.layout, root.binds, root.face, root.altFace)
    wheelCanvas.requestPaint()
  }

  // ---------------------------------------------------------- navigation
  function beyondIndex() { return Wheel.beyondFace(root.layout) }

  function firstRow(from, dir) {
    var rows = root.layout.beyond
    for (var i = from; i >= 0 && i < rows.length; i += dir)
      if (rows[i].kind !== "header") return i
    return -1
  }

  // Turn to face `f`, then select `spoke` (or `row` on Beyond Super).
  function goFace(f, spoke, row) {
    var n = root.layout.faces.length
    f = ((f % n) + n) % n
    if (f === root.face && !faceAnim.running) {
      root.applySelection(spoke, row)
      return
    }
    faceAnim.stop()
    faceAnim.dir = (f > root.face) ? 1 : -1
    root.pendingFace = f
    root.pendingSpoke = spoke === undefined ? -1 : spoke
    root.pendingRow = row === undefined ? -1 : row
    faceAnim.start()
  }
  property int pendingRow: -1

  function applySelection(spoke, row) {
    if (root.onList) {
      root.selectedSpoke = -1
      root.selectedRow = (row !== undefined && row >= 0) ? row : root.firstRow(0, 1)
    } else {
      root.selectedRow = -1
      root.selectedSpoke = (spoke !== undefined) ? spoke : -1
    }
  }

  function moveRow(dir) {
    var next = root.firstRow(root.selectedRow < 0 ? 0 : root.selectedRow + dir, dir)
    if (next >= 0) root.selectedRow = next
  }

  // A binding-style key name for a key pressed in the overlay, or "".
  function bindKeyName(k, scan) {
    if (scan >= 10 && scan <= 19) return String((scan - 9) % 10)
    var byScan = { 20: "MINUS", 21: "EQUAL", 34: "BRACKETLEFT", 35: "BRACKETRIGHT",
                   59: "COMMA", 60: "PERIOD" }
    if (byScan.hasOwnProperty(scan)) return byScan[scan]
    if (k === Qt.Key_Space) return "SPACE"
    if (k === Qt.Key_Return || k === Qt.Key_Enter) return "RETURN"
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab) return "TAB"
    if (k === Qt.Key_Backspace) return "BACKSPACE"
    if (k === Qt.Key_Home) return "HOME"
    if (k === Qt.Key_Delete) return "DELETE"
    if (k === Qt.Key_Print) return "PRINT"
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
    return ""
  }

  function navName(k) {
    if (k === Qt.Key_Left) return "LEFT"
    if (k === Qt.Key_Right) return "RIGHT"
    if (k === Qt.Key_Up) return "UP"
    if (k === Qt.Key_Down) return "DOWN"
    return ""
  }

  function syncMods(m) {
    root.shiftHeld = (m & Qt.ShiftModifier) !== 0
    root.ctrlHeld = (m & Qt.ControlModifier) !== 0
    root.altHeld = (m & Qt.AltModifier) !== 0
  }

  function handleKey(event) {
    var k = event.key
    var enter = k === Qt.Key_Return || k === Qt.Key_Enter

    if (k === Qt.Key_Slash && !(event.modifiers & Qt.ShiftModifier)) { root.startSearch(); return }
    if (k === Qt.Key_PageDown) { root.goFace(root.face + 1); return }
    if (k === Qt.Key_PageUp) { root.goFace(root.face - 1); return }
    if (k === Qt.Key_CapsLock || k === Qt.Key_Multi_key) { root.goFace(root.beyondIndex()); return }

    if (root.onList) {
      if (k === Qt.Key_Up) { root.moveRow(-1); return }
      if (k === Qt.Key_Down) { root.moveRow(1); return }
      if (k === Qt.Key_Left) { root.goFace(root.face - 1); return }
      if (k === Qt.Key_Right) { root.goFace(root.face + 1); return }
      if (enter) { root.runItem(root.currentRow); return }
    } else {
      // With a cell selected, Enter runs it. With nothing selected it turns
      // to the Return spoke like any other key.
      if (enter && root.selectedSpoke >= 0) { root.runItem(root.current); return }
      var nav = Wheel.navForKey(root.navName(k))
      if (nav && nav.turn) {
        root.selectedSpoke = Wheel.turn(root.selectedSpoke, nav.turn, root.spokeCount)
        return
      }
      if (nav && nav.step) {
        if (root.selectedSpoke < 0) root.selectedSpoke = 0
        root.pinnedRing = Wheel.stepRing(root.displayedRing, nav.step)
        return
      }
    }

    var key = root.bindKeyName(k, event.nativeScanCode)
    var t = key ? Wheel.keyTarget(root.layout, key) : null
    if (t) {
      root.pinnedRing = -1
      root.goFace(t.face, t.spoke)
    }
  }

  // --------------------------------------------------------------- search
  function startSearch() {
    root.searching = true
    root.query = ""
    root.results = []
    root.resultIndex = 0
  }

  function endSearch() {
    root.searching = false
    root.query = ""
    root.results = []
    root.resultIndex = 0
    root.altPinned = false
  }

  function setQuery(q) {
    root.query = q
    root.results = Wheel.search(root.layout, root.binds, q)
    root.pickResult(0)
  }

  function pickResult(i) {
    if (!root.results.length) return
    i = Math.max(0, Math.min(root.results.length - 1, i))
    root.resultIndex = i
    var t = root.results[i].target
    if (!t) return
    if (t.row !== undefined) {
      root.altPinned = false
      root.goFace(t.face, undefined, t.row)
    } else {
      root.pinnedRing = t.ring
      root.altPinned = t.alt
      root.goFace(t.face, t.spoke)
    }
  }

  function searchKey(event) {
    var k = event.key
    if (k === Qt.Key_Escape) { root.endSearch(); return }
    if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.runItem(root.result); return }
    if (k === Qt.Key_Up) { root.pickResult(root.resultIndex - 1); return }
    if (k === Qt.Key_Down || k === Qt.Key_Tab) { root.pickResult(root.resultIndex + 1); return }
    if (k === Qt.Key_Backspace) {
      if (!root.query.length) root.endSearch()
      else root.setQuery(root.query.slice(0, -1))
      return
    }
    var t = event.text
    if (t && t.length === 1 && t.charCodeAt(0) >= 32 && t.charCodeAt(0) !== 127)
      root.setQuery(root.query + t)
  }

  // ------------------------------------------------------------------ run
  // Anything with a `line` runs through Omarchy's menu; compose entries type.
  function runItem(item) {
    if (!item || (!item.line && !item.out)) {
      root.notice = "Nothing bound here"
      return
    }
    if (item.kind === "compose" || (!item.line && item.out)) {
      root.dismiss()
      Quickshell.execDetached(["bash", "-c", 'sleep 0.2; exec "$1" "$2"',
        "key-wheel", root.omarchyPath + "/bin/omarchy-menu-emoji-insert", item.out])
      return
    }
    if (root.usingFallback) {
      root.notice = "Can't run it: your bindings couldn't be read"
      return
    }
    root.dismiss()
    // Give focus back to the window underneath before the binding runs. The
    // line goes in a private one-shot file that bin/omarchy-menu-select reads
    // and deletes, so nothing launched afterwards can replay it.
    Quickshell.execDetached(["bash", "-c",
      'sleep 0.2; umask 077; f=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/key-wheel.XXXXXX") || exit 1; ' +
      'printf "%s\\n" "$2" > "$f"; PATH="$1/bin:$PATH" KEY_WHEEL_PICK="$f" omarchy menu keybindings; rm -f -- "$f"',
      "key-wheel", root.pluginDir, item.line])
  }

  // ------------------------------------------------------------- drawing
  function css(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," +
           Math.round(c.b * 255) + "," + a + ")"
  }

  // Rings appear hub first, then outward.
  function reveal(ring) {
    var order = 4 - ring
    return Math.max(0, Math.min(1, root.bloom * 4 - order * 0.75))
  }

  // True when the pointer really moved. Qt re-sends hover events when the
  // scene repaints under a resting pointer; those must not steal the
  // selection from the keyboard.
  function realMove(item, mouse) {
    var p = item.mapToItem(null, mouse.x, mouse.y)
    if (root.lastMouseX >= 0 && Math.abs(p.x - root.lastMouseX) < 4 &&
        Math.abs(p.y - root.lastMouseY) < 4) return false
    var first = root.lastMouseX < 0
    root.lastMouseX = p.x
    root.lastMouseY = p.y
    if (first && root.keyboardDriven) return false
    root.keyboardDriven = false
    return true
  }

  // Which cell (or keycap) is under a point on the wheel, or null.
  function cellAt(x, y) {
    var dx = x - wheel.width / 2, dy = y - wheel.height / 2
    var r = Math.sqrt(dx * dx + dy * dy) / wheel.u
    if (r < 72 || r > 520) return null
    var deg = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360
    var spoke = Math.round(deg / root.stepDeg) % root.spokeCount
    if (!root.spokes[spoke] || !root.spokes[spoke].cap) return null
    for (var ring = 1; ring <= 4; ring++) {
      var rr = root.radii[ring]
      if (r >= rr[0] && r < rr[1]) return { spoke: spoke, ring: ring }
    }
    return { spoke: spoke, ring: -1 }   // on a keycap
  }

  onSelectedSpokeChanged: {
    if (root.selectedSpoke < 0) return
    var target = root.selectedSpoke * root.stepDeg
    var d = ((target - root.needleAngle) % 360 + 540) % 360 - 180
    root.needleAngle = root.needleAngle + d
    wheelCanvas.requestPaint()
  }
  onDisplayedRingChanged: {
    pulseAnim.restart()
    wheelCanvas.requestPaint()
  }
  onAltShownChanged: flipAnim.restart()
  onCellsChanged: wheelCanvas.requestPaint()
  onBloomChanged: wheelCanvas.requestPaint()
  onNeedleAngleChanged: wheelCanvas.requestPaint()
  onPulseChanged: wheelCanvas.requestPaint()
  onAccentChanged: wheelCanvas.requestPaint()
  onBindTextChanged: root.rebuild()
  onComposeDefaultChanged: root.rebuild()
  onComposeUserChanged: root.rebuild()
  onSelectedRowChanged: if (root.selectedRow >= 0) beyondList.positionViewAtIndex(root.selectedRow, ListView.Contain)

  Behavior on needleAngle { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
  NumberAnimation { id: bloomAnim; target: root; property: "bloom"; from: 0; to: 1; duration: 560; easing.type: Easing.OutCubic }
  NumberAnimation { id: pulseAnim; target: root; property: "pulse"; from: 0.35; to: 1; duration: 320; easing.type: Easing.OutQuad }

  SequentialAnimation {
    id: faceAnim
    property int dir: 1
    NumberAnimation { target: root; property: "dial"; to: faceAnim.dir; duration: 120; easing.type: Easing.InQuad }
    ScriptAction {
      script: {
        root.face = root.pendingFace
        root.needleAngle = 0
        root.recompute()
        root.applySelection(root.pendingSpoke, root.pendingRow)
        root.dial = -faceAnim.dir
      }
    }
    NumberAnimation { target: root; property: "dial"; to: 0; duration: 200; easing.type: Easing.OutCubic }
  }

  SequentialAnimation {
    id: flipAnim
    NumberAnimation { target: root; property: "flip"; to: 0; duration: 110; easing.type: Easing.InQuad }
    ScriptAction { script: { root.altFace = root.altShown; root.recompute() } }
    NumberAnimation { target: root; property: "flip"; to: 1; duration: 160; easing.type: Easing.OutCubic }
  }

  Component.onCompleted: root.rebuild()

  Process {
    id: keysProc
    command: ["omarchy", "menu", "keybindings", "--print"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.bindText = text
    }
  }

  FileView {
    id: composeDefaultFile
    path: root.omarchyPath + "/default/xcompose"
    printErrors: false
    onLoaded: root.composeDefault = text()
  }

  FileView {
    id: composeUserFile
    path: Quickshell.env("HOME") + "/.XCompose"
    printErrors: false
    onLoaded: root.composeUser = text()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "lofifren-key-wheel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: Math.min(1, root.bloom * 2)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        root.keyboardDriven = true
        root.notice = ""
        var k = event.key
        if (root.searching) {
          root.searchKey(event)
        } else if (k === Qt.Key_Escape) {
          root.dismiss()
        } else if (k === Qt.Key_Shift) {
          root.shiftHeld = true
          root.pinnedRing = -1
        } else if (k === Qt.Key_Control) {
          root.ctrlHeld = true
          root.pinnedRing = -1
        } else if (k === Qt.Key_Alt) {
          root.altHeld = true
        } else if (k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R) {
          // Super is implied inside the wheel.
        } else {
          root.syncMods(event.modifiers)
          root.handleKey(event)
        }
        event.accepted = true
      }
      Keys.onReleased: function (event) {
        if (event.key === Qt.Key_Shift) root.shiftHeld = false
        else if (event.key === Qt.Key_Control) root.ctrlHeld = false
        else if (event.key === Qt.Key_Alt) root.altHeld = false
        event.accepted = true
      }
    }

    // ------------------------------------------------------------ the wheel
    Item {
      id: wheel
      readonly property real size: Math.min(panel.width * 0.9, panel.height * 0.66)
      readonly property real u: size / 1040
      width: size
      height: size
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: panel.height * 0.04
      visible: !root.onList || Math.abs(root.dial) > 0.01
      scale: 0.9 + 0.1 * root.bloom
      rotation: root.dial * 28
      opacity: Math.min(1, root.bloom * 1.6) * (1 - Math.abs(root.dial) * 0.85) * (root.onList ? 0 : 1)
      transform: Scale {
        origin.x: wheel.width / 2
        origin.y: wheel.height / 2
        xScale: root.flip
      }

      Canvas {
        id: wheelCanvas
        anchors.fill: parent
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var u = wheel.u, cx = width / 2, cy = height / 2
          var step = Math.PI * 2 / root.spokeCount

          for (var i = 0; i < root.cells.length; i++) {
            var c = root.cells[i]
            if (!root.spokes[c.spoke] || !root.spokes[c.spoke].cap) continue
            var rev = root.reveal(c.ring)
            if (rev <= 0) continue
            var r = root.radii[c.ring]
            var ri = (r[0] + 2) * u, ro = (r[1] - 2) * u
            var a = c.spoke * step - Math.PI / 2
            var a0 = a - step / 2 + 0.012, a1 = a + step / 2 - 0.012
            var lit = c.ring === root.displayedRing
            var sel = c.spoke === root.selectedSpoke

            ctx.beginPath()
            ctx.arc(cx, cy, ro, a0, a1, false)
            ctx.arc(cx, cy, ri, a1, a0, true)
            ctx.closePath()
            ctx.globalAlpha = rev * (lit ? 1 : 0.45)
            ctx.lineWidth = Math.max(1, 1.5 * u)
            if (c.bound) {
              ctx.fillStyle = lit ? root.css(root.accent, (sel ? 0.42 : 0.2) * root.pulse)
                                  : root.css(root.ink, sel ? 0.14 : 0.06)
              ctx.fill()
              ctx.strokeStyle = lit ? root.css(root.accent, 0.85) : root.css(root.ink, 0.12)
            } else {
              ctx.strokeStyle = root.css(root.ink, 0.05)
            }
            ctx.stroke()
          }

          // The marker: a short bar hugging the rim's outer edge that glides
          // to the selected spoke.
          if (root.selectedSpoke >= 0) {
            var ma = root.needleAngle * Math.PI / 180 - Math.PI / 2
            var half = step / 2 - 0.06
            ctx.globalAlpha = Math.min(1, root.bloom)
            ctx.strokeStyle = root.css(root.accent, 1)
            ctx.lineWidth = 6 * u
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.arc(cx, cy, 452 * u, ma - half, ma + half, false)
            ctx.stroke()
          }

          ctx.globalAlpha = Math.min(1, root.bloom * 2)
          ctx.beginPath()
          ctx.arc(cx, cy, 66 * u, 0, Math.PI * 2)
          ctx.fillStyle = root.css(root.surface, 1)
          ctx.fill()
          ctx.strokeStyle = root.css(root.accent, 1)
          ctx.lineWidth = 3 * u
          ctx.stroke()
        }
      }

      // Cell labels.
      Repeater {
        model: root.cells
        delegate: Text {
          required property var modelData
          readonly property real ang: modelData.spoke * 2 * Math.PI / root.spokeCount
          readonly property real rm: (root.radii[modelData.ring][0] + root.radii[modelData.ring][1]) / 2 * wheel.u
          readonly property real arc: rm * 2 * Math.PI / root.spokeCount
          readonly property bool lit: modelData.ring === root.displayedRing
          visible: modelData.bound
          width: Math.min((modelData.ring === 4 ? 70 : modelData.ring === 3 ? 96 : 150) * wheel.u * (12 / root.spokeCount), arc * 0.9)
          x: wheel.width / 2 + Math.sin(ang) * rm - width / 2
          y: wheel.height / 2 - Math.cos(ang) * rm - height / 2
          text: modelData.label
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: root.ink
          opacity: root.reveal(modelData.ring) * (lit ? 1 : 0.5)
          font.family: root.fontFamily
          font.pixelSize: Math.max(8, root.labelSize[modelData.ring] * wheel.u)
          font.weight: lit && modelData.spoke === root.selectedSpoke ? Font.Bold : Font.Medium
        }
      }

      // Keycaps on the rim.
      Repeater {
        model: root.spokes
        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property real ang: index * 2 * Math.PI / root.spokeCount
          readonly property bool sel: index === root.selectedSpoke
          visible: modelData.cap !== ""
          width: Math.max(52, 18 + 14.5 * modelData.cap.length) * wheel.u
          height: 46 * wheel.u
          radius: 9 * wheel.u
          x: wheel.width / 2 + Math.sin(ang) * root.capRadius * wheel.u - width / 2
          y: wheel.height / 2 - Math.cos(ang) * root.capRadius * wheel.u - height / 2
          // Keep caps upright while the wheel turns between faces.
          rotation: -wheel.rotation
          color: sel ? Util.alpha(root.accent, 0.18) : Util.alpha(root.ink, 0.07)
          border.color: sel ? root.accent : Util.alpha(root.ink, 0.18)
          border.width: Math.max(1, 1.5 * wheel.u)
          opacity: root.reveal(1)

          Text {
            anchors.centerIn: parent
            text: parent.modelData.cap
            textFormat: Text.PlainText
            color: parent.sel ? root.accent : root.ink
            font.family: root.fontFamily
            font.pixelSize: Math.max(8, 22 * wheel.u)
            font.weight: Font.DemiBold
          }
        }
      }

      // The hub: Super, plus whatever else is held or shown.
      Column {
        anchors.centerIn: parent
        spacing: 2 * wheel.u
        opacity: Math.min(1, root.bloom * 2)
        rotation: -wheel.rotation

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.altFace ? "SUPER+ALT" : "SUPER"
          textFormat: Text.PlainText
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Math.max(8, (root.altFace ? 19 : 25) * wheel.u)
          font.weight: Font.Black
          font.letterSpacing: 1.5 * wheel.u
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.displayedRing === 4 ? "+ Shift + Ctrl"
              : root.displayedRing === 2 ? "+ Shift"
              : root.displayedRing === 3 ? "+ Ctrl" : " "
          textFormat: Text.PlainText
          color: root.ink
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Math.max(8, 15 * wheel.u)
        }
      }

      // Hover a cell to look it up, click to run it, scroll to turn faces.
      // Clicks inside the wheel never close it.
      MouseArea {
        id: wheelMouse
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: function (mouse) {
          if (!root.realMove(wheelMouse, mouse)) return
          var hit = root.cellAt(mouse.x, mouse.y)
          if (!hit) return
          root.selectedSpoke = hit.spoke
          if (hit.ring > 0) root.pinnedRing = hit.ring
        }
        onExited: if (!root.keyboardDriven) root.pinnedRing = -1
        onClicked: function (mouse) {
          var hit = root.cellAt(mouse.x, mouse.y)
          if (!hit) return
          root.selectedSpoke = hit.spoke
          if (hit.ring > 0) {
            root.pinnedRing = hit.ring
            root.runItem(Wheel.cell(root.cells, hit.spoke, hit.ring))
          }
        }
        onWheel: function (wheelEvent) {
          root.wheelAccum += wheelEvent.angleDelta.y
          if (root.wheelAccum <= -120) { root.wheelAccum = 0; root.goFace(root.face + 1) }
          else if (root.wheelAccum >= 120) { root.wheelAccum = 0; root.goFace(root.face - 1) }
        }
        onReleased: keyCatcher.forceActiveFocus()
      }
    }

    // ------------------------------------------------- Beyond Super (a list)
    Rectangle {
      id: beyondCard
      width: Math.min(panel.width * 0.8, wheel.size * 1.15)
      height: wheel.size * 0.92
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: wheel.verticalCenter
      radius: Style.cornerRadius
      color: Util.alpha(root.surface, 0.92)
      border.color: Util.alpha(root.ink, 0.12)
      border.width: 1
      visible: root.onList
      opacity: Math.min(1, root.bloom * 1.6) * (1 - Math.abs(root.dial) * 0.85)

      MouseArea {
        anchors.fill: parent
        onWheel: function (wheelEvent) {
          root.wheelAccum += wheelEvent.angleDelta.y
          if (root.wheelAccum <= -240 && beyondList.atYEnd) { root.wheelAccum = 0; root.goFace(root.face + 1) }
          else if (root.wheelAccum >= 240 && beyondList.atYBeginning) { root.wheelAccum = 0; root.goFace(root.face - 1) }
          else wheelEvent.accepted = false
        }
      }

      ListView {
        id: beyondList
        anchors.fill: parent
        anchors.margins: wheel.size * 0.03
        clip: true
        model: root.layout.beyond
        boundsBehavior: Flickable.StopAtBounds
        delegate: Item {
          required property var modelData
          required property int index
          readonly property bool header: modelData.kind === "header"
          readonly property bool sel: index === root.selectedRow
          width: beyondList.width
          height: (header ? 44 : 36) * wheel.u * 1.4

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            visible: !parent.header
            color: parent.sel ? Util.alpha(root.accent, 0.22) : "transparent"
            border.color: parent.sel ? root.accent : "transparent"
          }
          Text {
            visible: parent.header
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            text: parent.modelData.text || ""
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Math.max(10, 17 * wheel.u * 1.2)
            font.weight: Font.Bold
          }
          Row {
            visible: !parent.header
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            spacing: 16
            Text {
              width: beyondList.width * 0.38
              text: parent.parent.modelData.combo || ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: parent.parent.sel ? root.accent : root.ink
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, 17 * wheel.u * 1.2)
              font.weight: Font.DemiBold
            }
            Text {
              width: beyondList.width * 0.56
              text: parent.parent.modelData.description || ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.ink
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, 17 * wheel.u * 1.2)
            }
          }
          MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !parent.header
            hoverEnabled: true
            onPositionChanged: function (mouse) {
              if (root.realMove(rowMouse, mouse)) root.selectedRow = parent.index
            }
            onClicked: root.runItem(parent.modelData)
          }
        }
      }
    }

    // ------------------------------------------- face dots, caption, search
    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: wheel.bottom
      anchors.topMargin: panel.height * 0.015
      spacing: panel.height * 0.008
      width: panel.width * 0.8
      opacity: Math.min(1, root.bloom * 1.6)

      // Which face, out of how many.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: wheel.size * 0.012
        Repeater {
          model: root.layout.faces.length
          delegate: Rectangle {
            required property int index
            anchors.verticalCenter: parent.verticalCenter
            width: wheel.size * (index === root.face ? 0.03 : 0.012)
            height: wheel.size * 0.012
            radius: height / 2
            color: index === root.face ? root.accent : Util.alpha(root.ink, 0.3)
            Behavior on width { NumberAnimation { duration: 160 } }
            MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.goFace(parent.index) }
          }
        }
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.faceObj.title + (root.altFace && !root.onList ? "  ·  Alt side" : "")
        textFormat: Text.PlainText
        color: root.ink
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Math.max(10, wheel.size * 0.02)
        font.weight: Font.DemiBold
      }

      // The selection: full combo and Omarchy's own description.
      Text {
        visible: !root.searching
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.onList
              ? (root.currentRow ? root.currentRow.combo : "Bindings without Super, and Caps Lock compose")
              : (root.current && root.current.combo ? root.current.combo : "Press any key to find it")
        textFormat: Text.PlainText
        color: (root.current && root.current.bound) || root.currentRow ? root.accent : root.ink
        font.family: root.fontFamily
        font.pixelSize: Math.max(12, wheel.size * 0.032)
        font.weight: Font.Bold
      }
      Text {
        visible: !root.searching
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.notice ? root.notice
              : root.onList
                ? (root.currentRow
                   ? root.currentRow.description + (root.currentRow.kind === "compose" ? "  ·  Enter types it" : "  ·  Enter or click runs it")
                   : "↑ ↓ choose · Enter runs · PgUp or scroll for the wheel")
                : (root.current
                   ? (root.current.bound ? root.current.description + "  ·  Enter or click runs it" : "Nothing bound here")
                   : "← → ↑ ↓ move · hold Shift, Ctrl or Alt · PgUp/PgDn or scroll for more · / search · Esc")
        textFormat: Text.PlainText
        color: root.ink
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Math.max(10, wheel.size * 0.022)
      }

      // Search: the query, then a window of results around the pick.
      Text {
        visible: root.searching
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "/ " + root.query + "▏"
        textFormat: Text.PlainText
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Math.max(12, wheel.size * 0.03)
        font.weight: Font.Bold
      }
      Repeater {
        model: root.searching ? root.results.slice(root.resultStart, root.resultStart + 5) : []
        delegate: Text {
          required property var modelData
          required property int index
          readonly property bool sel: root.resultStart + index === root.resultIndex
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: modelData.combo + "   " + modelData.description
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: sel ? root.accent : root.ink
          opacity: sel ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, wheel.size * 0.021)
          font.weight: sel ? Font.Bold : Font.Normal
          MouseArea { anchors.fill: parent; onClicked: root.runItem(parent.modelData) }
        }
      }
      Text {
        visible: root.searching && root.query !== "" && root.results.length === 0
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "No matches"
        textFormat: Text.PlainText
        color: root.ink
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Math.max(10, wheel.size * 0.021)
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.usingFallback
              ? "Key wheel · showing Omarchy's defaults (couldn't read your bindings)"
              : "Key wheel · " + root.layout.total + " shortcuts and sequences"
        textFormat: Text.PlainText
        color: root.ink
        opacity: 0.4
        font.family: root.fontFamily
        font.pixelSize: Math.max(9, wheel.size * 0.016)
      }
    }
  }
}
