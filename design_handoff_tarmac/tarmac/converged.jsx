/* Tarmac v2 — converged: terminal-first cockpit screens */

const DockDoc = ({ c, on, ad, wd }) => (
  <div className={"doc" + (on ? " on" : "")}>
    ¶
    <span className="rd" style={{ background: `var(--tm-repo-${c})` }}></span>
    {ad && <span className="ad"></span>}
    {wd && <span className="wd"></span>}
  </div>
);

const LeftDock = ({ expandedHint }) => (
  <div className="tm-dock">
    <DockDoc c="a" on />
    <DockDoc c="a" />
    <div className="gap"></div>
    <DockDoc c="c" ad />
    <div className="gap"></div>
    <DockDoc c="b" />
    <DockDoc c="b" wd />
    <div className="sep"></div>
    <div className="hint">{expandedHint || "⌘E index"}</div>
    <div className="foot"><span className="glyphbtn">▞</span></div>
  </div>
);

const TermFull = ({ children }) => (
  <TermPane
    style={{ flex: 1, minWidth: 0 }}
    tabs={<React.Fragment><TermTab label="payments-api" active run /><TermTab label="infra" wait /><TermTab label="scratch" /></React.Fragment>}
  >
    {children}
  </TermPane>
);

const RunwayBody = ({ link }) => (
  <React.Fragment>
    <div className="tl dim"># payments-api · feat/billing-retries</div>
    <div className="tl"><span className="cy">❯</span> <span className="wh">agent run --plan docs/plan.md</span></div>
    <div className="tl dim">  reading src/billing/retry.ts …</div>
    <div className="tl dim">  editing src/billing/retry.ts  +38 −12</div>
    <div className="tl"><span className="gr">✓</span> tests · 41 passed <span className="dim">· 2.3s</span></div>
    <div className="tl"><span className="cy">✎</span> wrote <span className={"tm-doclink" + (link === "hover" ? " hover" : "")}>docs/handoff.md</span> <span className="dim">· 142 lines</span></div>
    <div className="tl"><span className="cy">✚</span> opened <span className="tm-doclink">infra/docs/runbook.md</span> <span className="dim">— “rollout steps ready”</span></div>
    <div className="tl"><span className="cy tm-blink">⠧</span> updating handoff — risk section …</div>
    <div className="tl">&nbsp;</div>
    <div className="tl"><span className="dim">❯</span> <span className="wh">git diff --stat</span></div>
    <div className="tl dim"> src/billing/retry.ts | 50 ++++++----</div>
    <div className="tl dim"> src/billing/dlq.ts   | 18 +++</div>
    <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
  </React.Fragment>
);

/* R1 · Runway — terminal is the whole cockpit */
const R1Runway = () => (
  <TmWin label="v2 · Runway (default)">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermFull><TermBody><RunwayBody /></TermBody></TermFull>
        <div className="tm-split"></div>
        <TermPane style={{ flex: "none", height: 150 }}>
          <TermBody><TermShell /></TermBody>
        </TermPane>
      </div>
    </div>
    <StatusBar right={<React.Fragment><span style={{ color: "var(--tm-agent)" }}>2 unread docs · ⌘P peek</span><span>6 docs · 3 repos</span></React.Fragment>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* R2 · Peek — viewer summoned as slide-over, terminal keeps focus */
const R2Peek = () => (
  <TmWin label="v2 · Peek viewer">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermFull><TermBody><RunwayBody /></TermBody></TermFull>
      </div>
      <div className="tm-peek">
        <div className="phd">
          <RepoDot c="a" /> payments-api/docs/handoff.md
          <span style={{ color: "var(--tm-agent)", opacity: 0.85 }}>✎ 5s</span>
          <span className="pin"><Kbd k="⌘⏎ pin" /><Kbd k="esc" /></span>
        </div>
        <div className="pbody tm-docwrap"><DocBody changed compact ago="5s" /></div>
      </div>
    </div>
    <StatusBar right={<span>peek · focus stays in terminal</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
    </StatusBar>
  </TmWin>
);

/* R3 · Pin — doc pinned as a tile; terminal stays dominant */
const R3Pin = () => (
  <TmWin label="v2 · Pinned tile">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div className="tm-deskbg" style={{ gridTemplateColumns: "1.45fr 1fr", gridTemplateRows: "1fr" }}>
        <div className="tm-tile">
          <div className="thd"><span className="kind">›_</span> term · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></div>
          <TermPane style={{ flex: 1 }}><TermBody><RunwayBody /></TermBody></TermPane>
        </div>
        <div className="tm-tile">
          <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> payments-api/docs/handoff.md <span style={{ marginLeft: "auto", color: "var(--tm-faint)", font: "400 9.5px var(--tm-mono)" }}>unpin ⌘⏎</span></div>
          <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
        </div>
      </div>
    </div>
    <StatusBar right={<span>1 pinned · 5 in dock</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* R4 · Index — dock expands into repo-grouped index */
const R4Index = () => (
  <TmWin label="v2 · Index expanded">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <div className="tm-side" style={{ width: 224 }}>
        <div className="cap">OPEN DOCS · ⌘E</div>
        <SideGroup repo="payments-api" c="a" items={[{ n: "handoff.md", on: true }, { n: "plan.md" }]} />
        <SideGroup repo="infra" c="c" items={[{ n: "runbook.md", agent: true, upd: true }]} />
        <SideGroup repo="search-svc" c="b" items={[{ n: "plan.md" }, { n: "notes.md", agent: true }]} />
        <div style={{ font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "6px 8px" }}>⏎ peek · ⌘⏎ pin · ⌫ close</div>
        <div className="foot"><span className="glyph">▞</span>infra-week <span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>▾</span></div>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermFull><TermBody><RunwayBody /></TermBody></TermFull>
      </div>
    </div>
    <StatusBar right={<span>6 docs · 3 repos</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
    </StatusBar>
  </TmWin>
);

/* R5 · Rail — strips + agent activity on the right */
const R5Rail = () => (
  <TmWin label="v2 · Strips + activity rail">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermFull><TermBody><RunwayBody /></TermBody></TermFull>
      </div>
      <div className="tm-rail2">
        <div className="cap">STRIPS · ⌘K</div>
        <div className="tm-strip on"><span className="glyph">▞</span> infra-week <span className="meta"><span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> 6 docs</span></div>
        <div className="tm-strip"><span className="glyph">▞</span> exp-search <span className="meta">3 docs</span></div>
        <div className="tm-strip off"><span className="glyph">▞</span> billing-fire <span className="meta"><span style={{ color: "var(--tm-amber)" }}>● waiting</span></span></div>
        <div className="sep"></div>
        <div className="cap">ACTIVITY · infra-week</div>
        <RailItem t="14:02" ic="✎" label="rewrote payments-api/handoff.md" hi />
        <RailItem t="13:58" ic="✚" label="opened infra/runbook.md" />
        <RailItem t="13:55" ic="✓" cls="ok" label="tests passed · 41" />
        <RailItem t="13:47" ic="▸" cls="wait" label="waiting — DLQ alert routing?" />
        <div style={{ marginTop: "auto", font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "8px 6px", borderTop: "1px solid var(--tm-line-soft)" }}>
          ⏎ peek doc · ⌘J jump
        </div>
      </div>
    </div>
    <StatusBar right={<span>3 strips · 1 waiting</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* R6 · Doc links in terminal output — the summon affordance */
const R6Links = () => (
  <TmWin label="v2 · Doc links in output">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermFull><TermBody><RunwayBody link="hover" /></TermBody></TermFull>
      </div>
      <div className="tm-linkhint" style={{ left: 248, top: 188 }}>
        <span style={{ color: "var(--tm-agent)" }}>¶</span> handoff.md · ✎ 5s ago
        <span style={{ display: "flex", gap: 5 }}><Kbd k="⌘click peek" /><Kbd k="⌘⏎ pin" /></span>
      </div>
    </div>
    <StatusBar right={<span style={{ color: "var(--tm-agent)" }}>2 unread docs · ⌘P peek</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { R1Runway, R2Peek, R3Pin, R4Index, R5Rail, R6Links });
