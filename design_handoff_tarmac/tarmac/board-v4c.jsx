/* Tarmac v4c — docs become editors. Rule upgrade:
   「文件不收 focus」→「focus 的家在 terminal」(borrowed focus, esc goes home) */

const V4cIntro = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "26px 36px", display: "grid", gridTemplateColumns: "1.05fr 1fr", gap: 36, fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>文件可編輯之後 — 規則升級,不是推翻</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        「文件不收 focus」擋住了編輯。換成更強的不變式:<br />
        <b>focus 的家在 terminal</b> — 編輯是顯式「借用」。<br /><br />
        · 進入編輯是大動作:⏎ 或點進文字,卡片亮起 + 出現游標<br />
        · <b>esc 永遠回家</b> — 一鍵回到 focused terminal(像 vim 的<br />
        　normal mode;不用想「我現在 focus 在哪」)<br />
        · ⌥tab 不變,只巡 terminal;編輯中的文件不進循環<br />
        · 重力不變:編輯不改變歸屬,衛星還是衛星
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>誠實模型多了一條:寫入</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        以前 Tarmac 只「讀」磁碟;現在你的存檔也是 file event。<br /><br />
        · 訊號照樣不猜:meta 標 <b>✎ you · editing</b> vs<br />
        　<b>✎ 5s · during claude</b> — 來源都是事實<br />
        · 新衝突:你編輯到一半,claude 改寫了磁碟上的同一個檔<br />
        　→ Tarmac <b>不仲裁</b>:琥珀橫幅報告 mtime,給 diff /<br />
        　重載 / 照舊三個出口,自己決定<br />
        · agent 還在跑時進編輯,卡片頭保留 ⠧ — 你知道<br />
        　隨時可能再被改
      </Annot>
    </div>
  </div>
);

/* the doc as an editor — caret in text, honest meta */
const EditDocBody = ({ conflictless }) => (
  <div className="tm-doc">
    <div className="meta">
      <RepoDot c="a" /> payments-api/docs/handoff.md <span>·</span>
      <span className="ag">✎ you · editing</span>
      {conflictless && <span style={{ color: "var(--tm-faint)" }}>· saved 12s ago</span>}
    </div>
    <h1>Handoff — billing retries</h1>
    <p>Retry scheduling for failed charges now runs on a dedicated queue with exponential backoff. The cron path is removed.</p>
    <h2>What changed</h2>
    <ul>
      <li><code>retry.ts</code> — backoff curve is configurable per provider <b>(+38 −12)</b></li>
      <li>Dead-letter handling moved to <code>dlq.ts</code>; alerts fire after 3 failures — confirmed with infra<span className="tm-caret"></span></li>
    </ul>
  </div>
);

/* E1 · borrowed focus — editing a doc, esc goes home */
const E1Edit = () => (
  <TmWin label="v4 · Editing a doc card">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <Edge d="M 500 240 C 544 234, 548 224, 580 216" />
      <BCard x={80} y={110} w={420} h={300} kind="›_" prime
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span className="tm-homechip">⌂ esc 回這裡</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={580} y={90} w={400} h={350} kind="¶" edit
        title={<span><RepoDot c="a" /> handoff.md — editing</span>}
        right={<span className="owner">← claude</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><EditDocBody conflictless /></div>
      </BCard>
      <BCard x={120} y={480} w={330} h={150} kind="¶" quiet
        title={<span><RepoDot c="c" /> infra/docs/runbook.md</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
      </BCard>
      <div className="tm-pill"><span className="cy">⏎</span> / 點進文字 = 借走 focus · <span className="cy">esc</span> 永遠回 terminal · <span className="cy">⌥tab</span> 照樣只巡 terminal</div>
    </div>
    <StatusBar right={<span>editing: handoff.md · esc → claude</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* E2 · write conflict — claude rewrote the file on disk mid-edit */
const E2Conflict = () => (
  <TmWin label="v4 · Edit conflict (honest)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <Edge d="M 470 250 C 514 244, 518 234, 550 226" />
      <BCard x={70} y={120} w={400} h={290} kind="›_"
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span className="tm-homechip">⌂ esc</span>}>
        <TermCardBody>
          <div className="tl dim"># payments-api · feat/billing-retries</div>
          <div className="tl dim">  · edit src/billing/dlq.ts  +9 −2</div>
          <div className="tl dim">  · wrote <span className="tm-doclink">docs/handoff.md</span></div>
          <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>
        </TermCardBody>
      </BCard>
      <BCard x={550} y={88} w={430} h={380} kind="¶" edit
        title={<span><RepoDot c="a" /> handoff.md — editing</span>}
        right={<span className="owner">← claude</span>}>
        <div className="tm-conflict">
          <span className="ic">◉</span> 磁碟上的檔變了 · ✎ 14:06 · during claude — 你的編輯尚未存
          <span className="keys"><Kbd k="d diff" /><Kbd k="r 重載" /><Kbd k="照舊" /></span>
        </div>
        <div className="tm-docwrap" style={{ flex: 1 }}><EditDocBody /></div>
      </BCard>
      <div className="tm-pill">Tarmac 不仲裁 — 只報告 mtime(事實)+ 給 diff;要不要讓 claude 的版本進來,你決定</div>
    </div>
    <StatusBar right={<span style={{ color: "var(--tm-amber)" }}>conflict: handoff.md changed on disk</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { V4cIntro, EditDocBody, E1Edit, E2Conflict });
