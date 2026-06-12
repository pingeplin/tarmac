/* Tarmac — Section 02: key moments */

/* M1 · First run / empty (880×560) */
const M1Empty = () => (
  <TmWin label="Moment · First run">
    <TitleBar session={null} dim />
    <div style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 18 }}>
      <div style={{ font: "600 30px var(--tm-mono)", color: "var(--tm-agent)", letterSpacing: "0.06em" }}>▞▞</div>
      <div style={{ font: "500 15px var(--tm-mono)", color: "var(--tm-text)", letterSpacing: "0.18em" }}>TARMAC</div>
      <div style={{ font: "400 11.5px/2 var(--tm-mono)", color: "var(--tm-muted)", textAlign: "left", background: "var(--tm-term-bg)", border: "1px solid var(--tm-line-soft)", borderRadius: 9, padding: "14px 22px" }}>
        <div><span style={{ color: "var(--tm-faint)" }}>$</span> tarmac open <span style={{ color: "var(--tm-agent)" }}>&lt;path&gt;</span><span style={{ color: "var(--tm-faint)" }}>   # any file, any repo</span></div>
        <div><span style={{ color: "var(--tm-faint)" }}>$</span> tarmac term <span style={{ color: "var(--tm-faint)" }}>          # open a terminal here</span></div>
      </div>
      <div style={{ font: "400 10.5px var(--tm-mono)", color: "var(--tm-faint)" }}>your agent can call these too — that's the point</div>
      <div style={{ border: "1.5px dashed var(--tm-line)", borderRadius: 8, padding: "9px 22px", font: "400 10.5px var(--tm-mono)", color: "var(--tm-faint)" }}>or drop a .md file here</div>
    </div>
    <StatusBar><span>tmux <span style={{ color: "var(--tm-faint)" }}>not attached</span></span></StatusBar>
  </TmWin>
);

/* M2 · Agent opened a doc while you read — flag, don't steal (880×560) */
const M2Flag = () => (
  <TmWin label="Moment · Agent opened (flag)">
    <TitleBar session="infra-week">
      <DocTab repo="payments-api" c="a" name="handoff.md" active />
      <DocTab repo="infra" c="c" name="runbook.md" agent updated />
    </TitleBar>
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <div className="tm-docwrap" style={{ flex: "0 0 56%" }}><DocBody compact /></div>
      <div style={{ width: 1, background: "var(--tm-line)" }}></div>
      <TermPane style={{ flex: 1 }} tabs={<TermTab label="infra" active />}>
        <TermBody><TermWaiting /></TermBody>
      </TermPane>
      <Toast icon="✚" title="agent opened infra/runbook.md" body="“rollout steps are ready for review”" keys={["⏎ view", "esc"]} />
    </div>
    <StatusBar right={<AgentChip state="wait" />}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span>
    </StatusBar>
  </TmWin>
);

/* M3 · Live rewrite while reading (720×520) */
const M3Rewrite = () => (
  <TmWin label="Moment · Live rewrite">
    <TitleBar session={null}>
      <DocTab repo="payments-api" c="a" name="handoff.md" active updated />
      <DocTab repo="infra" c="c" name="runbook.md" />
    </TitleBar>
    <div className="tm-docwrap" style={{ flex: 1 }}>
      <DocBody changed compact ago="5s" />
      <div className="tm-pill"><span className="cy">✎</span> rewritten by agent · your place kept · changes above</div>
    </div>
  </TmWin>
);

/* M4 · Idle handover — agent switched the active tab (880×300) */
const M4Switch = () => (
  <TmWin label="Moment · Idle auto-switch">
    <TitleBar session="infra-week">
      <DocTab repo="payments-api" c="a" name="handoff.md" ghost />
      <DocTab repo="infra" c="c" name="runbook.md" active agent />
    </TitleBar>
    <div className="tm-banner">
      <span className="ic">▞</span>
      agent switched to <b style={{ fontWeight: 500 }}>infra/runbook.md</b>
      <span className="dim">— you were idle 4 min</span>
      <span className="keys"><Kbd k="⌫ go back" /><Kbd k="esc" /></span>
    </div>
    <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
  </TmWin>
);

/* M5 · Session restore (880×560) */
const M5Restore = () => (
  <TmWin label="Moment · Session restore">
    <TitleBar session="infra-week" dim>
      <DocTab repo="payments-api" c="a" name="handoff.md" active />
      <DocTab repo="infra" c="c" name="runbook.md" />
      <DocTab repo="search-svc" c="b" name="plan.md" />
    </TitleBar>
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <div className="tm-docwrap" style={{ flex: "0 0 56%", opacity: 0.35 }}><DocBody compact /></div>
      <div style={{ width: 1, background: "var(--tm-line)" }}></div>
      <TermPane style={{ flex: 1, opacity: 0.35 }}><TermBody><TermShell /></TermBody></TermPane>
      <div className="tm-veil"></div>
      <div className="tm-card">
        <div className="hd"><span className="glyph">▞</span> restored “infra-week”</div>
        <div className="row"><span className="ok">✓</span> 6 docs <span className="dim">· 3 repos</span></div>
        <div className="row"><span className="ok">✓</span> tmux attached <span className="dim">· 2 windows, history intact</span></div>
        <div className="row"><span className="dim">→</span> agent was waiting on you <span className="dim">· since 13:47</span></div>
        <div className="foot">any key to continue · ⌘K switch strip</div>
      </div>
    </div>
    <StatusBar right={<AgentChip state="wait" />}><span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span></StatusBar>
  </TmWin>
);

/* M6 · Strip switcher — named contexts (880×560) */
const M6Strips = () => (
  <TmWin label="Moment · Strip switcher">
    <TitleBar session="infra-week" dim>
      <DocTab repo="payments-api" c="a" name="handoff.md" active />
      <DocTab repo="infra" c="c" name="runbook.md" />
    </TitleBar>
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <div className="tm-docwrap" style={{ flex: 1, opacity: 0.35 }}><DocBody compact /></div>
      <div className="tm-veil"></div>
      <div className="tm-palette">
        <div className="inp">⌘K <span className="q">switch strip…</span><span className="tm-cursor"></span></div>
        <div className="tm-prow on">
          <span className="glyph">▞</span> infra-week
          <span className="meta"><span className="dots"><RepoDot c="a" /><RepoDot c="b" /><RepoDot c="c" /></span> 6 docs · 2 terms · tmux ✓</span>
        </div>
        <div className="tm-prow">
          <span className="glyph">▞</span> exp-search
          <span className="meta"><span className="dots"><RepoDot c="b" /></span> 3 docs · 1 term · tmux ✓</span>
        </div>
        <div className="tm-prow">
          <span className="glyph" style={{ color: "var(--tm-faint)" }}>▞</span> billing-fire
          <span className="meta">2 docs · <span style={{ color: "var(--tm-amber)" }}>detached</span></span>
        </div>
        <div className="pfoot"><span>⏎ switch</span><span>⌘N new strip</span><span>⌘⌫ archive</span></div>
      </div>
    </div>
    <StatusBar><span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week</span></StatusBar>
  </TmWin>
);

/* M7 · Agent state language (760×300, open board) */
const M7States = () => (
  <div style={{ width: "100%", height: "100%", background: "var(--tm-bg0)", borderRadius: 10, border: "1px solid #2a3039", display: "flex", flexDirection: "column", justifyContent: "center", gap: 26, padding: "0 44px" }}>
    {[
      { chip: "work", note: "working — 青色 + 慢速呼吸的 braille。出現在狀態列與 terminal 分頁;絕不彈窗。" },
      { chip: "wait", note: "waiting on you — 琥珀。唯一允許「主動拉注意力」的狀態:dock badge + 分頁琥珀點。" },
      { chip: "idle", note: "idle — 灰。agent 沒事做;此時(且僅此時)允許 agent 自動切換分頁。" },
    ].map((s) => (
      <div key={s.chip} style={{ display: "flex", alignItems: "center", gap: 22 }}>
        <div style={{ flex: "none", width: 190, background: "var(--tm-bg1)", border: "1px solid var(--tm-line)", borderRadius: 7, padding: "9px 14px" }}>
          <AgentChip state={s.chip} />
        </div>
        <Annot style={{ color: "var(--tm-muted)" }}>{s.note}</Annot>
      </div>
    ))}
  </div>
);

/* M8 · Tab anatomy & provenance (920×380, open board) */
const M8Anatomy = () => (
  <div style={{ width: "100%", height: "100%", background: "var(--tm-bg0)", borderRadius: 10, border: "1px solid #2a3039", display: "flex", flexDirection: "column", justifyContent: "center", gap: 20, padding: "0 40px" }}>
    {[
      { tab: <DocTab repo="payments-api" c="a" name="handoff.md" active />, note: "你開的 — 乾淨無記號。repo 前綴恆顯,色點 = repo 身分。" },
      { tab: <DocTab repo="infra" c="c" name="runbook.md" agent />, note: "agent 開的、未讀 — 5px 青點。讀過後青點消失,只留 repo 色點。" },
      { tab: <DocTab repo="payments-api" c="a" name="handoff.md" updated />, note: "agent 剛改寫 — 青點 + 2.4s 光環脈衝,約 30s 後安靜下來。" },
      { tab: <DocTab repo="infra" c="c" name="runbook.md" waiting />, note: "agent 在這份文件上等你 — 琥珀點,直到你回應才消失。" },
      {
        tab: (
          <div style={{ display: "flex", gap: 4 }}>
            <DocTab repo="payments-api" c="a" name="handoff.md" active />
            <DocTab repo="search-svc" c="b" name="handoff.md" />
          </div>
        ),
        note: "撞名雙胞胎 — 前綴 + 色點雙重消歧;同名時前綴永不省略。",
      },
    ].map((s, i) => (
      <div key={i} style={{ display: "flex", alignItems: "center", gap: 26 }}>
        <div style={{ flex: "none", width: 480, display: "flex", transform: "scale(1.28)", transformOrigin: "left center" }}>{s.tab}</div>
        <Annot style={{ color: "var(--tm-muted)", flex: 1 }}>{s.note}</Annot>
      </div>
    ))}
  </div>
);

Object.assign(window, { M1Empty, M2Flag, M3Rewrite, M4Switch, M5Restore, M6Strips, M7States, M8Anatomy });
