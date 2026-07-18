// verify_receiver.mjs — unit tests for the RECEIVER-mode bootstrap logic
// added to OrgPadCore in canvas.html: config resolution (mode decision),
// the /pair request body, GET /session response parsing (incl. base64
// web-JSON edit-drawing decode), and the Backoff sequence. Also exercises a
// localStorage mock for token read/write, mirroring what the UI script's
// readStoredToken()/writeStoredToken() do in a real browser.
//
// Extracts the CORE-START..CORE-END block from canvas.html verbatim (same
// approach as verify.mjs) so these tests run against the EXACT source shipped
// in the browser, not a copy.
//
// Run:  node verify_receiver.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, "canvas.html"), "utf-8");

const m = html.match(/\/\* CORE-START \*\/([\s\S]*?)\/\* CORE-END \*\//);
assert.ok(m, "CORE-START/CORE-END markers not found in canvas.html");
const coreSrc = m[1];

const sandbox = { module: { exports: {} }, Buffer, console };
vm.createContext(sandbox);
new vm.Script(coreSrc).runInContext(sandbox);
const C = sandbox.OrgPadCore;
assert.ok(C && typeof C === "object", "OrgPadCore not exported");

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; console.log("  ok  " + name); }
  catch (e) { console.error("FAIL  " + name + "\n      " + e.message); process.exitCode = 1; }
}
function eqVal(a, b, msg) {
  assert.equal(JSON.stringify(a), JSON.stringify(b), msg);
}

console.log("== resolveConfig: mode/screen decision ==");
t("session_id present -> drawing screen, regardless of token", () => {
  const r = C.resolveConfig({ session_id: "sess-1", mode: "new" }, null);
  assert.equal(r.screen, "drawing");
  assert.equal(r.session_id, "sess-1");
});
t("session_id present + token also present -> still drawing (per-session wins)", () => {
  const r = C.resolveConfig({ session_id: "sess-1", token: "tok" }, "stored-tok");
  assert.equal(r.screen, "drawing");
});
t("no session_id, cfg.token present -> waiting, uses cfg.token", () => {
  const r = C.resolveConfig({ token: "cfg-tok" }, null);
  assert.equal(r.screen, "waiting");
  assert.equal(r.token, "cfg-tok");
});
t("no session_id, no cfg.token, but stored token -> waiting, uses stored token", () => {
  const r = C.resolveConfig({}, "stored-tok");
  assert.equal(r.screen, "waiting");
  assert.equal(r.token, "stored-tok");
});
t("no session_id, no token anywhere -> pairing", () => {
  const r = C.resolveConfig({}, null);
  assert.equal(r.screen, "pairing");
  assert.equal(r.token, null);
});
t("empty/absent config entirely still resolves with sane defaults", () => {
  const r = C.resolveConfig(undefined, null);
  assert.equal(r.screen, "pairing");
  assert.equal(r.session_id, null);
  assert.equal(r.mode, "new");
  assert.equal(r.background, "transparent");
});
t("path defaults fill in when cfg omits them", () => {
  const r = C.resolveConfig({}, "tok");
  assert.equal(r.pair_path, "/pair");
  assert.equal(r.session_path, "/session");
  assert.equal(r.result_path, "/result");
  assert.equal(r.cancel_path, "/cancel");
  assert.equal(r.token_header, "X-OrgPad-Token");
});
t("explicit paths in cfg override the defaults", () => {
  const r = C.resolveConfig({
    token: "t", pair_path: "/p2", session_path: "/s2",
    result_path: "/r2", cancel_path: "/c2", token_header: "X-Foo"
  }, null);
  assert.equal(r.pair_path, "/p2");
  assert.equal(r.session_path, "/s2");
  assert.equal(r.result_path, "/r2");
  assert.equal(r.cancel_path, "/c2");
  assert.equal(r.token_header, "X-Foo");
});
t("legacy resultUrl alias still honored when result_path absent", () => {
  const r = C.resolveConfig({ token: "t", resultUrl: "/legacy-result" }, null);
  assert.equal(r.result_path, "/legacy-result");
});

console.log("== pairRequestBody ==");
t("body shape is exactly {code}", () => {
  const b = C.pairRequestBody("123456");
  eqVal(b, { code: "123456" });
});
t("code is coerced to a string", () => {
  const b = C.pairRequestBody(123456);
  eqVal(b, { code: "123456" });
});
t("null/undefined code becomes empty string, not a crash", () => {
  eqVal(C.pairRequestBody(null), { code: "" });
  eqVal(C.pairRequestBody(undefined), { code: "" });
});

console.log("== parseSessionResponse ==");
t("new session (no drawing) parses with restoreJSON null", () => {
  const json = { session_id: "s1", mode: "new", name: "", background: "dark", format: "web", drawing: null };
  const p = C.parseSessionResponse(json);
  assert.equal(p.sessionID, "s1");
  assert.equal(p.mode, "new");
  assert.equal(p.background, "dark");
  assert.equal(p.restoreJSON, null);
});
t("accepts a JSON string, not just an object", () => {
  const json = JSON.stringify({ session_id: "s2", mode: "new", background: "transparent" });
  const p = C.parseSessionResponse(json);
  assert.equal(p.sessionID, "s2");
});
t("edit session with web-format base64 drawing decodes to the stroke JSON", () => {
  const model = { v: C.SCHEMA, w: 800, h: 600, bg: "light",
    strokes: [{ tool: "pen", color: "#000", width: 3, points: [[1, 2, 0.5], [3, 4, 0.6]] }] };
  const strokeJSON = C.serialize(model);
  const drawingB64 = C.utf8ToBase64(strokeJSON);
  const sessionJSON = { session_id: "s3", mode: "edit", name: "fig-1",
    background: "light", format: "web", drawing: drawingB64 };
  const p = C.parseSessionResponse(sessionJSON);
  assert.equal(p.sessionID, "s3");
  assert.equal(p.mode, "edit");
  assert.equal(p.name, "fig-1");
  assert.ok(p.restoreJSON, "expected restoreJSON to be populated");
  // restoreJSON is ready for OrgPadCore.deserialize (the same restore() path).
  const restored = C.deserialize(p.restoreJSON);
  assert.equal(restored.strokes.length, 1);
  assert.equal(restored.strokes[0].tool, "pen");
  eqVal(restored.strokes[0].points[0], [1, 2, 0.5]);
});
t("edit session with pkdrawing format does NOT attempt a web-JSON decode", () => {
  const sessionJSON = { session_id: "s4", mode: "edit", background: "transparent",
    format: "pkdrawing", drawing: "not-web-json-base64-does-not-matter" };
  const p = C.parseSessionResponse(sessionJSON);
  assert.equal(p.restoreJSON, null, "pkdrawing edits are not restorable by this client");
  assert.equal(p.format, "pkdrawing");
});
t("missing 'format' field defaults to web (back-compat with existing wire shape)", () => {
  const model = { v: C.SCHEMA, w: 10, h: 10, bg: "transparent", strokes: [] };
  const drawingB64 = C.utf8ToBase64(C.serialize(model));
  const sessionJSON = { session_id: "s5", mode: "edit", background: "transparent", drawing: drawingB64 };
  const p = C.parseSessionResponse(sessionJSON);
  assert.equal(p.format, "web");
  assert.ok(p.restoreJSON !== null);
});
t("throws on garbage input, same contract as deserialize()", () => {
  assert.throws(() => C.parseSessionResponse(null));
  assert.throws(() => C.parseSessionResponse(42));
});

console.log("== Backoff sequence ==");
t("sequence is 1,2,4,8,16,30 then caps at 30", () => {
  const b = C.makeBackoff();
  const seq = [];
  for (let i = 0; i < 9; i++) seq.push(b.next());
  eqVal(seq, [1, 2, 4, 8, 16, 30, 30, 30, 30]);
});
t("reset() restarts the sequence from 1", () => {
  const b = C.makeBackoff();
  b.next(); b.next(); b.next(); // 1,2,4
  b.reset();
  assert.equal(b.next(), 1);
  assert.equal(b.next(), 2);
});
t("BACKOFF_SEQUENCE constant matches spec", () => {
  eqVal(C.BACKOFF_SEQUENCE, [1, 2, 4, 8, 16, 30]);
});
t("independent Backoff instances don't share state", () => {
  const a = C.makeBackoff(), b = C.makeBackoff();
  a.next(); a.next(); a.next(); // a is now at index 3 (=> next 8)
  assert.equal(b.next(), 1, "b should be unaffected by a's advancement");
  assert.equal(a.next(), 8);
});

console.log("== token read/write via a localStorage mock ==");
// Minimal localStorage mock mirroring what a browser (incl. iPad Safari)
// exposes: getItem/setItem/removeItem backed by an in-memory map. This
// mirrors the UI script's readStoredToken()/writeStoredToken(), which
// wraps window.localStorage calls in try/catch for parity with private-mode
// Safari (where localStorage can throw).
function makeLocalStorageMock() {
  const store = new Map();
  return {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: (k) => { store.delete(k); },
    _store: store
  };
}
const TOKEN_KEY = "orgpad.token";
function readStoredToken(ls) {
  try { return ls.getItem(TOKEN_KEY); } catch (e) { return null; }
}
function writeStoredToken(ls, tok) {
  try {
    if (tok) ls.setItem(TOKEN_KEY, tok);
    else ls.removeItem(TOKEN_KEY);
  } catch (e) { /* non-fatal */ }
}

t("no token stored -> readStoredToken returns null", () => {
  const ls = makeLocalStorageMock();
  assert.equal(readStoredToken(ls), null);
});
t("writeStoredToken persists under orgpad.token, then readStoredToken finds it", () => {
  const ls = makeLocalStorageMock();
  writeStoredToken(ls, "abc123");
  assert.equal(ls._store.get("orgpad.token"), "abc123");
  assert.equal(readStoredToken(ls), "abc123");
});
t("writeStoredToken(null) clears the stored token (unpair)", () => {
  const ls = makeLocalStorageMock();
  writeStoredToken(ls, "abc123");
  writeStoredToken(ls, null);
  assert.equal(readStoredToken(ls), null);
  assert.equal(ls._store.has("orgpad.token"), false);
});
t("a localStorage that throws (private-mode Safari) degrades to null, not a crash", () => {
  const throwing = {
    getItem() { throw new Error("SecurityError"); },
    setItem() { throw new Error("SecurityError"); },
    removeItem() { throw new Error("SecurityError"); }
  };
  assert.equal(readStoredToken(throwing), null);
  assert.doesNotThrow(() => writeStoredToken(throwing, "x"));
});
t("resolveConfig composes with the localStorage-backed token exactly as the boot path does", () => {
  const ls = makeLocalStorageMock();
  writeStoredToken(ls, "persisted-tok");
  const cfg = {}; // server injected nothing (bare receiver tab)
  const resolved = C.resolveConfig(cfg, readStoredToken(ls));
  assert.equal(resolved.screen, "waiting");
  assert.equal(resolved.token, "persisted-tok");
});

console.log("== /result body still carries format:\"web\" (receiver reuses buildResultBody) ==");
t("buildResultBody unaffected by receiver additions", () => {
  const model = { v: C.SCHEMA, w: 100, h: 100, bg: "transparent", strokes: [] };
  const body = C.buildResultBody("recv-sess", "cGFuZ2Vk", model);
  assert.equal(body.session_id, "recv-sess");
  assert.equal(body.format, "web");
  assert.equal(body.png, "cGFuZ2Vk");
  assert.ok(typeof body.drawing === "string" && body.drawing.length > 0);
});
t("a full receiver loop iteration (parse session -> build result) round-trips", () => {
  // Simulate: GET /session gives us an edit session with strokes; we restore,
  // (pretend to draw more), then buildResultBody for POST /result.
  const editModel = { v: C.SCHEMA, w: 500, h: 500, bg: "dark",
    strokes: [{ tool: "marker", color: "#fff", width: 8, points: [[0, 0, 0.5], [10, 10, 0.5]] }] };
  const sessionJSON = { session_id: "loop-1", mode: "edit", name: "loop-fig",
    background: "dark", format: "web", drawing: C.utf8ToBase64(C.serialize(editModel)) };
  const parsed = C.parseSessionResponse(sessionJSON);
  const restored = C.deserialize(parsed.restoreJSON);
  assert.equal(restored.strokes.length, 1);
  // Append a stroke (simulating the user drawing more) and send it back.
  restored.strokes.push({ tool: "pen", color: "#f00", width: 4, points: [[20, 20, 0.7], [30, 30, 0.7]] });
  const resultBody = C.buildResultBody(parsed.sessionID, "cG5nYnl0ZXM=", restored);
  assert.equal(resultBody.session_id, "loop-1");
  assert.equal(resultBody.format, "web");
  const final = C.deserialize(C.base64ToUtf8(resultBody.drawing));
  assert.equal(final.strokes.length, 2);
});

console.log("\n" + passed + " assertions passed"
  + (process.exitCode ? " (with failures above)" : ", 0 failed"));
