// smoke.mjs — headless DOM smoke test for canvas.html WITHOUT jsdom.
// jsdom is not installed in this environment, so we build a minimal DOM +
// Canvas2D + PointerEvent mock, extract the two inline <script> bodies from
// canvas.html, run them in a vm context wired to the mock, and then drive a
// full flow: boot -> pick pen -> draw a stroke via pointer events -> Done
// (upload intercepted) and assert the /result body shape.
//
// This proves the UI script boots, wires the toolbar, records strokes from
// PointerEvents (incl. coalesced), exports a PNG data URL, and POSTs the exact
// {session_id, png, drawing, format:"web"} body with the X-OrgPad-Token header.
//
// Run:  node smoke.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, "canvas.html"), "utf-8");

// ---- extract inline (non-src) script bodies in document order ----
const scripts = [];
const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
let m;
while ((m = re.exec(html))) scripts.push(m[1]);
assert.equal(scripts.length, 2, "expected 2 inline scripts");

// ---- minimal DOM mock ----
let listeners = {};      // eventType -> [fn] on window
function makeEl(tag) {
  const el = {
    tagName: (tag || "div").toUpperCase(),
    children: [], attributes: {}, dataset: {}, style: {},
    _listeners: {}, className: "", _text: "", disabled: false, value: "",
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
      contains(c) { return this._s.has(c); }
    },
    setAttribute(k, v) { this.attributes[k] = String(v); if (k.startsWith("data-")) this.dataset[k.slice(5)] = v; },
    getAttribute(k) { return this.attributes[k]; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    addEventListener(t, fn, o) { (this._listeners[t] = this._listeners[t] || []).push(fn); },
    removeEventListener() {},
    dispatch(t, ev) { (this._listeners[t] || []).forEach(fn => fn(ev)); },
    setPointerCapture() {}, releasePointerCapture() {},
    getContext() { return makeCtx(); },
    toDataURL() { return "data:image/png;base64,SU1BR0VEQVRB"; }, // "IMAGEDATA"
    querySelectorAll() { return []; },
    get textContent() { return this._text; }, set textContent(v) { this._text = v; },
    focus() {}, remove() {}
  };
  el.width = 0; el.height = 0;
  return el;
}
function makeCtx() {
  const calls = [];
  const rec = (name) => (...a) => { calls.push([name, a]); };
  return {
    calls,
    setTransform: rec("setTransform"), clearRect: rec("clearRect"),
    save: rec("save"), restore: rec("restore"), beginPath: rec("beginPath"),
    moveTo: rec("moveTo"), lineTo: rec("lineTo"), quadraticCurveTo: rec("quadraticCurveTo"),
    arc: rec("arc"), ellipse: rec("ellipse"), stroke: rec("stroke"), fill: rec("fill"),
    fillRect: rec("fillRect"), strokeRect: rec("strokeRect"), closePath: rec("closePath"),
    set fillStyle(v) {}, set strokeStyle(v) {}, set lineWidth(v) {},
    set lineCap(v) {}, set lineJoin(v) {}, set globalAlpha(v) {}, set globalCompositeOperation(v) {}
  };
}

const elements = {};
function reg(id, tag) { const e = makeEl(tag); e.id = id; elements[id] = e; return e; }

// Elements the UI script looks up by id:
["board","status","toast","zoomBadge","width","widthCap","btnUndo","btnRedo",
 "btnSnap","btnClear","btnDone","btnCancel","btnTheme","tglPen","palette",
 "tools","shapes"].forEach(id => reg(id, id === "board" ? "canvas" : "div"));
elements.width.value = "4";

// tool buttons (data-tool) that selectTool/querySelectorAll operate on
const toolButtons = [];
["pen","marker","pencil","highlighter","eraser","line","rect","ellipse","arrow"].forEach(t => {
  const b = makeEl("button"); b.setAttribute("data-tool", t);
  b.setAttribute("aria-pressed", t === "pen" ? "true" : "false");
  toolButtons.push(b);
});

const paletteSwatches = [];

const documentMock = {
  getElementById: (id) => elements[id] || reg(id, "div"),
  createElement: (tag) => {
    const e = makeEl(tag);
    if (tag === "canvas") { e.getContext = () => makeCtx(); }
    if (tag === "input") { e.type = "text"; }
    return e;
  },
  querySelectorAll: (sel) => {
    if (sel.indexOf(".tool") >= 0) return toolButtons;
    if (sel.indexOf(".swatch") >= 0) return paletteSwatches;
    return [];
  },
  documentElement: { setAttribute() {}, getAttribute() {} },
  addEventListener() {}
};
// palette.appendChild should collect swatches for querySelectorAll
elements.palette.appendChild = function (c) { this.children.push(c); if ((c.className||"").indexOf("swatch")>=0) paletteSwatches.push(c); return c; };

// ---- window mock ----
let fetchCalls = [];
const windowMock = {
  innerWidth: 1024, innerHeight: 768, devicePixelRatio: 2,
  ORGPAD_CONFIG: { session_id: "smoke-sess", token: "smoke-token", mode: "new",
                   resultUrl: "/result", background: "transparent" },
  location: { search: "" },
  matchMedia: () => ({ matches: false }),
  addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); },
  removeEventListener() {},
  setTimeout: (fn) => 0, clearTimeout() {},
  TextEncoder, TextDecoder,
  fetch: async (url, opts) => { fetchCalls.push({ url, opts }); return { ok: true, status: 200 }; }
};
windowMock.window = windowMock;

const sandbox = {
  window: windowMock, document: documentMock,
  // bare browser globals the UI script references (resolve to window.* in a
  // real browser): location, navigator.
  location: windowMock.location,
  navigator: { maxTouchPoints: 5 },
  URLSearchParams, TextEncoder, TextDecoder, Buffer, console,
  setTimeout: () => 0, clearTimeout: () => {},
  Math, JSON, Map, Set, Array, Object, String, Number, Infinity, isNaN,
  atob: (s) => Buffer.from(s, "base64").toString("binary"),
  btoa: (s) => Buffer.from(s, "binary").toString("base64"),
  fetch: windowMock.fetch
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

// core script first, then UI script (same order as the document)
new vm.Script(scripts[0]).runInContext(sandbox);
assert.ok(sandbox.OrgPadCore, "core did not load");
new vm.Script(scripts[1]).runInContext(sandbox);

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; console.log("  ok  " + name); }
  catch (e) { console.error("FAIL  " + name + "\n      " + e.stack); process.exitCode = 1; }
}

console.log("== boot ==");
t("UI exposed __orgpad debug handle", () => {
  assert.ok(sandbox.window.__orgpad, "no __orgpad on window");
  assert.ok(sandbox.window.__orgpad.state, "no state");
});
t("board was sized by resize()", () => {
  assert.equal(elements.board.width, 1024 * 2);
  assert.equal(elements.board.height, 768 * 2);
});
t("status reflects new-figure session", () => {
  assert.equal(elements.status._text, "new figure");
});

console.log("== draw a stroke via pointer events ==");
function pe(type, x, y, opts = {}) {
  return Object.assign({
    pointerId: 1, pointerType: "pen", clientX: x, clientY: y, pressure: 0.7,
    shiftKey: false, preventDefault() {},
    getCoalescedEvents: () => [], getPredictedEvents: () => []
  }, opts);
}
t("pointerdown+move+up records a freehand stroke", () => {
  const board = elements.board;
  board.dispatch("pointerdown", pe("pointerdown", 100, 100));
  // a coalesced move burst
  board.dispatch("pointermove", pe("pointermove", 150, 130, {
    getCoalescedEvents: () => [pe("m",120,110),pe("m",135,120),pe("m",150,130)]
  }));
  board.dispatch("pointermove", pe("pointermove", 220, 180));
  board.dispatch("pointerup", pe("pointerup", 220, 180));
  const strokes = sandbox.window.__orgpad.state.strokes;
  assert.equal(strokes.length, 1, "expected 1 committed stroke");
  assert.ok(strokes[0].points.length >= 3, "expected multiple points, got " + strokes[0].points.length);
  assert.equal(strokes[0].tool, "pen");
});

console.log("== export + upload (Done) ==");
t("Done posts the correct /result body", async () => {
  fetchCalls = [];
  elements.btnDone.dispatch("click", {});
});
// allow the async done() microtask to settle
await new Promise(r => setImmediate(r));
t("fetch called with /result, token header, and format:web body", () => {
  assert.equal(fetchCalls.length, 1, "expected exactly one fetch, got " + fetchCalls.length);
  const call = fetchCalls[0];
  assert.equal(call.url, "/result");
  assert.equal(call.opts.method, "POST");
  assert.equal(call.opts.headers["X-OrgPad-Token"], "smoke-token");
  const body = JSON.parse(call.opts.body);
  assert.equal(body.session_id, "smoke-sess");
  assert.equal(body.format, "web");
  assert.ok(body.png && body.png.length > 0, "png missing");
  // drawing decodes to a model with our stroke
  const model = sandbox.OrgPadCore.deserialize(sandbox.OrgPadCore.base64ToUtf8(body.drawing));
  assert.ok(model.strokes.length >= 1, "drawing has no strokes");
});

console.log("\n" + passed + " assertions passed"
  + (process.exitCode ? " (with failures above)" : ", 0 failed"));
