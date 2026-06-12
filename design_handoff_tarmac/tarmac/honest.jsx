/* Tarmac v3 — no-harness honest signals: process table + fswatch + CLI + bell */

/* a terminal session that is just `claude` running — Tarmac doesn't parse it,
   only linkifies paths in output (regex, like semantic links in iTerm) */
const ClaudeRun = ({ link }) => (
  <React.Fragment>
    <div className="tl dim"># payments-api · feat/billing-retries</div>
    <div className="tl"><span className="dim">❯</span> <span className="wh">claude "wire up billing retries per plan.md"</span></div>
    <div className="tl dim">  · read src/billing/retry.ts</div>
    <div className="tl dim">  · edit src/billing/retry.ts  +38 −12</div>
    <div className="tl dim">  · ran npm test → <span className="gr">41 passed</span></div>
    <div className="tl dim">  · wrote <span className={"tm-doclink" + (link ? " hover" : "")}>docs/handoff.md</span></div>
    <div className="tl dim">  · ran tarmac open <span className="tm-doclink">docs/handoff.md</span></div>
    <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>
  </React.Fragment>
);

const DevServer = () => (
  <React.Fragment>
    <div className="tl dim"># search-svc</div>
    <div className="tl"><span className="dim">❯</span> <span className="wh">npm run dev</span></div>
    <div className="tl dim">  ready on :3000 · watching</div>
  </React.Fragment>
);

/* process-based status chip — replaces semantic AgentChip */
const ProcChip = ({ kind }) => {
  if (kind === "run") return <span className="tm-chip work"><span className="tm-blink">⠧</span>claude · 4m12s</span>;
  if (kind === "bell") return <span className="tm-chip wait"><span className="wdot"></span>bell · infra · 3m ago</span>;
  if (kind === "exit") return <span className="tm-chip idle"><span style={{ color: "var(--tm-ok)" }}>✓</span>pytest · exit 0</span>;
  return <span className="tm-chip idle"><span className="idot"></span>zsh · at prompt</span>;
};

/* H1 · Runway — tab label IS the foreground process name */
const H1Runway = () => (
  <TmWin label="v3 · Runway">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermPane
          style={{ flex: 1, minWidth: 0 }}
          tabs={<React.Fragment><TermTab label="claude · payments-api" active run /><TermTab label="zsh · infra" wait /><TermTab label="npm run dev · search-svc" /></React.Fragment>}
        >
          <TermBody><ClaudeRun /></TermBody>
        </TermPane>
        <div className="tm-split"></div>
        <TermPane style={{ flex: "none", height: 150 }}>
          <TermBody><TermShell /></TermBody>
        </TermPane>
      </div>
    </div>
    <StatusBar right={<React.Fragment><span style={{ color: "var(--tm-agent)" }}>2 docs changed · ⌘P peek</span><span>6 docs · 3 repos</span></React.Fragment>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* H2 · Rail — PROCESSES (the real "agent activities") + FILE EVENTS + STRIPS */
const H2Rail = () => (
  <TmWin label="v3 · Processes rail">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermPane style={{ flex: 1, minWidth: 0 }} tabs={<TermTab label="claude · payments-api" active run />}>
          <TermBody><ClaudeRun /></TermBody>
        </TermPane>
      </div>
      <div className="tm-rail2">
        <div className="cap">STRIPS · ⌘K</div>
        <div className="tm-strip on"><span className="glyph">▞</span> infra-week <span className="meta"><span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> 2 running</span></div>
        <div className="tm-strip"><span className="glyph">▞</span> exp-search <span className="meta">1 running</span></div>
        <div className="tm-strip off"><span className="glyph">▞</span> billing-fire <span className="meta"><span style={{ color: "var(--tm-amber)" }}>● bell</span></span></div>
        <div className="sep"></div>
        <div className="cap">PROCESSES</div>
        <RailItem t="started 14:02 · 4m" ic="⠧" label="claude — payments-api" hi />
        <RailItem t="up 2h · :3000" ic="⠧" label="npm run dev — search-svc" />
        <RailItem t="bell 3m ago" ic="◉" cls="wait" label="zsh — infra · at prompt" />
        <RailItem t="13:55 · exit 0" ic="✓" cls="ok" label="pytest — payments-api" />
        <div className="sep"></div>
        <div className="cap">FILE EVENTS · fswatch</div>
        <RailItem t="5s ago · while claude ran" ic="✎" label="payments-api/handoff.md" hi />
        <RailItem t="13:58" ic="✎" label="infra/runbook.md" />
        <div style={{ marginTop: "auto", font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "8px 6px", borderTop: "1px solid var(--tm-line-soft)" }}>
          ⏎ jump to tab / peek doc
        </div>
      </div>
    </div>
    <StatusBar right={<span>4 procs · 1 bell</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* H3 · Peek — meta line is honest: mtime + which process was in foreground */
const H3Peek = () => (
  <TmWin label="v3 · Peek (honest meta)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermPane style={{ flex: 1, minWidth: 0 }} tabs={<TermTab label="claude · payments-api" active run />}>
          <TermBody><ClaudeRun /></TermBody>
        </TermPane>
      </div>
      <div className="tm-peek">
        <div className="phd">
          <RepoDot c="a" /> payments-api/docs/handoff.md
          <span style={{ color: "var(--tm-agent)", opacity: 0.85 }}>✎ 5s · during claude</span>
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

/* H4 · Signal anatomy — every mark maps to an observable fact */
const H4Signals = () => (
  <div style={{ width: "100%", height: "100%", background: "var(--tm-bg0)", borderRadius: 10, border: "1px solid #2a3039", display: "flex", flexDirection: "column", justifyContent: "center", gap: 19, padding: "0 40px" }}>
    {[
      { el: <DocTab repo="payments-api" c="a" name="handoff.md" agent />, note: "青點 = 這份是經 tarmac open 從 shell 打開的(來源:CLI 呼叫)。誰跑的指令無所謂 — 不猜意圖。" },
      { el: <DocTab repo="payments-api" c="a" name="handoff.md" updated />, note: "光環脈衝 = 檔案在磁碟上剛變了(來源:fswatch mtime)。30s 後安靜。" },
      { el: <TermTab label="claude · payments-api" active run />, note: "terminal tab 標籤 = 前景程序名 + cwd repo(來源:process 表)。⠧ = 還在跑。" },
      { el: <TermTab label="zsh · infra" wait />, note: "琥珀點 = 背景 tab 響過 bell(來源:BEL 字元)。這是唯一的「等你」訊號 — 由工具自己發。" },
      { el: <span className="tl" style={{ font: "400 12px var(--tm-mono)" }}>  · wrote <span className="tm-doclink">docs/handoff.md</span></span>, note: "輸出裡的路徑自動連結化(來源:regex,如 semantic links)。⌘click peek — 不解析語意,只認路徑。" },
    ].map((s, i) => (
      <div key={i} style={{ display: "flex", alignItems: "center", gap: 26 }}>
        <div style={{ flex: "none", width: 330, display: "flex", transform: "scale(1.2)", transformOrigin: "left center" }}>{s.el}</div>
        <Annot style={{ color: "var(--tm-muted)", flex: 1 }}>{s.note}</Annot>
      </div>
    ))}
  </div>
);

/* H5 · Process finished — exit status is the "done" moment */
const H5Exit = () => (
  <TmWin label="v3 · Process exited">
    <TitleBar session="infra-week" right={<ProcChip kind="exit" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <LeftDock />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <TermPane style={{ flex: 1, minWidth: 0 }} tabs={<React.Fragment><TermTab label="zsh · payments-api" active /><TermTab label="npm run dev · search-svc" /></React.Fragment>}>
          <TermBody>
            <div className="tl dim">  · wrote <span className="tm-doclink">docs/handoff.md</span></div>
            <div className="tl dim">  · done · 9 files touched</div>
            <div className="tl"><span className="gr">✓</span> <span className="dim">claude exited 0 · ran 6m24s</span></div>
            <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
          </TermBody>
        </TermPane>
      </div>
      <Toast icon="✓" title="claude exited 0 · 6m24s" body="2 open docs changed during the run" keys={["⌘P peek", "esc"]} />
    </div>
    <StatusBar right={<span style={{ color: "var(--tm-agent)" }}>2 docs changed · ⌘P peek</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* H6 · Free tiles — pinned docs and terminals are movable peers (v1-C style) */
const H6Tiles = () => (
  <TmWin label="v3 · Free tiles (drag)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div className="tm-deskbg" style={{ gridTemplateColumns: "1.35fr 1fr", gridTemplateRows: "1.3fr 1fr" }}>
        <div className="tm-tile" style={{ gridRow: "1 / 3" }}>
          <div className="thd"><span className="kind">›_</span> claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span><span style={{ marginLeft: "auto", color: "var(--tm-faint)", font: "400 9.5px var(--tm-mono)" }}>⋮ drag · ⌘⏎ unpin</span></div>
          <TermPane style={{ flex: 1 }}><TermBody><ClaudeRun /></TermBody></TermPane>
        </div>
        <div className="tm-tile">
          <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> payments-api/docs/handoff.md</div>
          <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
        </div>
        <div style={{ position: "relative", minHeight: 0 }}>
          <div className="tm-dropslot" style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", font: "400 10px var(--tm-mono)", color: "var(--tm-faint)" }}>drop → split row</div>
          <div className="tm-tile lift" style={{ position: "absolute", inset: "8px -12px -4px 12px" }}>
            <div className="thd"><span className="kind">¶</span><RepoDot c="c" /> infra/docs/runbook.md <AgentDot /></div>
            <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
          </div>
        </div>
      </div>
    </div>
    <StatusBar right={<span>1 term · 2 docs pinned · 4 in dock</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { ClaudeRun, DevServer, ProcChip, H1Runway, H2Rail, H3Peek, H4Signals, H5Exit, H6Tiles });
