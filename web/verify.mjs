// verify.mjs — unit tests for the pure OrgPadCore functions inside canvas.html.
// Extracts the CORE-START..CORE-END block from canvas.html, evaluates it in a
// Node vm context (so it is the EXACT source shipped in the browser), and
// asserts on serialization round-trips, export-rect math, base64, and the
// shape classifier.
//
// Run:  node verify.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, "canvas.html"), "utf-8");

// --- extract the shared core verbatim ---
const m = html.match(/\/\* CORE-START \*\/([\s\S]*?)\/\* CORE-END \*\//);
assert.ok(m, "CORE-START/CORE-END markers not found in canvas.html");
const coreSrc = m[1];

// evaluate in a sandbox that mimics Node module globals (Buffer available)
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
// Cross-realm-safe structural equality (vm sandbox objects have a different
// Array/Object prototype than the main realm, which trips eqVal's
// strict prototype check). Compare by JSON value instead.
function eqVal(a, b, msg) {
  assert.equal(JSON.stringify(a), JSON.stringify(b), msg);
}

console.log("== constants ==");
t("format byte value is 'web'", () => assert.equal(C.WEB_FORMAT, "web"));
t("schema version is a number", () => assert.equal(typeof C.SCHEMA, "number"));
t("export geometry constants match Swift", () => {
  assert.equal(C.PAD, 20); assert.equal(C.MIN_W, 200); assert.equal(C.MIN_H, 150);
});

console.log("== base64 round-trip (JSON) ==");
t("ascii round-trip", () => {
  const s = '{"hello":"world","n":42}';
  assert.equal(C.base64ToUtf8(C.utf8ToBase64(s)), s);
});
t("unicode round-trip", () => {
  const s = JSON.stringify({ note: "café — ∑ 数学 🎨", n: 1 });
  assert.equal(C.base64ToUtf8(C.utf8ToBase64(s)), s);
});
t("base64 is standard (matches Buffer)", () => {
  const s = "org-pad-web-canvas";
  assert.equal(C.utf8ToBase64(s), Buffer.from(s, "utf-8").toString("base64"));
});

console.log("== serialize/deserialize round-trip ==");
const sampleModel = {
  v: C.SCHEMA, w: 1024, h: 768, bg: "transparent",
  strokes: [
    { tool: "pen", color: "#1c1c1e", width: 4,
      points: [[10.123, 20.987, 0.4], [30.5, 40.5, 0.9], [55, 60]] },
    { tool: "highlighter", color: "#ffd60a", width: 12,
      points: [[100, 100, 0.5], [200, 100, 0.5]] },
    { tool: "pen", color: "#0a84ff", width: 3, shape: "rect", a: [5, 5], b: [95, 55] },
    { tool: "pen", color: "#ff453a", width: 2, shape: "arrow", a: [0, 0], b: [120, 120] }
  ]
};
t("round-trip preserves structure", () => {
  const json = C.serialize(sampleModel);
  const back = C.deserialize(json);
  assert.equal(back.strokes.length, sampleModel.strokes.length);
  assert.equal(back.w, 1024); assert.equal(back.h, 768);
  assert.equal(back.bg, "transparent");
  assert.equal(back.strokes[0].tool, "pen");
  assert.equal(back.strokes[2].shape, "rect");
  eqVal(back.strokes[2].a, [5, 5]);
  eqVal(back.strokes[2].b, [95, 55]);
  assert.equal(back.strokes[3].shape, "arrow");
});
t("missing pressure defaults to 0.5", () => {
  const back = C.deserialize(C.serialize(sampleModel));
  const p = back.strokes[0].points[2];
  assert.equal(p[2], 0.5);
});
t("serialize is valid parseable JSON", () => {
  const parsed = JSON.parse(C.serialize(sampleModel));
  assert.equal(parsed.v, C.SCHEMA);
  assert.ok(Array.isArray(parsed.strokes));
});
t("double round-trip is stable", () => {
  const once = C.deserialize(C.serialize(sampleModel));
  const twice = C.deserialize(C.serialize(once));
  assert.equal(C.serialize(once), C.serialize(twice));
});
t("coordinates rounded to <=2 decimals", () => {
  const parsed = JSON.parse(C.serialize(sampleModel));
  const x = parsed.strokes[0].points[0][0];
  assert.ok(Math.abs(x - 10.12) < 1e-9, "expected 10.12, got " + x);
});

console.log("== result body (what /result receives) ==");
t("buildResultBody has the four required fields incl. format:web", () => {
  const body = C.buildResultBody("sess-123", "iVBORw0KGgo=", sampleModel);
  assert.equal(body.session_id, "sess-123");
  assert.equal(body.png, "iVBORw0KGgo=");
  assert.equal(body.format, "web");
  // drawing is base64 of the serialized JSON
  const decoded = C.base64ToUtf8(body.drawing);
  const model = C.deserialize(decoded);
  assert.equal(model.strokes.length, sampleModel.strokes.length);
});
t("result body drawing decodes to the same drawing", () => {
  const body = C.buildResultBody("s", "png", sampleModel);
  assert.equal(C.base64ToUtf8(body.drawing), C.serialize(sampleModel));
});

console.log("== bounding box / export rect math ==");
t("null strokes => default rect", () => {
  const r = C.exportRect(null);
  eqVal(r, { x: 0, y: 0, w: 200, h: 150 });
});
t("empty stroke list => null bounds => default rect", () => {
  assert.equal(C.strokeBounds([]), null);
  const r = C.exportRectForStrokes([]);
  eqVal(r, { x: 0, y: 0, w: 200, h: 150 });
});
t("small drawing is padded to min size, centered", () => {
  // a tiny 10x10 stroke (width 0 for exactness of geometry)
  const strokes = [{ tool: "pen", color: "#000", width: 0,
                     points: [[100, 100], [110, 110]] }];
  const b = C.strokeBounds(strokes);
  // width>=1 half-extent clamps, so account for it: use the rect instead
  const r = C.exportRect({ x: 100, y: 100, w: 10, h: 10 });
  assert.equal(r.w, 200); assert.equal(r.h, 150);
  // centered on (105,105)
  assert.ok(Math.abs((r.x + r.w / 2) - 105) < 1e-9);
  assert.ok(Math.abs((r.y + r.h / 2) - 105) < 1e-9);
});
t("large drawing gets PAD inset on each side", () => {
  const r = C.exportRect({ x: 0, y: 0, w: 500, h: 400 });
  assert.equal(r.x, -20); assert.equal(r.y, -20);
  assert.equal(r.w, 540); assert.equal(r.h, 440);
});
t("bounds account for stroke width", () => {
  const strokes = [{ tool: "pen", color: "#000", width: 10,
                     points: [[100, 100], [200, 100]] }];
  const b = C.strokeBounds(strokes);
  // half-width extends the box on all sides (>= width used as half-extent)
  assert.ok(b.x <= 90, "x extended by width, got " + b.x);
  assert.ok(b.x + b.w >= 210, "right edge extended, got " + (b.x + b.w));
});
t("shape strokes contribute to bounds", () => {
  const strokes = [{ tool: "pen", color: "#000", width: 2, shape: "rect",
                     a: [50, 50], b: [150, 120] }];
  const b = C.strokeBounds(strokes);
  assert.ok(b.x <= 50 && b.y <= 50);
  assert.ok(b.x + b.w >= 150 && b.y + b.h >= 120);
});

console.log("== shape classifier ==");
function poly(fn, n) {
  const out = []; for (let i = 0; i <= n; i++) out.push(fn(i / n)); return out;
}
t("straight drag classifies as line", () => {
  const pts = poly(t => [10 + t * 200, 30 + t * 5], 40);  // near-horizontal
  const cls = C.classifyShape(pts);
  assert.ok(cls, "expected a classification");
  assert.equal(cls.shape, "line");
});
t("closed circle classifies as ellipse", () => {
  const pts = poly(t => {
    const a = t * 2 * Math.PI;
    return [200 + 80 * Math.cos(a), 200 + 80 * Math.sin(a)];
  }, 60);
  const cls = C.classifyShape(pts);
  assert.ok(cls, "expected a classification");
  assert.equal(cls.shape, "ellipse");
});
t("closed axis-aligned box classifies as rect", () => {
  const pts = [];
  const push = (x, y) => pts.push([x, y]);
  for (let i = 0; i <= 20; i++) push(100 + i * 5, 100);       // top
  for (let i = 0; i <= 20; i++) push(200, 100 + i * 4);       // right
  for (let i = 0; i <= 20; i++) push(200 - i * 5, 180);       // bottom
  for (let i = 0; i <= 20; i++) push(100, 180 - i * 4);       // left
  const cls = C.classifyShape(pts);
  assert.ok(cls, "expected a classification");
  assert.equal(cls.shape, "rect");
});
t("closed triangle classifies as triangle", () => {
  const A = [100, 300], B = [300, 300], Cx = [200, 100];
  const pts = [];
  const seg = (p, q, n) => { for (let i = 0; i < n; i++) pts.push([p[0] + (q[0] - p[0]) * i / n, p[1] + (q[1] - p[1]) * i / n]); };
  seg(A, B, 20); seg(B, Cx, 20); seg(Cx, A, 20); pts.push(A);
  const cls = C.classifyShape(pts);
  assert.ok(cls, "expected a classification");
  assert.equal(cls.shape, "triangle");
  assert.ok(Array.isArray(cls.corners) && cls.corners.length === 3);
});
t("tiny scribble returns null (no shape)", () => {
  const pts = [[10, 10], [11, 12], [10, 11]];
  assert.equal(C.classifyShape(pts), null);
});
t("open squiggle (non-straight) returns null", () => {
  const pts = poly(t => [10 + t * 200, 100 + 40 * Math.sin(t * 12)], 60);
  const cls = C.classifyShape(pts);
  assert.equal(cls, null);
});

console.log("== stroke smoothing ==");
t("smoothStroke keeps endpoints and adds points", () => {
  const pts = [[0, 0, 0.5], [10, 0, 0.5], [10, 10, 0.5], [0, 10, 0.5]];
  const out = C.smoothStroke(pts, 1);
  eqVal(out[0], pts[0]);
  eqVal(out[out.length - 1], pts[pts.length - 1]);
  assert.ok(out.length > pts.length);
});
t("smoothStroke preserves pressure channel", () => {
  const out = C.smoothStroke([[0, 0, 0.2], [10, 0, 0.8], [20, 0, 0.4]], 1);
  out.forEach(p => { assert.ok(p[2] >= 0 && p[2] <= 1); });
});
t("smoothStroke no-op on <3 points", () => {
  const pts = [[0, 0, 0.5], [10, 0, 0.5]];
  eqVal(C.smoothStroke(pts, 2), pts);
});

console.log("\n" + passed + " assertions passed"
  + (process.exitCode ? " (with failures above)" : ", 0 failed"));
