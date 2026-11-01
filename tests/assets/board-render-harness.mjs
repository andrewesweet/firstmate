// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      remove: (c) => { this.className = this.className.split(/\s+/).filter((name) => name !== c).join(" "); },
      toggle: (c, enabled) => { if (enabled) this.classList.add(c); else this.classList.remove(c); },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, handler) { this.listeners[type] = handler; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queued = [];
globalThis.window = { lavish: { queuePrompt: (prompt, { tag, text, data }) => { queued.push({ prompt, tag, text, data }); } } };
const descendants = (node) => node.children.flatMap((child) => [child, ...descendants(child)]);
globalThis.FormData = class {
  constructor(form) { this.inputs = descendants(form).filter((node) => node.tagName === "input"); }
  get(name) { return this.inputs.find((input) => input.name === name && (input.type !== "radio" || input.checked))?.value ?? null; }
};
globalThis.setTimeout = () => 0;
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();
if (process.argv[3] || process.argv[5] !== undefined) {
  const form = descendants(byId.get("bb-call")).find((node) => node.tagName === "form"
    && (!process.argv[4] || node.attributes["data-lavish-question"] === process.argv[4]));
  if (process.argv[3]) {
    const input = descendants(form).find((node) => node.type === "radio" && node.value === process.argv[3]);
    if (!input) throw new Error("requested option was not rendered");
    input.checked = true;
  }
  if (process.argv[5] !== undefined) descendants(form).find((node) => node.name === "note").value = process.argv[5];
  form.listeners.submit({ preventDefault() {} });
}

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        artifacts: row.children.filter((c) => c.className.includes("bb-row__pr")).map((c) => ({text: c.textContent, href: c.href ?? null})),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const landed = rowsOf(byId.get("bb-landed") || new Node("div"));
const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const options = descendants(byId.get("bb-call")).filter((node) => node.className === "bb-opt__label").map((node) => node.textContent);
const questions = descendants(byId.get("bb-call")).filter((node) => node.tagName === "form").map((node) => node.attributes["data-lavish-question"]);
process.stdout.write(
  JSON.stringify({ options, questions, stats, underway, landed, charted, empty, more, error: errorText, queued }) + "\n");
