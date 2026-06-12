/* Tarmac — Section 01: four overall directions (1180×740 each) */

/* A · Two-up — classic fixed split, tabs in the titlebar */
const DirA = () => (
  <TmWin label="Direction A · Two-up">
    <TitleBar
      session="infra-week"
      right={<span style={{ font: "400 11px var(--tm-mono)", color: "var(--tm-faint)", display: "flex", gap: 10 }}><span>▤</span><span style={{ color: "var(--tm-muted)" }}>▥</span></span>}
    >
      <DocTab repo="payments-api" c="a" name="handoff.md" active agent />
      <DocTab repo="infra" c="c" name="runbook.md" agent updated />
      <DocTab repo="search-svc" c="b" name="plan.md" />
    </TitleBar>
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <div className="tm-docwrap" style={{ flex: "0 0 57%" }}>
        <DocBody />
      </div>
      <div style={{ width: 1, background: "var(--tm-line)", position: "relative", flex: "none" }}>
        <div style={{ position: "absolute", top: "50%", left: -2, width: 5, height: 38, marginTop: -19, borderRadius: 3, background: "var(--tm-line)" }}></div>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermPane
          style={{ flex: "1 1 58%" }}
          tabs={<React.Fragment><TermTab label="payments-api" active run /><TermTab label="scratch" /></React.Fragment>}
        >
          <TermBody><TermAgentRun /></TermBody>
        </TermPane>
        <div className="tm-split"></div>
        <TermPane style={{ flex: "1 1 42%" }}>
          <TermBody><TermShell /></TermBody>
        </TermPane>
      </div>
    </div>
    <StatusBar right={<React.Fragment><span>3 docs · 3 repos</span><AgentChip state="work" /></React.Fragment>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* B · Index — sidebar grouped by repo, terminal as full-width runway strip */
const DirB = () => (
  <TmWin label="Direction B · Index">
    <TitleBar session="infra-week" right={<AgentChip state="work" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <div className="tm-side">
        <div className="cap">OPEN DOCS</div>
        <SideGroup repo="payments-api" c="a" items={[{ n: "handoff.md", on: true }, { n: "plan.md" }]} />
        <SideGroup repo="infra" c="c" items={[{ n: "runbook.md", agent: true, upd: true }]} />
        <SideGroup repo="search-svc" c="b" items={[{ n: "plan.md" }, { n: "notes.md" }]} />
        <div className="foot"><span className="glyph">▞</span>infra-week <span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>▾</span></div>
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <div className="tm-docwrap" style={{ flex: 1 }}>
          <DocBody compact />
        </div>
        <TermPane
          style={{ flex: "none", height: 218, borderTop: "1px solid var(--tm-line)" }}
          tabs={<React.Fragment><TermTab label="payments-api" active run /><TermTab label="infra" wait /></React.Fragment>}
        >
          <TermBody><TermAgentRun short /></TermBody>
        </TermPane>
      </div>
    </div>
    <StatusBar right={<span>5 docs · 3 repos</span>}>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached · 2 windows</span></span>
    </StatusBar>
  </TmWin>
);

/* C · Tiles — free panes: docs and terminals as movable peers */
const DirC = () => (
  <TmWin label="Direction C · Tiles">
    <TitleBar
      session={null}
      right={<AgentChip state="work" />}
    >
      <div className="tm-tab on" style={{ fontWeight: 500 }}><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</div>
      <div className="tm-tab"><span style={{ color: "var(--tm-faint)" }}>▞</span> exp-search</div>
    </TitleBar>
    <div className="tm-deskbg" style={{ gridTemplateColumns: "1.1fr 1fr", gridTemplateRows: "1.35fr 1fr" }}>
      <div className="tm-tile">
        <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> payments-api/docs/handoff.md</div>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
      </div>
      <div className="tm-tile">
        <div className="thd"><span className="kind">›_</span> term · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></div>
        <TermPane style={{ flex: 1 }}><TermBody><TermAgentRun short /></TermBody></TermPane>
      </div>
      <div style={{ position: "relative", minHeight: 0 }}>
        <div className="tm-dropslot" style={{ position: "absolute", inset: 0 }}></div>
        <div className="tm-tile lift" style={{ position: "absolute", inset: "6px -14px -2px 10px" }}>
          <div className="thd"><span className="kind">¶</span><RepoDot c="c" /> infra/docs/runbook.md <AgentDot /></div>
          <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
        </div>
      </div>
      <div className="tm-tile">
        <div className="thd"><span className="kind">›_</span> term · infra <span className="wdot" style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)" }}></span></div>
        <TermPane style={{ flex: 1 }}><TermBody><TermWaiting /></TermBody></TermPane>
      </div>
    </div>
    <StatusBar right={<span>2 docs · 2 terms</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* D · Tower — reading mode + agent activity rail + terminal drawer */
const DirD = () => (
  <TmWin label="Direction D · Tower">
    <TitleBar session={null} right={<AgentChip state="work" />}>
      <div style={{ font: "400 11px var(--tm-mono)", color: "var(--tm-muted)", display: "flex", alignItems: "center", gap: 7 }}>
        <RepoDot c="a" /> payments-api / docs / <span style={{ color: "var(--tm-text)" }}>handoff.md</span>
      </div>
    </TitleBar>
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <div className="tm-docwrap" style={{ flex: 1, display: "flex", justifyContent: "center" }}>
          <div style={{ width: 640 }}><DocBody compact /></div>
        </div>
        <div className="tm-drawer" style={{ height: 168 }}>
          <div className="grab"></div>
          <TermPane style={{ height: "100%" }} tabs={<React.Fragment><TermTab label="payments-api" active run /><TermTab label="infra" wait /></React.Fragment>}>
            <TermBody><TermAgentRun short /></TermBody>
          </TermPane>
        </div>
      </div>
      <div className="tm-rail">
        <div className="cap">AGENT ACTIVITY</div>
        <RailItem t="14:02" ic="✎" label="rewrote payments-api/handoff.md" hi />
        <RailItem t="13:58" ic="✚" label="opened infra/runbook.md" />
        <RailItem t="13:55" ic="✓" cls="ok" label="tests passed · 41" />
        <RailItem t="13:47" ic="▸" cls="wait" label="waiting — DLQ alert routing?" />
        <RailItem t="13:31" ic="✚" label="opened search-svc/plan.md" />
        <div style={{ marginTop: "auto", font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "8px 6px", borderTop: "1px solid var(--tm-line-soft)" }}>
          ⌘J jump to event · ⌫ undo focus
        </div>
      </div>
    </div>
    <StatusBar right={<span>3 docs · 3 repos</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { DirA, DirB, DirC, DirD });
