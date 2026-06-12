/* Tarmac — shared cockpit primitives (exported to window) */

const TmWin = ({ children, style, label }) => (
  <div className="tm-win" style={style} data-screen-label={label}>{children}</div>
);

const Lights = ({ dim }) => (
  <div className={"tm-lights" + (dim ? " dim" : "")}><i className="r"></i><i className="y"></i><i className="g"></i></div>
);

const RepoDot = ({ c }) => (
  <span className="tm-repodot" style={{ background: `var(--tm-repo-${c})` }}></span>
);

const AgentDot = () => <span className="tm-agentdot"></span>;

const DocTab = ({ repo, c, name, active, agent, updated, waiting, ghost }) => (
  <div className={"tm-tab" + (active ? " on" : "") + (ghost ? " ghost" : "")}>
    <RepoDot c={c} />
    <span className="pre">{repo}/</span><span className="nm">{name}</span>
    {agent && <AgentDot />}
    {updated && <span className="upd"></span>}
    {waiting && <span className="wait"></span>}
  </div>
);

const TitleBar = ({ session, children, right, dim }) => (
  <div className="tm-titlebar">
    <Lights dim={dim} />
    {session && <span className="tm-session"><span className="glyph">▞</span>{session}</span>}
    <div className="tm-tabs">{children}</div>
    <div className="tm-tb-right">{right}</div>
  </div>
);

const Kbd = ({ k }) => <kbd className="tm-kbd">{k}</kbd>;

const AgentChip = ({ state }) => {
  if (state === "work") return <span className="tm-chip work"><span className="tm-blink">⠧</span>agent · working</span>;
  if (state === "wait") return <span className="tm-chip wait"><span className="wdot"></span>agent · waiting on you</span>;
  return <span className="tm-chip idle"><span className="idot"></span>agent · idle</span>;
};

const StatusBar = ({ children, right }) => (
  <div className="tm-status"><div className="l">{children}</div><div className="r">{right}</div></div>
);

/* ── terminal ── */
const TermTab = ({ label, active, run, wait }) => (
  <div className={"tm-ttab" + (active ? " on" : "")}>
    {run && <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span>}
    {wait && <span className="wdot"></span>}
    {label}
  </div>
);

const TermPane = ({ tabs, children, style }) => (
  <div className="tm-term" style={style}>
    {tabs && <div className="tm-ttabs">{tabs}<span className="plus">+</span></div>}
    {children}
  </div>
);

const TermBody = ({ children, style }) => <div className="tm-tbody" style={style}>{children}</div>;

const TermAgentRun = ({ short }) => (
  <React.Fragment>
    <div className="tl dim"># payments-api · feat/billing-retries</div>
    <div className="tl"><span className="cy">❯</span> <span className="wh">agent run --plan docs/plan.md</span></div>
    <div className="tl dim">  reading src/billing/retry.ts …</div>
    {!short && <div className="tl dim">  editing src/billing/retry.ts  +38 −12</div>}
    <div className="tl"><span className="gr">✓</span> tests · 41 passed <span className="dim">· 2.3s</span></div>
    <div className="tl"><span className="cy">✎</span> wrote docs/handoff.md <span className="dim">· 142 lines</span></div>
    <div className="tl"><span className="cy tm-blink">⠧</span> updating handoff — risk section …</div>
  </React.Fragment>
);

const TermWaiting = () => (
  <React.Fragment>
    <div className="tl dim"># infra · main</div>
    <div className="tl"><span className="cy">❯</span> <span className="wh">agent review --staged</span></div>
    <div className="tl"><span className="gr">✓</span> wrote docs/runbook.md</div>
    <div className="tl"><span className="am">▸</span> waiting for your call — see runbook.md §3</div>
    <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
  </React.Fragment>
);

const TermShell = () => (
  <React.Fragment>
    <div className="tl"><span className="dim">❯</span> <span className="wh">git log --oneline -3</span></div>
    <div className="tl dim">b41f2c9 retry: per-provider backoff</div>
    <div className="tl dim">a02d771 dlq: alert after 3 failures</div>
    <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
  </React.Fragment>
);

/* ── markdown doc ── */
const DocMeta = ({ repo, c, ago }) => (
  <div className="meta">
    <RepoDot c={c} /> {repo}/docs/handoff.md <span>·</span>
    <span className="ag">✎ agent rewrote {ago} ago</span>
  </div>
);

const DocBody = ({ repo = "payments-api", c = "a", ago = "2m", changed, compact }) => (
  <div className="tm-doc">
    <DocMeta repo={repo} c={c} ago={ago} />
    <h1>Handoff — billing retries</h1>
    <p>Retry scheduling for failed charges now runs on a dedicated queue with exponential backoff. The cron path is removed; everything below assumes the queue is deployed.</p>
    <div className={changed ? "tm-changed" : ""}>
      <h2>What changed</h2>
      <ul>
        <li><code>retry.ts</code> — backoff curve is configurable per provider <b>(+38 −12)</b></li>
        <li>Dead-letter handling moved to <code>dlq.ts</code>; alerts fire after 3 failures</li>
        {!compact && <li>Flag <code>billing_retry_v2</code> defaults <b>on</b> in staging</li>}
      </ul>
    </div>
    {!compact && (
      <React.Fragment>
        <pre>{`$ kubectl rollout status deploy/billing --timeout=120s
$ flagctl enable billing_retry_v2 --env=staging`}</pre>
        <h2>Open questions</h2>
        <ul>
          <li>Cap the total retry window at 48 h or 72 h?</li>
          <li>Who owns DLQ alert routing — payments or infra?</li>
        </ul>
      </React.Fragment>
    )}
  </div>
);

const DocBodyAlt = ({ compact }) => (
  <div className="tm-doc">
    <div className="meta"><RepoDot c="c" /> infra/docs/runbook.md <span>·</span> <span className="ag">✎ agent wrote 1m ago</span></div>
    <h1>Runbook — queue rollout</h1>
    <p>Steps to roll the new retry queue into staging, with checks between each step.</p>
    {!compact && (
      <ul>
        <li>Scale consumers to 2 before enabling the flag</li>
        <li>Watch <code>dlq_depth</code> for 10 min; rollback if &gt; 50</li>
      </ul>
    )}
  </div>
);

/* ── toast / sidebar / rail ── */
const Toast = ({ icon = "✚", title, body, keys }) => (
  <div className="tm-toast">
    <span className="ic">{icon}</span>
    <div className="bd">
      <div className="t">{title}</div>
      {body && <div className="b">{body}</div>}
    </div>
    {keys && <div className="keys">{keys.map((k) => <Kbd k={k} key={k} />)}</div>}
  </div>
);

const SideGroup = ({ repo, c, items }) => (
  <div className="tm-sgroup">
    <div className="hd"><RepoDot c={c} />{repo}</div>
    {items.map((it) => (
      <div className={"it" + (it.on ? " on" : "")} key={it.n}>
        {it.n}
        {it.agent && <AgentDot />}
        {it.upd && <span className="upd" style={{ width: 7, height: 7, borderRadius: "50%", background: "var(--tm-agent)", flex: "none" }}></span>}
      </div>
    ))}
  </div>
);

const RailItem = ({ t, ic, cls, label, hi }) => (
  <div className={"tm-rev" + (hi ? " hi" : "")}>
    <span className={"ic " + (cls || "")}>{ic}</span>
    <div className="tx"><span className="lb">{label}</span><span className="tt">{t}</span></div>
  </div>
);

const Annot = ({ children, style }) => <div className="tm-annot" style={style}>{children}</div>;

Object.assign(window, {
  TmWin, Lights, RepoDot, AgentDot, DocTab, TitleBar, Kbd, AgentChip, StatusBar,
  TermTab, TermPane, TermBody, TermAgentRun, TermWaiting, TermShell,
  DocMeta, DocBody, DocBodyAlt, Toast, SideGroup, RailItem, Annot,
});
