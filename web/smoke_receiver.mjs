// smoke_receiver.mjs — headless DOM smoke test for canvas.html's RECEIVER
// bootstrap (pairing -> waiting -> drawing -> upload -> back to waiting),
// using the same hand-rolled DOM/Canvas2D/PointerEvent mock style as
// smoke.mjs (no jsdom available). smoke.mjs continues to cover the existing
// one-shot per-session boot path unmodified; this file exercises the NEW
// receiver-mode path added alongside it, with its own fresh sandbox (the
// receiver bootstrap runs boot() once at script-load time, so a distinct
// scenario needs a distinct sandbox/config, exactly like smoke.mjs does for
// its own scenario).
//
// Drives: no config/token -> pairing screen shown -> submit code -> POST
// /pair -> token stored -> waiting screen -> long-poll GET /session (204 then
// 200) -> drawing screen entered for the session -> draw a stroke -> Done ->
// POST /result -> back to waiting screen, polling resumes.
//
// Run:  node smoke_receiver.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, "canvas.html"), "utf-8");

const scripts = [];
const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
let m;
while ((m = re.exec(html))) scripts.push(m[1]);
assert.equal(scripts.length, 2, "expected 2 inline scripts");

// ---- minimal DOM mock (same shape as smoke.mjs) ----
let listeners = {};
function makeEl(tag) {
  const el = {
    tagName: (tag || "div").toUpperCase(),
    children: [], attributes: {}, dataset: {}, style: {},
    _listeners: {}, className: "", _text: "", disabled: false, value: "",
    hidden: false,
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
    toDataURL() { return "data:image/png;base64,SU1BR0VEQVRB"; },
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

["board","status","toast","zoomBadge","width","widthCap","btnUndo","btnRedo",
 "btnSnap","btnClear","btnDone","btnCancel","btnTheme","tglPen","palette",
 "tools","shapes",
 // receiver overlay elements:
 "screenPairing","screenWaiting","screenDone","pairCode","btnPair","pairError",
 "waitingOrigin","btnUnpair","doneTitle","doneHint"
].forEach(id => reg(id, id === "board" ? "canvas" : "div"));
elements.width.value = "4";
elements.pairCode.value = "";

const toolButtons = [];
["pen","marker","pencil","highlighter","eraser","line","rect","ellipse","arrow"].forEach(tool => {
  const b = makeEl("button"); b.setAttribute("data-tool", tool);
  b.setAttribute("aria-pressed", tool === "pen" ? "true" : "false");
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
elements.palette.appendChild = function (c) { this.children.push(c); if ((c.className||"").indexOf("swatch")>=0) paletteSwatches.push(c); return c; };

// ---- localStorage mock ----
const lsStore = new Map();
const localStorageMock = {
  getItem: (k) => (lsStore.has(k) ? lsStore.get(k) : null),
  setItem: (k, v) => { lsStore.set(k, String(v)); },
  removeItem: (k) => { lsStore.delete(k); }
};

// ---- scripted fetch: queue of responses per call, keyed by URL prefix ----
// once:true entries are pushed to the FRONT (queueOnce) so they take priority
// over the persistent fallback and are consumed strictly in registration
// order. A persistent "/session -> 204" fallback is always present so any
// extra long-poll tick that lands during a test's flush (a real timing race,
// since the receiver keeps polling continuously in the background) gets a
// harmless 204 instead of an uncaught "no scripted response" error whose
// error-driven retry path would otherwise race with later test setup.
let fetchCalls = [];
let fetchScript = [];
function queueOnce(match, respond) { fetchScript.unshift({ match, respond, once: true }); }
function queuePersistent(match, respond) { fetchScript.push({ match, respond, once: false }); }
function nextResponseFor(url, opts) {
  for (let i = 0; i < fetchScript.length; i++) {
    if (fetchScript[i].match(url)) {
      const entry = fetchScript[i];
      if (entry.once) fetchScript.splice(i, 1);
      return entry.respond(url, opts);
    }
  }
  throw new Error("no scripted fetch response for " + url);
}
// Always-available fallback: an idle long-poll just gets 204 (re-poll).
queuePersistent((url) => url === "/session", async () => ({ ok: false, status: 204 }));

const windowMock = {
  innerWidth: 1024, innerHeight: 768, devicePixelRatio: 2,
  ORGPAD_CONFIG: {}, // bare receiver: no session_id, no token
  location: { search: "", href: "http://127.0.0.1:8991/canvas", origin: "http://127.0.0.1:8991" },
  matchMedia: () => ({ matches: false }),
  addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); },
  removeEventListener() {},
  setTimeout: (fn, ms) => { return realSetTimeout(fn, 0); }, // fire "immediately" (no real delay) for test speed
  clearTimeout: (h) => clearTimeout(h),
  TextEncoder, TextDecoder,
  localStorage: localStorageMock,
  AbortController,
  // The scripted response is chosen SYNCHRONOUSLY at dispatch time (whatever
  // is queued at the exact moment fetch() is called) — this is what makes the
  // scripting deterministic regardless of test-harness tick timing. Only the
  // PROMISE RESOLUTION is deferred to a macrotask (setImmediate), to mimic a
  // real network round-trip: a same-microtask resolution would let an
  // unbounded 204 re-poll loop starve the microtask queue and never yield to
  // setImmediate-based test flushing (OOM). Deferring just the resolve (not
  // the response lookup) gives flushUntil() a chance to interleave and bound
  // the loop, while keeping "which response did THIS call get" unambiguous.
  fetch: (url, opts) => {
    fetchCalls.push({ url, opts });
    let outcome;
    try { outcome = { ok: true, value: nextResponseFor(url, opts) }; }
    catch (e) { outcome = { ok: false, value: e }; }
    return new Promise((resolve, reject) => {
      setImmediate(() => {
        if (outcome.ok) resolve(outcome.value);
        else reject(outcome.value);
      });
    });
  }
};
const realSetTimeout = setTimeout;
windowMock.window = windowMock;

const sandbox = {
  window: windowMock, document: documentMock,
  location: windowMock.location,
  navigator: { maxTouchPoints: 5 },
  URLSearchParams, TextEncoder, TextDecoder, Buffer, console,
  setTimeout: (fn, ms) => realSetTimeout(fn, 0), clearTimeout: (h) => clearTimeout(h),
  Math, JSON, Map, Set, Array, Object, String, Number, Infinity, isNaN,
  atob: (s) => Buffer.from(s, "base64").toString("binary"),
  btoa: (s) => Buffer.from(s, "binary").toString("base64"),
  AbortController,
  fetch: windowMock.fetch
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

new vm.Script(scripts[0]).runInContext(sandbox);
assert.ok(sandbox.OrgPadCore, "core did not load");
new vm.Script(scripts[1]).runInContext(sandbox);

let passed = 0;
async function t(name, fn) {
  try { await fn(); passed++; console.log("  ok  " + name); }
  catch (e) { console.error("FAIL  " + name + "\n      " + e.stack); process.exitCode = 1; }
}
async function settle(n = 1) {
  for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r));
}
// Deliberately NOT a "wait until quiet" helper: the receiver's long-poll loop
// is designed to run forever (immediate re-poll on 204), so it never goes
// idle in this mock (no real network latency to create a lull). Instead this
// waits for fetchCalls to reach a known minimum count — the exact number of
// calls the test expects up to and including the one it cares about — then
// gives a few extra ticks for that call's .then/await continuation (the
// state mutations after the awaited fetch resolves) to finish running.
async function flushUntil(minCalls, maxTicks = 50) {
  for (let i = 0; i < maxTicks; i++) {
    if (fetchCalls.length >= minCalls) {
      await settle(4); // let this call's .then/await continuation complete
      return;
    }
    await new Promise(r => setImmediate(r));
  }
}

console.log("== boot (no config, no stored token) ==");
await t("pairing screen is shown, waiting/done hidden", () => {
  assert.equal(elements.screenPairing.hidden, false, "pairing should be visible");
  assert.equal(elements.screenWaiting.hidden, true, "waiting should be hidden");
  assert.equal(elements.screenDone.hidden, true, "done should be hidden");
});

console.log("== pairing: bad code shows an error, no fetch ==");
await t("empty code does not call fetch and shows an error", async () => {
  fetchCalls = [];
  elements.pairCode.value = "12";
  elements.btnPair.dispatch("click", {});
  await settle();
  assert.equal(fetchCalls.length, 0, "should not fetch with an invalid code");
  assert.ok(elements.pairError._text.length > 0, "expected an error message");
});

console.log("== pairing: correct code POSTs /pair, stores token, enters waiting ==");
queueOnce((url) => url === "/pair",
  async (url, opts) => ({ ok: true, status: 200, json: async () => ({ token: "new-token-abc" }) }));
// After pairing succeeds, the waiting screen immediately starts polling
// /session; the persistent fallback (204/re-poll) covers it until the next
// test queues the specific 200-with-session response it wants to observe.
await t("submitting 123456 posts /pair with the exact {code} body, no auth header", async () => {
  fetchCalls = [];
  elements.pairCode.value = "123456";
  elements.btnPair.dispatch("click", {});
  // Deterministic, not "wait for quiet": the receiver's long-poll loop never
  // goes quiet (it re-polls immediately on every 204), so bound this to the
  // first two calls we actually expect (POST /pair, then the first GET
  // /session of the resumed waiting loop) rather than racing a idle-detector
  // against a background process that runs forever by design.
  await flushUntil(2);
  const pairCall = fetchCalls.find(c => c.url === "/pair");
  assert.ok(pairCall, "expected a /pair fetch");
  assert.equal(pairCall.opts.method, "POST");
  assert.equal(pairCall.opts.headers["X-OrgPad-Token"], undefined, "/pair must not carry an auth header");
  const body = JSON.parse(pairCall.opts.body);
  assert.deepEqual(body, { code: "123456" });
});
await t("token is persisted to localStorage under orgpad.token", () => {
  assert.equal(lsStore.get("orgpad.token"), "new-token-abc");
});
await t("after pairing, waiting screen is shown", () => {
  assert.equal(elements.screenWaiting.hidden, false);
  assert.equal(elements.screenPairing.hidden, true);
});
await t("waiting screen shows the connected origin", () => {
  assert.equal(elements.waitingOrigin._text, "http://127.0.0.1:8991");
});

console.log("== long-poll: 204 triggers immediate re-poll, then 200 enters drawing ==");
const editModel = { v: sandbox.OrgPadCore.SCHEMA, w: 400, h: 300, bg: "dark",
  strokes: [{ tool: "pen", color: "#fff", width: 3, points: [[1, 1, 0.5], [5, 5, 0.5]] }] };
const sessionPayload = {
  session_id: "recv-sess-1", mode: "edit", name: "my-fig",
  background: "dark", format: "web",
  drawing: sandbox.OrgPadCore.utf8ToBase64(sandbox.OrgPadCore.serialize(editModel))
};
queueOnce((url) => url === "/session",
  async () => ({ ok: true, status: 200, json: async () => sessionPayload }));
await t("GET /session carries the token header", async () => {
  fetchCalls = [];
  await flushUntil(1); // the queued 200 is consumed by the very next /session poll
  const sessionCalls = fetchCalls.filter(c => c.url === "/session");
  assert.ok(sessionCalls.length >= 1, "expected at least one /session poll");
  sessionCalls.forEach(c => assert.equal(c.opts.headers["X-OrgPad-Token"], "new-token-abc"));
});
await t("drawing screen is entered for the polled session (overlays hidden)", () => {
  assert.equal(elements.screenWaiting.hidden, true);
  assert.equal(elements.screenPairing.hidden, true);
  assert.equal(elements.screenDone.hidden, true);
});
await t("edit session's strokes were restored into state", () => {
  assert.equal(sandbox.window.__orgpad.state.strokes.length, 1);
  assert.equal(sandbox.window.__orgpad.state.strokes[0].tool, "pen");
});
await t("CONFIG now reflects the polled session (used by Done's /result POST)", () => {
  assert.equal(sandbox.window.__orgpad.CONFIG.session_id, "recv-sess-1");
  assert.equal(sandbox.window.__orgpad.CONFIG.mode, "edit");
  assert.equal(sandbox.window.__orgpad.CONFIG.background, "dark");
});

console.log("== draw, then Done posts /result and returns to waiting ==");
function pe(type, x, y, opts = {}) {
  return Object.assign({
    pointerId: 2, pointerType: "pen", clientX: x, clientY: y, pressure: 0.6,
    shiftKey: false, preventDefault() {},
    getCoalescedEvents: () => [], getPredictedEvents: () => []
  }, opts);
}
await t("draw an extra stroke on top of the restored one", () => {
  const board = elements.board;
  board.dispatch("pointerdown", pe("pointerdown", 50, 50));
  board.dispatch("pointermove", pe("pointermove", 90, 80));
  board.dispatch("pointerup", pe("pointerup", 90, 80));
  assert.equal(sandbox.window.__orgpad.state.strokes.length, 2);
});

queueOnce((url) => url === "/result", async () => ({ ok: true, status: 200 }));
// Once we go back to waiting, polling resumes; the persistent /session -> 204
// fallback covers the resumed stream, so no extra scripting is needed here.
await t("Done posts /result with the token header and format:web body", async () => {
  fetchCalls = [];
  elements.btnDone.dispatch("click", {});
  // Stop as soon as /result has landed — don't let the free-running 204
  // re-poll stream (which starts the instant we're back in "waiting") spin
  // this mock forever the way it would legitimately hold ~55s on a real server.
  await flushUntil(1);
  await settle(2); // let the POST /result promise chain (json-free) settle fully
  const resultCall = fetchCalls.find(c => c.url === "/result");
  assert.ok(resultCall, "expected a /result fetch");
  assert.equal(resultCall.opts.headers["X-OrgPad-Token"], "new-token-abc");
  const body = JSON.parse(resultCall.opts.body);
  assert.equal(body.session_id, "recv-sess-1");
  assert.equal(body.format, "web");
  const model = sandbox.OrgPadCore.deserialize(sandbox.OrgPadCore.base64ToUtf8(body.drawing));
  assert.equal(model.strokes.length, 2);
});
await t("after a successful upload, the tab returns to waiting (not done) — receiver stays open", () => {
  assert.equal(elements.screenWaiting.hidden, false, "expected waiting screen after receiver upload");
  assert.equal(elements.screenDone.hidden, true);
});
await t("canvas is cleared for the next drawing", () => {
  assert.equal(sandbox.window.__orgpad.state.strokes.length, 0);
});
await t("polling resumed (a /session call happened after returning to waiting)", async () => {
  fetchCalls = [];
  await flushUntil(1); // just needs to observe polling resumed, not drain the 204 stream
  assert.ok(fetchCalls.some(c => c.url === "/session"), "expected polling to resume");
});

console.log("== Unpair clears the token and returns to pairing ==");
await t("clicking Unpair clears localStorage and shows pairing", async () => {
  elements.btnUnpair.dispatch("click", {});
  await settle();
  assert.equal(lsStore.has("orgpad.token"), false);
  assert.equal(elements.screenPairing.hidden, false);
  assert.equal(elements.screenWaiting.hidden, true);
});

console.log("\n" + passed + " assertions passed"
  + (process.exitCode ? " (with failures above)" : ", 0 failed"));
