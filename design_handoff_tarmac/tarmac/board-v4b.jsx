/* Tarmac v4b — keeping the terminal primary on an infinite board.
   Three stackable mechanisms: focus model · gravity · cockpit dock. */

const V4bIntro = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "26px 36px", display: "flex", flexDirection: "column", fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 16 }}>白板上,terminal 的主體性靠什麼?— 不靠版面,靠三個機制(可疊加)</div>
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 30, flex: 1 }}>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        <b>1 · Focus 模型 — 打字去哪</b><br /><br />
        focus 永遠停在某個 terminal 上;<br />
        鏡頭飛到哪、點到哪張文件都一樣,<br />
        打字就是進 focused terminal。<br />
        ⌥tab 只在 terminal 間循環 —<br />
        文件不收 focus,只能 peek / 捲動。
      </Annot>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        <b>2 · 重力 — 東西落在哪</b><br /><br />
        文件卡是衛星:tarmac open 在哪個<br />
        shell 跑,就落在那張 terminal 卡旁,<br />
        拖 terminal 整個星座一起走。<br />
        白板的空間結構由 terminal 決定 —<br />
        「誰的文件」來自呼叫紀錄,不是猜的。
      </Annot>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        <b>3 · 駕駛艙 — 視窗 vs 畫布</b><br /><br />
        ⏎ 把 terminal 從畫布接進視窗底部,<br />
        固定不動;白板在它後面流動。<br />
        文件屬於空間,terminal 屬於你。<br />
        原位留一個虛線殘影,esc 放回去。
      </Annot>
    </div>
  </div>
);

/* F1 · focus model — typing always goes to a terminal */
const F1Focus = () => (
  <TmWin label="v4 · Focus model">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <div className="tm-cyclehud">
        <span className="c on"><span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> claude · payments-api</span>
        <span className="c"><span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)", display: "inline-block" }}></span> zsh · infra</span>
        <span className="c">npm run dev · search-svc</span>
      </div>
      <BCard x={84} y={96} w={440} h={290} kind="›_" prime sel
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<Kbd k="focus" />}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={130} y={440} w={350} h={190} kind="›_"
        title={<span>zsh · infra</span>}
        right={<span style={{ color: "var(--tm-amber)", font: "400 9.5px var(--tm-mono)" }}>bell 3m</span>}>
        <TermCardBody><TermWaiting /></TermCardBody>
      </BCard>
      <BCard x={590} y={120} w={370} h={300} kind="¶" quiet
        title={<span><RepoDot c="a" /> payments-api/docs/handoff.md</span>}
        right={<span style={{ color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ 5s</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
      </BCard>
      <BCard x={560} y={470} w={330} h={160} kind="¶" quiet
        title={<span><RepoDot c="c" /> infra/docs/runbook.md</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
      </BCard>
      <div className="tm-pill">打字永遠進 focused terminal — 不必先點卡片 · <span className="cy">⌥tab</span> 只巡 terminal;文件不收 focus,只能 peek</div>
    </div>
    <StatusBar right={<span>focus: claude · 3 terms in cycle</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* F2 · gravity — docs are satellites of the terminal that opened them */
const F2Gravity = () => (
  <TmWin label="v4 · Gravity (constellation)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <Edge d="M 560 250 C 600 240, 606 218, 640 206" />
      <Edge d="M 560 320 C 612 350, 620 420, 668 458" label="tarmac open" lx={588} ly={368} />
      <BCard x={100} y={110} w={460} h={330} kind="›_" prime
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span style={{ color: "var(--tm-faint)" }}>4m12s · ⋮ drag</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={640} y={80} w={340} h={260} kind="¶"
        title={<span><RepoDot c="a" /> handoff.md</span>}
        right={<span className="owner">← claude</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact ago="5s" /></div>
      </BCard>
      <BCard x={668} y={392} w={312} h={180} kind="¶"
        title={<span><RepoDot c="a" /> plan.md</span>}
        right={<span className="owner">← claude</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}>
          <div className="tm-doc">
            <div className="meta"><RepoDot c="a" /> payments-api/docs/plan.md</div>
            <h1 style={{ fontSize: 16 }}>Plan — billing retries</h1>
            <p>Queue-based retries with per-provider backoff; cron path removed.</p>
          </div>
        </div>
      </BCard>
      <BCard x={120} y={500} w={330} h={150} kind="¶" quiet
        title={<span><RepoDot c="c" /> infra/docs/runbook.md</span>}
        right={<span className="owner">無主卡</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
      </BCard>
      <div className="tm-pill">拖 claude,衛星跟著走 — 「誰的文件」來自 tarmac open 的呼叫紀錄,不是猜的 · 手動上板的卡自己待著</div>
    </div>
    <StatusBar right={<span>1 constellation · 1 loose card</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* F3 · cockpit dock — ⏎ pins the terminal to the viewport; board pans behind */
const F3Dock = () => (
  <TmWin label="v4 · Cockpit dock">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <span className="tm-zonelab" style={{ left: 84, top: 36 }}>PAYMENTS</span>
      <BCard x={80} y={58} w={380} h={330} kind="¶"
        title={<span><RepoDot c="a" /> payments-api/docs/handoff.md</span>}
        right={<span style={{ color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ 5s</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact changed ago="5s" /></div>
      </BCard>
      <BCard x={500} y={84} w={340} h={220} kind="¶"
        title={<span><RepoDot c="c" /> infra/docs/runbook.md</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
      </BCard>
      <div className="tm-slotghost" style={{ left: 880, top: 100, width: 220, height: 150 }}>claude 卡的原位 · esc 放回</div>
      <div className="tm-offhint bell" style={{ right: 10, top: 196 }}>
        <span style={{ color: "var(--tm-amber)" }}>◉</span> zsh — infra · bell 3m <span className="arr">→</span>
      </div>
      <div className="tm-dockpane" style={{ height: 330 }}>
        <div className="dhd">
          <span className="kind">›_</span> claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span>
          <span className="mr">docked — 白板在後面流動 <Kbd k="esc 放回白板" /><Kbd k="⌘⏎" /></span>
        </div>
        <TermBody style={{ padding: "12px 16px" }}><ClaudeRun /></TermBody>
      </div>
    </div>
    <StatusBar right={<span>docked: claude · 1 bell offscreen</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { V4bIntro, F1Focus, F2Gravity, F3Dock });
