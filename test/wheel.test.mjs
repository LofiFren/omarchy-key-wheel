// Run with: node --test test/wheel.test.mjs
// Loads Wheel.js the way QML would (minus the .pragma line) and checks it
// against fixtures generated from Omarchy 4.0.4's own binding files.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

const src = readFileSync(new URL('../Wheel.js', import.meta.url), 'utf8').replace(/^\.pragma library$/m, '');
const ctx = {};
vm.runInNewContext(src + `
this.W = { RINGS, CORE, parse, parseLine, parseCompose, buildModel, faceCells, cell,
  keyTarget, locate, search, ringFor, navForKey, turn, stepRing, shortLabel,
  comboText, capFor, beyondFace, FALLBACK };`, ctx);
const W = ctx.W;
const fixture = (f) => readFileSync(new URL('fixtures/' + f, import.meta.url), 'utf8');

const binds = W.parse(fixture('omarchy-4.0.4-print.txt'));
const compose = W.parseCompose(fixture('xcompose'));
const model = W.buildModel(binds, compose);
const titles = model.faces.map((f) => f.title);

test('parses the padded --print format, including the tab-separated tail', () => {
  const b = W.parseLine('SUPER SHIFT CTRL + SPACE            → Theme menu\texec\tomarchy-menu toggle theme');
  assert.deepEqual([...b.mods], ['CTRL', 'SHIFT', 'SUPER']);
  assert.equal(b.key, 'SPACE');
  assert.equal(b.description, 'Theme menu');
  assert.equal(b.line, 'SUPER SHIFT CTRL + SPACE            → Theme menu');
});

test('keycodes and mouse buttons get readable names', () => {
  assert.equal(W.parseLine('SUPER + code:10 → Switch to workspace 1').key, '1');
  assert.equal(W.parseLine('SUPER + code:19 → Switch to workspace 10').key, '0');
  assert.equal(W.parseLine('SUPER + code:20 → Expand window left').key, 'MINUS');
  assert.equal(W.parseLine('SUPER + mouse:272 → Move window').key, 'LEFT MOUSE BUTTON');
});

test('compose table: 23 emoji and the em dash, with sections', () => {
  assert.equal(compose.length, 24);
  const smile = compose.find((c) => c.name === 'smile');
  assert.deepEqual([...smile.seq], ['m', 's']);
  assert.equal(smile.out, '😄');
  assert.equal(smile.category, 'Emoji');
  assert.equal(compose.find((c) => c.out === '—').category, 'Typography');
});

test('faces: Core first, letters, keys & symbols, Beyond Super last', () => {
  assert.equal(titles[0], 'Core');
  assert.equal(titles.at(-1), 'Beyond Super');
  assert.ok(titles.some((t) => t.startsWith('Letters')), titles.join(', '));
  assert.ok(titles.some((t) => t.startsWith('Keys & symbols')), titles.join(', '));
  for (const f of model.faces.filter((f) => f.kind === 'wheel')) {
    assert.ok(f.spokes.length >= 6 && f.spokes.length <= 12, `${f.title}: ${f.spokes.length}`);
  }
});

test('every binding has exactly one home: a wheel cell or a Beyond row', () => {
  for (const b of binds) {
    const t = W.locate(model, b);
    assert.ok(t, `nowhere for ${b.line}`);
    if (t.row === undefined) {
      const cells = W.faceCells(model, binds, t.face, t.alt);
      assert.ok(W.cell(cells, t.spoke, t.ring).bound, `cell empty for ${b.line}`);
    } else {
      assert.equal(model.beyond[t.row].line, b.line);
    }
  }
});

test('Core matches the slides on its plain side', () => {
  const c = W.faceCells(model, binds, 0, false);
  assert.equal(W.cell(c, 0, 1).label, 'Menu');
  assert.equal(W.cell(c, 0, 4).label, 'Theme');
  assert.equal(W.cell(c, 6, 1).label, 'Go to workspace');
  assert.equal(W.cell(c, 11, 4).label, 'Agent');
});

test('Alt is the other side: Super+Shift+Alt+1 sends a window quietly', () => {
  const c = W.faceCells(model, binds, 0, true);
  assert.equal(W.cell(c, 6, 2).description, 'Move window silently to workspace 1');
  assert.equal(W.cell(c, 6, 2).combo, 'Super + Shift + Alt + 1–4');
});

test('any key finds its face', () => {
  const s = W.keyTarget(model, 'S');
  assert.ok(model.faces[s.face].title.startsWith('Letters'));
  assert.equal(model.faces[s.face].spokes[s.spoke].cap, 'S');
  assert.equal(W.keyTarget(model, '7').face, 0);
  assert.ok(model.faces[W.keyTarget(model, 'COMMA').face].title.startsWith('Keys'));
  assert.equal(W.keyTarget(model, 'NOPE'), null);
});

test('Beyond Super holds the non-Super bindings and the compose table', () => {
  const rows = model.beyond;
  assert.ok(rows.some((r) => r.kind === 'bind' && r.combo === 'Alt + Tab'));
  assert.ok(rows.some((r) => r.kind === 'bind' && r.combo === 'Print'));
  assert.ok(rows.some((r) => r.kind === 'compose' && r.combo === 'Caps m s' && r.out === '😄'));
  assert.ok(rows.some((r) => r.kind === 'compose' && r.combo === 'Caps Space Space'));
});

test('search: "emoji" finds the picker and the compose emoji', () => {
  const r = W.search(model, binds, 'emoji');
  assert.equal(r[0].description, 'Emojis');
  assert.equal(r[0].combo, 'Super + Ctrl + E');
  assert.ok(r.some((x) => x.kind === 'compose' && x.out === '😄'));
  const t = r[0].target;
  assert.equal(model.faces[t.face].spokes[t.spoke].cap, 'E');
  assert.equal(t.ring, 3);
});

test('search: words in any order, prefix matches first, empty query', () => {
  assert.equal(W.search(model, binds, 'theme')[0].description, 'Theme menu');
  assert.ok(W.search(model, binds, 'window close').some((x) => x.description === 'Close window'));
  assert.deepEqual([...W.search(model, binds, '  ')], []);
});

test('navigation: arrows only, turning wraps per face, rings clamp', () => {
  assert.equal(W.navForKey('Left').turn, -1);
  assert.equal(W.navForKey('Down').step, 1);
  assert.equal(W.navForKey('L'), null);
  assert.equal(W.turn(-1, 1, 9), 0);
  assert.equal(W.turn(0, -1, 9), 8);
  assert.equal(W.stepRing(4, 1), 4);
  assert.equal(W.ringFor(true, true), 4);
});

test('fallback fills Core when the live list is unreadable', () => {
  const fb = W.parse(W.FALLBACK);
  const c = W.faceCells(W.buildModel(fb, []), fb, 0, false);
  assert.equal(W.cell(c, 0, 1).label, 'Menu');
});

test('the stand-in picker answers once, then defers to the real picker', async () => {
  const { mkdtempSync, writeFileSync, existsSync, chmodSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, resolve } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'kw-'));
  // A fake "real" picker further down PATH.
  const real = join(dir, 'real');
  (await import('node:fs')).mkdirSync(real);
  writeFileSync(join(real, 'omarchy-menu-select'), '#!/bin/bash\necho REAL-PICKER\n');
  chmodSync(join(real, 'omarchy-menu-select'), 0o755);
  const env = { ...process.env, PATH: `${resolve('bin')}:${real}:${process.env.PATH}` };

  const line = 'SUPER + W                           → Close window';
  const pick = join(dir, 'pick');
  writeFileSync(pick, line + '\n', { mode: 0o600 });
  const first = execFileSync('omarchy-menu-select', ['Keybindings'],
    { input: line + '\n', env: { ...env, KEY_WHEEL_PICK: pick } }).toString();
  assert.equal(first.replace(/\n$/, ''), line);
  assert.equal(existsSync(pick), false, 'one-shot file must be deleted');

  // Same environment again, as a launched app would inherit it.
  const second = execFileSync('omarchy-menu-select', ['Keybindings'],
    { input: '', env: { ...env, KEY_WHEEL_PICK: pick } }).toString();
  assert.equal(second.trim(), 'REAL-PICKER');
});
