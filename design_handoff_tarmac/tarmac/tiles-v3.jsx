/* Tarmac v3 — free-drag tiles (v1-C style) under the honest-signal model */

/* T1 · Tiles cockpit — docs & terminals as peer tiles, one mid-drag */
const T1Tiles = () => (
  <TmWin label="v3 · Tiles (mid-drag)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div className="tm-deskbg" style={{ gridTemplateColumns: "1.25fr 1fr", gridTemplateRows: "1.3fr 1fr" }}>
        <div className="tm-tile">
          <div className="thd"><span className="kind">›_</span> claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span><span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>4m12s</span></div>
          <TermPane style={{ flex: 1 }}><TermBody><ClaudeRun /></TermBody></TermPane>
        </div>
        <div className="tm-tile">
          <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> payments-api/docs/handoff.md <span style={{ marginLeft: "auto", color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ 5s</span></div>
          <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
        </div>
        <div style={{ position: "relative", minHeight: 0 }}>
          <div className="tm-dropslot" style={{ position: "absolute", inset: 0 }}></div>
          <div className="tm-tile lift" style={{ position: "absolute", inset: "8px -16px -4px 12px" }}>
            <div className="thd"><span className="kind">¶</span><RepoDot c="c" /> infra/docs/runbook.md</div>
            <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
          </div>
        </div>
        <div className="tm-tile">
          <div className="thd"><span className="kind">›_</span> zsh · infra <span className="wdot" style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)" }}></span><span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>bell 3m</span></div>
          <TermPane style={{ flex: 1 }}><TermBody><TermWaiting /></TermBody></TermPane>
        </div>
      </div>
    </div>
    <StatusBar right={<span>2 docs · 2 terms pinned</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* T2 · Pin lands on the desk — dragging peek header toward an edge shows split preview */
const T2PinDrop = () => (
  <TmWin label="v3 · Pin = drop onto desk">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <LeftDock />
      <div className="tm-deskbg" style={{ gridTemplateColumns: "1fr", gridTemplateRows: "1fr" }}>
        <div className="tm-tile">
          <div className="thd"><span className="kind">›_</span> claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></div>
          <TermPane style={{ flex: 1 }}><TermBody><ClaudeRun /></TermBody></TermPane>
        </div>
      </div>
      {/* right-edge split preview */}
      <div style={{ position: "absolute", top: 12, bottom: 12, right: 12, width: "34%", border: "1.5px dashed var(--tm-agent)", borderRadius: 9, background: "var(--tm-agent-dim)", zIndex: 3 }}></div>
      {/* dragged peek, shrunk to a ghost card */}
      <div className="tm-tile lift" style={{ position: "absolute", right: "16%", top: 90, width: 320, height: 210, zIndex: 4 }}>
        <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> handoff.md</div>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact ago="5s" /></div>
      </div>
      <div className="tm-pill" style={{ bottom: 14 }}><span className="cy">⌘⏎</span> pin here · 拖到邊緣 = 分割,拖到磚上 = 交換</div>
    </div>
    <StatusBar right={<span>dragging · esc to cancel</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
    </StatusBar>
  </TmWin>
);

/* T3 · Terminal splits live inside one tile too */
const T3TermSplit = () => (
  <TmWin label="v3 · Splits inside a tile">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
      <LeftDock />
      <div className="tm-deskbg" style={{ gridTemplateColumns: "1.35fr 1fr", gridTemplateRows: "1fr" }}>
        <div className="tm-tile">
          <div className="thd"><span className="kind">›_</span> payments-api <span style={{ color: "var(--tm-faint)" }}>· 2 panes</span></div>
          <div style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0 }}>
            <TermPane style={{ flex: "1 1 60%" }}><TermBody><ClaudeRun /></TermBody></TermPane>
            <div className="tm-split"></div>
            <TermPane style={{ flex: "1 1 40%" }}><TermBody><TermShell /></TermBody></TermPane>
          </div>
        </div>
        <div className="tm-tile">
          <div className="thd"><span className="kind">¶</span><RepoDot c="a" /> payments-api/docs/handoff.md <span style={{ marginLeft: "auto", color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ 5s</span></div>
          <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
        </div>
      </div>
    </div>
    <StatusBar right={<span>layout saved to strip</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { T1Tiles, T2PinDrop, T3TermSplit });
