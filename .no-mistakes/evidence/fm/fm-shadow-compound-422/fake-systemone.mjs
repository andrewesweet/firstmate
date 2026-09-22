// Local stand-in for POST /v1/systemone: enforces the one rule the real API
// rejected with HTTP 422 (every questions[key] must be a typed question),
// logs every request body, and answers each typed question.
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
const log = process.argv[2];
const srv = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    appendFileSync(log, body + "\n");
    const j = JSON.parse(body);
    const bad = Object.entries(j.questions ?? {}).filter(([, q]) => !q || typeof q.type !== "string");
    if (bad.length) {
      res.writeHead(422, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: `untyped question(s): ${bad.map(([k]) => k).join(",")}` }));
      return;
    }
    const answers = {};
    for (const [k, q] of Object.entries(j.questions)) {
      if (q.type === "noul") answers[k] = { type: "noul", noul: k.endsWith("ship-b") ? 0.9 : 0.1 };
      else if (q.type === "choice") answers[k] = { type: "choice", choice: q.options?.[0] ?? "routine", confidence: 0.9, probabilities: {} };
      else answers[k] = { type: q.type, score: 1, confidence: 0.8, probabilities: [] };
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ model: "jev-fake", answers }));
  });
});
srv.listen(0, "127.0.0.1", () => { console.log(srv.address().port); });
