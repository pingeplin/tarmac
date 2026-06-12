/* Tarmac prototype — data: docs, strips, sim timeline */

const PDOCS = {
  "pay-handoff": { repo: "payments-api", c: "a", name: "docs/handoff.md", body: "handoff" },
  "pay-plan": { repo: "payments-api", c: "a", name: "docs/plan.md", body: "plan" },
  "infra-runbook": { repo: "infra", c: "c", name: "docs/runbook.md", body: "runbook" },
  "search-plan": { repo: "search-svc", c: "b", name: "docs/plan.md", body: "splan" },
  "search-notes": { repo: "search-svc", c: "b", name: "docs/notes.md", body: "notes" },
};

const GenericDoc = ({ title, repo, c, name, children }) => (
  <div className="tm-doc">
    <div className="meta"><RepoDot c={c} /> {repo}/{name}</div>
    <h1>{title}</h1>
    {children}
  </div>
);

const renderDocBody = (docId, changedRecently) => {
  const d = PDOCS[docId];
  switch (d.body) {
    case "handoff":
      return <DocBody changed={changedRecently} ago={changedRecently ? "just now" : "14:02"} />;
    case "runbook":
      return <DocBodyAlt />;
    case "plan":
      return (
        <GenericDoc title="Plan — billing retries" repo="payments-api" c="a" name="docs/plan.md">
          <p>Replace the cron-based retry sweep with a queue. Keep the public charge API unchanged.</p>
          <h2>Steps</h2>
          <ul>
            <li>Extract backoff policy into <code>retry.ts</code></li>
            <li>Add DLQ with alerting after 3 failures</li>
            <li>Flag: <code>billing_retry_v2</code>, staged rollout</li>
          </ul>
        </GenericDoc>
      );
    case "splan":
      return (
        <GenericDoc title="Plan — search relevance pass" repo="search-svc" c="b" name="docs/plan.md">
          <p>Tune BM25 weights against the click-through eval set before trying embeddings.</p>
          <ul>
            <li>Baseline: nDCG@10 = 0.61</li>
            <li>Field boosts: title ×2.2, body ×1.0</li>
          </ul>
        </GenericDoc>
      );
    case "notes":
      return (
        <GenericDoc title="Notes — eval harness" repo="search-svc" c="b" name="docs/notes.md">
          <p>Eval queries live in <code>eval/queries.jsonl</code>. Re-run with <code>make eval</code> after any analyzer change.</p>
        </GenericDoc>
      );
    default:
      return null;
  }
};

/* claude terminal script — t in ms from run start */
const CLAUDE_SCRIPT = [
  { t: 0, k: "hdr", text: "# payments-api · feat/billing-retries" },
  { t: 400, k: "cmd", text: 'claude "wire up billing retries per plan.md"' },
  { t: 2200, k: "step", text: "· read src/billing/retry.ts" },
  { t: 4200, k: "step", text: "· edit src/billing/retry.ts  +38 −12" },
  { t: 6600, k: "ok", text: "· ran npm test → 41 passed" },
  { t: 9200, k: "wrote", doc: "pay-handoff", text: "· wrote " },
  { t: 11800, k: "open", doc: "infra-runbook", text: "· ran tarmac open " },
  { t: 14200, k: "step", text: "· updating handoff — risk section …" },
  { t: 18400, k: "wrote", doc: "pay-handoff", text: "· wrote " },
  { t: 20800, k: "step", text: "· done · 9 files touched" },
];
const CLAUDE_EXIT_T = 21800;

const SIM_EVENTS = [
  { t: 9200, ev: "fileChange", doc: "pay-handoff" },
  { t: 11800, ev: "openDoc", doc: "infra-runbook" },
  { t: 12600, ev: "bell", term: "t-infra" },
  { t: 18400, ev: "fileChange", doc: "pay-handoff" },
  { t: CLAUDE_EXIT_T, ev: "exit" },
];

const STRIPS = {
  "infra-week": {
    label: "infra-week",
    dock: ["pay-handoff", "pay-plan", "search-plan", "search-notes"],
    terms: [
      { id: "t-claude", label: "payments-api", kind: "claude" },
      { id: "t-infra", label: "zsh · infra", kind: "waiting" },
      { id: "t-scratch", label: "scratch", kind: "shell" },
    ],
    sim: true,
  },
  "exp-search": {
    label: "exp-search",
    dock: ["search-plan", "search-notes"],
    terms: [
      { id: "t-dev", label: "npm run dev · search-svc", kind: "dev" },
      { id: "t-sh", label: "zsh · search-svc", kind: "shell" },
    ],
    sim: false,
  },
  "billing-fire": { label: "billing-fire", detached: true, dock: [], terms: [] },
};

Object.assign(window, { PDOCS, renderDocBody, CLAUDE_SCRIPT, CLAUDE_EXIT_T, SIM_EVENTS, STRIPS });
