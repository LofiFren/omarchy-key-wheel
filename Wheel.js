// Pure logic for lofifren.key-wheel: parse the live keybindings and the
// compose table, and lay everything out as faces of a wheel. No QML or
// Quickshell here, so it runs under Node for tests (test/wheel.test.mjs).
//
// The grammar, on every face: a key is a spoke, a modifier is a ring.
// Plain Super is the rim; Shift, Ctrl and both step one ring in each; Alt
// flips the wheel to the same four rings with Alt added. So every Super
// combination has exactly one cell. Bindings without Super, and the Caps
// Lock compose sequences, live on the last face as a list.
.pragma library

// Rings, outermost first. Alt is the other side of the wheel, not a ring.
var RINGS = [
  { id: 1, name: "Rim",    mods: ["SUPER"] },
  { id: 2, name: "Ring 2", mods: ["SUPER", "SHIFT"] },
  { id: 3, name: "Ring 3", mods: ["SUPER", "CTRL"] },
  { id: 4, name: "Hub",    mods: ["SUPER", "SHIFT", "CTRL"] }
]

// The Core face: the curated twelve, the same wheel as the videos. Spokes
// that stand for a family of keys list them all; the first bound one shows.
var CORE = [
  { cap: "Space",   keys: ["SPACE"] },
  { cap: "Return",  keys: ["RETURN"] },
  { cap: "W",       keys: ["W"] },
  { cap: "T",       keys: ["T"] },
  { cap: "F",       keys: ["F"] },
  { cap: "Tab",     keys: ["TAB"] },
  { cap: "1–4",     keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] },
  { cap: "← ↑ ↓ →", keys: ["LEFT", "RIGHT", "UP", "DOWN"] },
  { cap: "Delete",  keys: ["BACKSPACE"] },
  { cap: "C",       keys: ["C"] },
  { cap: "V",       keys: ["V"] },
  { cap: "A",       keys: ["A"] }
]

var PER_FACE = 12   // most spokes a face holds
var MIN_SPOKES = 6  // fewer keys than this still draw six slots

// Short labels for cells. The caption always shows the full description.
var SHORT = {
  "Omarchy menu": "Menu",
  "Toggle top bar": "Top bar",
  "Background switcher": "Background",
  "Theme menu": "Theme",
  "Close window": "Close",
  "Toggle window floating/tiling": "Float",
  "Tiled full screen": "Tiled full",
  "File manager": "Files",
  "File manager (cwd)": "Files (cwd)",
  "Previous workspace": "Previous",
  "Former workspace": "Last used",
  "Switch to workspace 1": "Go to workspace",
  "Move window to workspace 1": "Send window",
  "Move window silently to workspace 1": "Send quietly",
  "Focus on left window": "Focus",
  "Swap window to the left": "Swap",
  "Move grouped window focus left": "Group focus",
  "Move window to group on left": "Into group",
  "Move workspace to left monitor": "To monitor",
  "Toggle window transparency": "Opacity",
  "Toggle window gaps": "Gaps",
  "Toggle single-window square aspect": "Square",
  "Universal copy": "Copy",
  "Universal paste": "Paste",
  "Universal cut": "Cut",
  "Capture menu": "Capture",
  "Clipboard manager": "Clipboard",
  "Toggle scratchpad": "Scratchpad",
  "Move window to scratchpad": "To scratchpad",
  "Pop window out (float & pin)": "Pop out",
  "Toggle window split": "Split",
  "Pseudo window": "Pseudo",
  "Toggle workspace layout": "Layout",
  "Toggle window grouping": "Group",
  "Move active window out of group": "Ungroup",
  "Keybindings": "Shortcuts",
  "System menu": "System",
  "Dismiss last notification": "Dismiss",
  "Dismiss all notifications": "Dismiss all",
  "Toggle silencing notifications": "Silence",
  "Invoke last notification": "Open last",
  "Open notification history": "History",
  "Browser (private)": "Private",
  "Monitor scaling up": "Scale up",
  "Monitor scaling down": "Scale down",
  "Save window width": "Save width",
  "Restore window width": "Restore width"
}

// Keycap text for a binding's key name.
var CAPS = {
  SPACE: "Space", RETURN: "Return", TAB: "Tab", BACKSPACE: "Delete",
  ESCAPE: "Esc", COMMA: ",", PERIOD: ".", SLASH: "/", MINUS: "-",
  EQUAL: "=", HOME: "Home", DELETE: "Fwd Del", PRINT: "Print",
  BRACKETLEFT: "[", BRACKETRIGHT: "]",
  LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓",
  MOUSE_DOWN: "Scroll ↓", MOUSE_UP: "Scroll ↑",
  "LEFT MOUSE BUTTON": "Click", "RIGHT MOUSE BUTTON": "Right-click",
  "MIDDLE MOUSE BUTTON": "Middle-click"
}

// Order for the non-letter keys after Core.
var OTHER_ORDER = ["ESCAPE", "COMMA", "PERIOD", "SLASH", "MINUS", "EQUAL",
                   "BRACKETLEFT", "BRACKETRIGHT", "HOME", "DELETE", "PRINT"]

var MOD_NAMES = { SUPER: "Super", SHIFT: "Shift", CTRL: "Ctrl", ALT: "Alt" }
var MOD_ORDER = ["SUPER", "SHIFT", "CTRL", "ALT"]

// ---------------------------------------------------------------- parsing

// One line of `omarchy menu keybindings --print`:
//   "SUPER SHIFT CTRL + SPACE            → Theme menu"
// Modifiers are space-separated, then " + ", then the key, then the arrow.
function parseLine(line) {
  var arrow = line.indexOf("→")
  if (arrow < 0) return null
  var left = line.slice(0, arrow).trim()
  var description = line.slice(arrow + 1).split("\t")[0].trim()
  if (!left || !description) return null

  var mods = []
  var key = left
  var plus = left.lastIndexOf(" + ")
  if (plus >= 0) {
    mods = left.slice(0, plus).trim().split(/\s+/).filter(function (m) { return m })
    key = left.slice(plus + 3).trim()
  }
  if (!key) return null
  // The Copilot key duplicates another binding; Omarchy's own list hides it.
  if (/^code:201$/i.test(key)) return null
  // `line` is kept verbatim: it's what Omarchy's keybindings menu matches on
  // when it runs a binding (see runLine in KeyWheel.qml).
  return { mods: normalizeMods(mods), key: normalizeKey(key), description: description,
           line: line.split("\t")[0].replace(/\r$/, "") }
}

function normalizeMods(mods) {
  return mods.map(function (m) { return m.toUpperCase() })
             .map(function (m) { return m === "CONTROL" ? "CTRL" : m })
             .sort()
}

// Workspace keys can come through as xkb keycodes: code:10 is 1 … code:19 is 0.
function normalizeKey(key) {
  var k = String(key).toUpperCase()
  var m = /^CODE:(\d+)$/.exec(k)
  if (m) {
    var n = Number(m[1])
    if (n >= 10 && n <= 19) return String((n - 9) % 10)
    var named = { 20: "MINUS", 21: "EQUAL", 34: "BRACKETLEFT", 35: "BRACKETRIGHT",
                  59: "COMMA", 60: "PERIOD", 61: "SLASH" }
    if (named.hasOwnProperty(n)) return named[n]
  }
  var mouse = { "MOUSE:272": "LEFT MOUSE BUTTON", "MOUSE:273": "RIGHT MOUSE BUTTON",
                "MOUSE:274": "MIDDLE MOUSE BUTTON" }
  if (mouse.hasOwnProperty(k)) return mouse[k]
  return k
}

function parse(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var b = parseLine(lines[i])
    if (b) out.push(b)
  }
  return out
}

// XCompose lines: <Multi_key> <m> <s> : "😄" # smile
// A bare "# Heading" comment names the section the next lines belong to.
function parseCompose(text) {
  var out = [], seen = {}, category = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    var h = /^#\s*(.+)$/.exec(line)
    if (h) { category = h[1].trim(); continue }
    var m = /^<Multi_key>((?:\s*<[^>]+>)+)\s*:\s*"((?:[^"\\]|\\.)*)"[^#]*(?:#\s*(.*))?$/.exec(line)
    if (!m) continue
    var seq = m[1].match(/<[^>]+>/g).map(function (s) { return s.slice(1, -1) })
    var id = seq.join(" ")
    if (seen[id]) continue
    seen[id] = true
    out.push({ seq: seq, out: m[2], name: (m[3] || "").trim(), category: category })
  }
  return out
}

// ----------------------------------------------------------------- helpers

function sameMods(a, b) {
  var x = normalizeMods(a), y = normalizeMods(b)
  if (x.length !== y.length) return false
  for (var i = 0; i < x.length; i++) if (x[i] !== y[i]) return false
  return true
}

function hasAlt(mods) { return mods.indexOf("ALT") >= 0 }

// Which ring a binding's modifiers land on, ignoring Alt; -1 if none.
function ringOf(mods) {
  var base = mods.filter(function (m) { return m !== "ALT" })
  for (var r = 0; r < RINGS.length; r++)
    if (sameMods(RINGS[r].mods, base)) return RINGS[r].id
  return -1
}

function onWheel(b) { return ringOf(b.mods) > 0 }

function capFor(key) {
  if (CAPS.hasOwnProperty(key)) return CAPS[key]
  if (/^XF86/.test(key)) return key.slice(4)
  if (key.length === 1) return key
  return key.charAt(0) + key.slice(1).toLowerCase()
}

function shortLabel(description) {
  if (SHORT[description]) return SHORT[description]
  var d = description.replace(/^Toggle /, "")
  d = d.charAt(0).toUpperCase() + d.slice(1)
  if (d.length <= 14) return d
  return d.split(/\s+/).slice(0, 2).join(" ")
}

function comboText(mods, cap) {
  var sorted = mods.slice().sort(function (a, b) { return MOD_ORDER.indexOf(a) - MOD_ORDER.indexOf(b) })
  return sorted.map(function (m) { return MOD_NAMES[m] || m }).concat([cap]).join(" + ")
}

function comboFor(b) { return comboText(b.mods, capFor(b.key)) }

function composeCombo(c) {
  return "Caps " + c.seq.map(function (k) { return k === "space" ? "Space" : k }).join(" ")
}

function find(bindings, mods, keys) {
  for (var k = 0; k < keys.length; k++) {
    for (var i = 0; i < bindings.length; i++) {
      var b = bindings[i]
      if (b.key === keys[k] && sameMods(b.mods, mods)) return b
    }
  }
  return null
}

// Split keys into faces of at most PER_FACE, as evenly as possible.
function chunk(keys) {
  if (!keys.length) return []
  var n = Math.ceil(keys.length / PER_FACE)
  var size = Math.ceil(keys.length / n)
  var out = []
  for (var i = 0; i < keys.length; i += size) out.push(keys.slice(i, i + size))
  return out
}

function spokesFor(keys) {
  var spokes = keys.map(function (k) { return { cap: capFor(k), keys: [k] } })
  while (spokes.length < MIN_SPOKES) spokes.push({ cap: "", keys: [] })
  return spokes
}

// ------------------------------------------------------------------ model

// Faces in order: Core, letters, other keys, then "Beyond Super" (a list).
function buildModel(binds, compose) {
  var coreKeys = {}
  CORE.forEach(function (s) { s.keys.forEach(function (k) { coreKeys[k] = true }) })

  var letters = [], others = [], seen = {}
  binds.forEach(function (b) {
    if (!onWheel(b) || coreKeys[b.key] || seen[b.key]) return
    seen[b.key] = true
    if (/^[A-Z]$/.test(b.key)) letters.push(b.key)
    else others.push(b.key)
  })
  letters.sort()
  others.sort(function (a, b) {
    var ia = OTHER_ORDER.indexOf(a), ib = OTHER_ORDER.indexOf(b)
    if (ia < 0) ia = 999
    if (ib < 0) ib = 999
    return ia !== ib ? ia - ib : (a < b ? -1 : a > b ? 1 : 0)
  })

  var faces = [{ title: "Core", kind: "wheel", spokes: CORE }]
  chunk(letters).forEach(function (g) {
    faces.push({ title: g.length > 1 ? "Letters " + g[0] + "–" + g[g.length - 1] : "Letter " + g[0],
                 kind: "wheel", spokes: spokesFor(g) })
  })
  var otherFaces = chunk(others)
  otherFaces.forEach(function (g, i) {
    faces.push({ title: otherFaces.length > 1 ? "Keys & symbols " + (i + 1) : "Keys & symbols",
                 kind: "wheel", spokes: spokesFor(g) })
  })

  var beyond = []
  var plain = binds.filter(function (b) { return !onWheel(b) })
  if (plain.length) {
    beyond.push({ kind: "header", text: "Without Super" })
    plain.forEach(function (b) {
      beyond.push({ kind: "bind", combo: comboFor(b), description: b.description, line: b.line })
    })
  }
  if (compose && compose.length) {
    beyond.push({ kind: "header", text: "Caps Lock compose: tap Caps Lock, then type the rest" })
    compose.forEach(function (c) {
      beyond.push({ kind: "compose", combo: composeCombo(c), out: c.out,
                    description: c.out + (c.name ? "  " + c.name : ""), category: c.category })
    })
  }
  faces.push({ title: "Beyond Super", kind: "list" })

  return { faces: faces, beyond: beyond, total: binds.length + (compose ? compose.length : 0) }
}

function beyondFace(model) { return model.faces.length - 1 }

// The cells of one wheel face, on its plain side or its Alt side.
function faceCells(model, binds, face, alt) {
  var f = model.faces[face]
  if (!f || f.kind !== "wheel") return []
  var out = []
  for (var s = 0; s < f.spokes.length; s++) {
    for (var r = 0; r < RINGS.length; r++) {
      var mods = RINGS[r].mods.concat(alt ? ["ALT"] : [])
      var b = f.spokes[s].keys.length ? find(binds, mods, f.spokes[s].keys) : null
      out.push({
        spoke: s,
        ring: RINGS[r].id,
        bound: !!b,
        label: b ? shortLabel(b.description) : "",
        description: b ? b.description : "",
        line: b ? b.line : "",
        combo: f.spokes[s].cap ? comboText(mods, f.spokes[s].cap) : ""
      })
    }
  }
  return out
}

function cell(list, spoke, ring) {
  for (var i = 0; i < list.length; i++)
    if (list[i].spoke === spoke && list[i].ring === ring) return list[i]
  return null
}

// Where a key lives: the first face with a spoke for it.
function keyTarget(model, key) {
  for (var f = 0; f < model.faces.length; f++) {
    var face = model.faces[f]
    if (face.kind !== "wheel") continue
    for (var s = 0; s < face.spokes.length; s++)
      if (face.spokes[s].keys.indexOf(key) >= 0) return { face: f, spoke: s }
  }
  return null
}

// Where a binding lives: a wheel cell, or a row on the Beyond Super face.
function locate(model, b) {
  if (onWheel(b)) {
    var t = keyTarget(model, b.key)
    if (t) return { face: t.face, spoke: t.spoke, ring: ringOf(b.mods), alt: hasAlt(b.mods) }
  }
  for (var i = 0; i < model.beyond.length; i++)
    if (model.beyond[i].line && model.beyond[i].line === b.line)
      return { face: beyondFace(model), row: i }
  return null
}

// Search descriptions, combos and compose names. Every word must match.
// Results that start with the query come first, then word matches.
function search(model, binds, query) {
  var q = String(query || "").toLowerCase().trim()
  if (!q) return []
  var terms = q.split(/\s+/)
  var word = new RegExp("\\b" + q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
  var out = []
  function consider(item, hay) {
    hay = hay.toLowerCase()
    for (var t = 0; t < terms.length; t++) if (hay.indexOf(terms[t]) < 0) return
    var d = item.description.toLowerCase()
    item.rank = d.indexOf(q) === 0 ? 0 : word.test(d) ? 1 : 2
    item.order = out.length
    out.push(item)
  }
  binds.forEach(function (b) {
    var combo = comboFor(b)
    consider({ kind: "bind", combo: combo, description: b.description, line: b.line,
               target: locate(model, b) }, b.description + " " + combo)
  })
  model.beyond.forEach(function (row, i) {
    if (row.kind !== "compose") return
    consider({ kind: "compose", combo: row.combo, description: row.description, out: row.out,
               target: { face: beyondFace(model), row: i } },
             row.description + " " + row.combo + " " + row.category + " compose")
  })
  out.sort(function (a, b) { return a.rank - b.rank || a.order - b.order })
  return out.slice(0, 40)
}

// ------------------------------------------------------------- navigation

function ringFor(shift, ctrl) {
  if (shift && ctrl) return 4
  if (shift) return 2
  if (ctrl) return 3
  return 1
}

// Arrows only: h, j, k and l are keys with spokes of their own.
function navForKey(name) {
  var n = String(name || "").toUpperCase()
  if (n === "LEFT") return { turn: -1 }
  if (n === "RIGHT") return { turn: 1 }
  if (n === "UP") return { step: -1 }
  if (n === "DOWN") return { step: 1 }
  return null
}

// Turn from `spoke` by `dir` around `count` spokes, wrapping. With nothing
// selected, start at 12 o'clock.
function turn(spoke, dir, count) {
  var n = count || CORE.length
  if (spoke < 0) return 0
  return (spoke + dir + n) % n
}

// Step from `ring` by `dir`: 1 is the rim, 4 the hub; stops at either end.
function stepRing(ring, dir) {
  return Math.max(1, Math.min(4, ring + dir))
}

// Omarchy 4.0.4's defaults for the Core cells, from default/hypr/bindings/*.lua
// at commit c668141. Used only when the live list can't be read, and
// labelled as such in the overlay.
var FALLBACK = [
  "SUPER + SPACE → Omarchy menu",
  "SUPER SHIFT + SPACE → Toggle top bar",
  "SUPER CTRL + SPACE → Background switcher",
  "SUPER SHIFT CTRL + SPACE → Theme menu",
  "SUPER + RETURN → Terminal",
  "SUPER SHIFT + RETURN → Browser",
  "SUPER + W → Close window",
  "SUPER + T → Toggle window floating/tiling",
  "SUPER + F → Full screen",
  "SUPER SHIFT + F → File manager",
  "SUPER CTRL + F → Tiled full screen",
  "SUPER + TAB → Next workspace",
  "SUPER SHIFT + TAB → Previous workspace",
  "SUPER CTRL + TAB → Former workspace",
  "SUPER + code:10 → Switch to workspace 1",
  "SUPER SHIFT + code:10 → Move window to workspace 1",
  "SUPER + LEFT → Focus on left window",
  "SUPER SHIFT + LEFT → Swap window to the left",
  "SUPER CTRL + LEFT → Move grouped window focus left",
  "SUPER + BACKSPACE → Toggle window transparency",
  "SUPER SHIFT + BACKSPACE → Toggle window gaps",
  "SUPER CTRL + BACKSPACE → Toggle single-window square aspect",
  "SUPER + C → Universal copy",
  "SUPER CTRL + C → Capture menu",
  "SUPER + V → Universal paste",
  "SUPER CTRL + V → Clipboard manager",
  "SUPER CTRL + A → Audio",
  "SUPER SHIFT CTRL + A → Agent"
].join("\n")
