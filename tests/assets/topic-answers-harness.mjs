import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import assert from "node:assert/strict";

const html = readFileSync(process.argv[2], "utf8");
const decode = (text) => text.replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const attrs = (text) => Object.fromEntries([...text.matchAll(/([\w-]+)="([^"]*)"/g)]
  .map(([, key, value]) => [key, decode(value)]));
const field = (text) => {
  const attributes = attrs(text);
  return { value: attributes.value || "", checked: false,
    getAttribute: (name) => attributes[name] ?? null };
};
const cards = [...html.matchAll(/<div class="card decision">([\s\S]*?)<\/fieldset><\/div>/g)]
  .map(([, body]) => ({
    inputs: [...body.matchAll(/<input ([^>]+)>/g)].map(([, text]) => field(text)),
    textarea: field(body.match(/<textarea ([^>]+)>/)[1]),
    querySelector: () => ({ textContent: decode(body.match(/<p class="meta">([^<]*)<\/p>/)[1]) }),
  }));
assert.equal(cards.length, 1);
const handlers = {};
const elements = Object.fromEntries(["answers-line", "ans-count", "copy-answers"].map((id) => [id, {
  textContent: "", addEventListener: (type, handler) => { handlers[`${id}:${type}`] = handler; },
}]));
const document = {
  body: { getAttribute: (name) => attrs(html.match(/<body ([^>]+)>/)[1])[name] },
  getElementById: (id) => elements[id],
  addEventListener: (type, handler) => { handlers[type] = handler; },
  querySelectorAll: (selector) => {
    if (selector === ".decision") return cards;
    const index = Number(selector.match(/name="d(\d+)"/)[1]);
    return cards[index].inputs;
  },
  querySelector: (selector) => {
    const index = Number(selector.match(/(?:name="d|data-freetext=")(\d+)/)[1]);
    return selector.startsWith("input") ? cards[index].inputs.find((input) => input.checked) : cards[index].textarea;
  },
};
let copied;
runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], {
  document, navigator: { clipboard: { writeText: (text) => { copied = text; return Promise.resolve(); } } },
});
const card = cards[0];
card.inputs[0].checked = true;
handlers.change({ target: card.inputs[0] });
assert.equal(elements["answers-line"].textContent, "TOPIC-ANSWERS v1 | topic=tf-mut | answered=1/1 | t-dec=yolo on");
card.textarea.value = "use custom | path\nnow";
handlers.input({ target: card.textarea });
assert.ok(card.inputs.every((input) => !input.checked));
assert.equal(elements["answers-line"].textContent, "TOPIC-ANSWERS v1 | topic=tf-mut | answered=1/1 | t-dec=use custom ; path now");
card.inputs[1].checked = true;
handlers.change({ target: card.inputs[1] });
assert.equal(card.textarea.value, "");
handlers["copy-answers:click"]();
assert.equal(copied, "TOPIC-ANSWERS v1 | topic=tf-mut | answered=1/1 | t-dec=yolo off");
card.textarea.value = " ";
handlers.input({ target: card.textarea });
assert.equal(elements["answers-line"].textContent, "TOPIC-ANSWERS v1 | topic=tf-mut | answered=0/1");
