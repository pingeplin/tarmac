/* Tarmac — cold start flow: empty shell → claude → first tarmac open → first peek */

const CSBar = ({ docs, name }) => (
  <StatusBar right={docs ? <span style={{ color: "var(--tm-agent)" }}>1 doc · ⌘P peek</span> : <span>0 docs</span>}>
    <span><span style={{ color: "var(--tm-agent)" }}>▞</span> {name}</span>
    <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
  </StatusBar>
);

/* F1 · Fresh launch — a shell, nothing else */
const CS1 = () => (
  <TmWin label="Cold start · 1 fresh shell">
    <TitleBar session="strip-1" right={<span className="tm-chip idle"><span className="idot"></span>zsh · at prompt</span>} />
    <TermPane style={{ flex: 1 }}>
      <TermBody>
        <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
      </TermBody>
    </TermPane>
    <div style={{ flex: "none", display: "flex", justifyContent: "center", padding: "0 0 18px", background: "var(--tm-term-bg)" }}>
      <div style={{ font: "400 10.5px var(--tm-mono)", color: "var(--tm-faint)" }}>
        docs appear when anything runs&nbsp;<span style={{ color: "var(--tm-muted)" }}>tarmac open &lt;path&gt;</span>&nbsp;— you or your tools
      </div>
    </div>
    <CSBar name="strip-1" />
  </TmWin>
);

/* F2 · You cd in and start claude — strip renames to the repo */
const CS2 = () => (
  <TmWin label="Cold start · 2 run claude">
    <TitleBar session="payments-api" right={<span className="tm-chip work"><span className="tm-blink">⠧</span>claude · 0m08s</span>} />
    <TermPane style={{ flex: 1 }}>
      <TermBody>
        <div className="tl"><span className="dim">❯</span> <span className="wh">cd dev/payments-api</span></div>
        <div className="tl"><span className="dim">❯</span> <span className="wh">claude "wire up billing retries per plan.md"</span></div>
        <div className="tl dim">  · read docs/plan.md</div>
        <div className="tl dim">  · read src/billing/retry.ts</div>
        <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>
      </TermBody>
    </TermPane>
    <CSBar name="payments-api" />
  </TmWin>
);

/* F3 · First tarmac open — the dock is born */
const CS3 = () => (
  <TmWin label="Cold start · 3 dock is born">
    <TitleBar session="payments-api" right={<span className="tm-chip work"><span className="tm-blink">⠧</span>claude · 4m12s</span>} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <div className="tm-dock">
        <div className="doc on pulse">¶<span className="rd" style={{ background: "var(--tm-repo-a)" }}></span><span className="ad"></span></div>
        <div className="sep"></div>
        <div className="hint">⌘E index</div>
        <div className="foot"><span className="glyphbtn">▞</span></div>
      </div>
      <TermPane style={{ flex: 1 }}>
        <TermBody>
          <div className="tl dim">  · edit src/billing/retry.ts  +38 −12</div>
          <div className="tl dim">  · ran npm test → <span className="gr">41 passed</span></div>
          <div className="tl dim">  · wrote <span className="tm-doclink">docs/handoff.md</span></div>
          <div className="tl dim">  · ran tarmac open <span className="tm-doclink">docs/handoff.md</span></div>
          <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>
        </TermBody>
      </TermPane>
      <Toast icon="✚" title="first doc · payments-api/docs/handoff.md" body="opened via tarmac open, called from claude" keys={["⌘P peek", "esc"]} />
    </div>
    <CSBar name="payments-api" docs />
  </TmWin>
);

/* F4 · First peek — focus never left the prompt */
const CS4 = () => (
  <TmWin label="Cold start · 4 first peek">
    <TitleBar session="payments-api" right={<span className="tm-chip work"><span className="tm-blink">⠧</span>claude · 4m31s</span>} />
    <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
      <div className="tm-dock">
        <div className="doc on">¶<span className="rd" style={{ background: "var(--tm-repo-a)" }}></span></div>
        <div className="sep"></div>
        <div className="hint">⌘E index</div>
        <div className="foot"><span className="glyphbtn">▞</span></div>
      </div>
      <TermPane style={{ flex: 1 }}>
        <TermBody>
          <div className="tl dim">  · ran tarmac open <span className="tm-doclink">docs/handoff.md</span></div>
          <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>
        </TermBody>
      </TermPane>
      <div className="tm-peek open" style={{ width: "47%" }}>
        <div className="phd">
          <RepoDot c="a" /> payments-api/docs/handoff.md
          <span style={{ color: "var(--tm-agent)", opacity: 0.85 }}>✎ just now · during claude</span>
          <span className="pin"><Kbd k="⌘⏎ pin" /><Kbd k="esc" /></span>
        </div>
        <div className="pbody tm-docwrap"><DocBody changed compact ago="just now" /></div>
      </div>
    </div>
    <CSBar name="payments-api" docs />
  </TmWin>
);

/* Rules board */
const CSRules = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "26px 34px", fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>冷啟動規則</div>
    <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 2 }}>
      · <b>開機 = 一個 shell</b>。沒有歡迎頁、沒有設定精靈;唯一的教學是 prompt 下一行字,出現過一次就不再出現<br />
      · <b>dock 在第一份文件出現前不存在</b> — 不是空的 dock,是沒有 dock。介面跟著事實長出來<br />
      · <b>strip 自動以 cwd 的 repo 命名</b>(strip-1 → payments-api);可改名<br />
      · <b>另一條入口:</b>在任何既有 terminal 打 <b>tarmac .</b>,把當下 cwd 收進新 strip(同 code . 的習慣)<br />
      · 第一次 peek 之後,使用者已經見過全部三個概念:shell、dock、peek — pin/strips 等用到再說
    </Annot>
  </div>
);

Object.assign(window, { CS1, CS2, CS3, CS4, CSRules });
