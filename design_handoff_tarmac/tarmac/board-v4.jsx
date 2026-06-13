/* Tarmac v4 — strip = whiteboard, terminal / doc = cards on an infinite canvas.
   Signal model unchanged from v3: process table · fswatch · CLI · bell. */

/* ── shared bits ── */

const BCard = ({ x, y, w, h, kind, sel, fresh, dim, prime, quiet, edit, title, right, children }) => (
  <div className={"tm-bcard" + (sel ? " sel" : "") + (fresh ? " fresh" : "") + (dim ? " dim" : "") + (prime ? " prime" : "") + (quiet ? " quiet" : "") + (edit ? " edit" : "")} style={{ left: x, top: y, width: w, height: h }}>
    <div className="bhd">
      <span className="kind">{kind}</span>
      {title}
      <span className="mr">{right}</span>
    </div>
    {children}
    {sel && (
      <React.Fragment>
        <span className="hndl" style={{ left: -4, top: -4 }}></span>
        <span className="hndl" style={{ right: -4, top: -4 }}></span>
        <span className="hndl" style={{ left: -4, bottom: -4 }}></span>
        <span className="hndl" style={{ right: -4, bottom: -4 }}></span>
      </React.Fragment>
    )}
  </div>
);

const TermCardBody = ({ children }) => (
  <div style={{ flex: 1, minHeight: 0, background: "var(--tm-term-bg)", display: "flex", flexDirection: "column" }}>
    <TermBody style={{ padding: "10px 14px", fontSize: 11.5 }}>{children}</TermBody>
  </div>
);

/* provenance edge: only drawn because `tarmac open` ran in that terminal */
const Edge = ({ d, label, lx, ly }) => (
  <React.Fragment>
    <svg className="tm-edges">
      <path d={d} fill="none" stroke="oklch(0.78 0.11 200 / 0.45)" strokeWidth="1.2" strokeDasharray="3 5" />
    </svg>
    {label && <span className="tm-edgelab" style={{ left: lx, top: ly }}>{label}</span>}
  </React.Fragment>
);

const ZoomCtl = ({ z }) => (
  <div className="tm-zoomctl"><span>−</span><span className="pct">{z}</span><span>+</span><span style={{ borderLeft: "1px solid var(--tm-line-soft)" }}>⊡ fit</span></div>
);

const MiniMap = ({ vp, rects }) => (
  <div className="tm-minimap">
    {rects.map((r, i) => <span key={i} className={"mr" + (r.c ? " " + r.c : "")} style={{ left: r.x, top: r.y, width: r.w, height: r.h }}></span>)}
    <span className="vp" style={{ left: vp.x, top: vp.y, width: vp.w, height: vp.h }}></span>
  </div>
);

const Shelf = () => (
  <div className="tm-shelf">
    SHELF
    <span className="chip"><RepoDot c="a" />plan.md</span>
    <span className="chip"><RepoDot c="b" />notes.md <span className="tm-agentdot"></span></span>
    <span style={{ opacity: 0.7 }}>拖上板 = 落卡</span>
  </div>
);

/* ── B1 · the board — strip is a whiteboard, cards are terms & docs ── */
const B1Board = () => (
  <TmWin label="v4 · Board">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <span className="tm-zonelab" style={{ left: 78, top: 50 }}>PAYMENTS</span>
      <span className="tm-zonelab" style={{ left: 120, top: 408 }}>INFRA</span>
      <Edge d="M 508 208 C 560 218, 562 230, 606 244" label="tarmac open · 14:02" lx={516} ly={214} />
      <Edge d="M 480 540 C 520 548, 524 552, 558 556" />
      <BCard x={72} y={74} w={436} h={290} kind="›_" sel
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span style={{ color: "var(--tm-faint)" }}>4m12s</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={606} y={96} w={392} h={324} kind="¶"
        title={<span><RepoDot c="a" /> payments-api/docs/handoff.md</span>}
        right={<span style={{ color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ 5s</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact changed ago="5s" /></div>
      </BCard>
      <BCard x={118} y={430} w={362} h={196} kind="›_"
        title={<span>zsh · infra <span className="wdot" style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)", display: "inline-block" }}></span></span>}
        right={<span style={{ color: "var(--tm-amber)", font: "400 9.5px var(--tm-mono)" }}>bell 3m</span>}>
        <TermCardBody><TermWaiting /></TermCardBody>
      </BCard>
      <BCard x={558} y={474} w={350} h={170} kind="¶"
        title={<span><RepoDot c="c" /> infra/docs/runbook.md</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBodyAlt compact /></div>
      </BCard>
      <Shelf />
      <ZoomCtl z="82%" />
      <MiniMap vp={{ x: 36, y: 22, w: 62, h: 40 }} rects={[
        { x: 42, y: 28, w: 14, h: 9, c: "cy" }, { x: 60, y: 29, w: 12, h: 10 },
        { x: 44, y: 44, w: 11, h: 6, c: "am" }, { x: 58, y: 46, w: 11, h: 5 },
        { x: 96, y: 60, w: 10, h: 6 }, { x: 14, y: 14, w: 8, h: 5 },
      ]} />
    </div>
    <StatusBar right={<span>4 cards on board · 2 in shelf</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* ── B2 · tarmac open lands a card next to the calling terminal ── */
const B2Spawn = () => (
  <TmWin label="v4 · Card lands by its caller">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board">
      <Edge d="M 562 268 C 608 276, 612 282, 648 290" label="tarmac open · now" lx={566} ly={272} />
      <BCard x={92} y={108} w={470} h={330} kind="›_"
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span style={{ color: "var(--tm-faint)" }}>4m12s</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={648} y={140} w={392} h={310} kind="¶" fresh
        title={<span><RepoDot c="a" /> payments-api/docs/handoff.md</span>}
        right={<span style={{ color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✚ now</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact ago="5s" /></div>
      </BCard>
      <ZoomCtl z="100%" />
      <div className="tm-pill"><span className="cy">✚</span> 卡片落在呼叫 tarmac open 的 terminal 旁 · 拖去別處 or <span className="cy">esc</span> 收進 shelf</div>
    </div>
    <StatusBar right={<span>card placed · layout saved to strip</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* ── B3 · semantic zoom — content fades, signals stay legible ── */
const LoCard = ({ x, y, w, h, bell, live, nm, kind, st, dot }) => (
  <div className={"tm-locard" + (bell ? " bell" : "") + (live ? " live" : "")} style={{ left: x, top: y, width: w, height: h }}>
    <span className="nm"><span className="kind">{kind}</span>{dot && <RepoDot c={dot} />}{nm}</span>
    <span className="st">{st}</span>
  </div>
);

const B3ZoomOut = () => (
  <TmWin label="v4 · Zoomed out (semantic)">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} />
    <div className="tm-board lo">
      <span className="tm-zonelab" style={{ left: 96, top: 56 }}>PAYMENTS</span>
      <span className="tm-zonelab" style={{ left: 660, top: 96 }}>INFRA</span>
      <span className="tm-zonelab" style={{ left: 250, top: 430 }}>SEARCH-SVC</span>
      <LoCard x={96} y={86} w={218} h={64} live kind="›_" nm={<span>claude <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>} st="payments-api · 4m12s" />
      <LoCard x={344} y={108} w={196} h={60} kind="¶" dot="a" nm="handoff.md" st={<span style={{ color: "var(--tm-agent)" }}>✎ 5s · during claude</span>} />
      <LoCard x={150} y={188} w={172} h={56} kind="¶" dot="a" nm="plan.md" st="quiet · 2h" />
      <LoCard x={356} y={206} w={170} h={56} kind="✓" nm="pytest" st="exit 0 · 13:55" />
      <LoCard x={660} y={128} w={196} h={64} bell kind="›_" nm={<span>zsh <span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)", display: "inline-block" }}></span></span>} st="infra · bell 3m — at prompt" />
      <LoCard x={892} y={162} w={184} h={58} kind="¶" dot="c" nm="runbook.md" st="✎ 13:58" />
      <LoCard x={252} y={462} w={222} h={62} live kind="›_" nm="npm run dev" st="search-svc · :3000 · up 2h" />
      <LoCard x={508} y={494} w={176} h={56} kind="¶" dot="b" nm="notes.md" st="quiet · 1d" />
      <ZoomCtl z="36%" />
      <MiniMap vp={{ x: 14, y: 10, w: 104, h: 66 }} rects={[
        { x: 22, y: 18, w: 16, h: 7, c: "cy" }, { x: 44, y: 20, w: 13, h: 6 },
        { x: 26, y: 30, w: 12, h: 5 }, { x: 70, y: 22, w: 13, h: 7, c: "am" },
        { x: 88, y: 26, w: 12, h: 5 }, { x: 36, y: 54, w: 15, h: 6, c: "cy" }, { x: 56, y: 58, w: 12, h: 5 },
      ]} />
      <div className="tm-pill">縮小 = 語意縮放 — 內容淡出,只剩程序名 / 檔名與訊號 · 琥珀隔著高度也看得到</div>
    </div>
    <StatusBar right={<span>8 cards · 2 running · 1 bell</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* ── B4 · signals never leave the viewport — edge hints ── */
const B4Offscreen = () => (
  <TmWin label="v4 · Offscreen signals">
    <TitleBar session="infra-week" right={<ProcChip kind="bell" />} />
    <div className="tm-board">
      <BCard x={300} y={104} w={560} h={400} kind="›_" sel
        title={<span>claude · payments-api <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span></span>}
        right={<span style={{ color: "var(--tm-faint)" }}>4m12s</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <div className="tm-offhint bell" style={{ right: 10, top: 230 }}>
        <span style={{ color: "var(--tm-amber)" }}>◉</span> zsh — infra · bell 3m <span className="arr">→</span>
      </div>
      <div className="tm-offhint" style={{ left: 10, top: 310 }}>
        <span className="arr">←</span> <span style={{ color: "var(--tm-agent)" }}>✎</span> runbook.md · 13:58
      </div>
      <div className="tm-offhint live" style={{ left: 470, top: 48 }}>
        <span className="arr">↑</span> <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> npm run dev · :3000
      </div>
      <ZoomCtl z="100%" />
      <div className="tm-pill">視野外的訊號貼在邊緣 — <span className="cy">⏎</span> 飛過去 · <span className="cy">esc</span> 飛回來</div>
    </div>
    <StatusBar right={<span>1 bell offscreen</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
      <span>tmux <span style={{ color: "var(--tm-ok)" }}>attached</span></span>
    </StatusBar>
  </TmWin>
);

/* ── B5 · ⌘K — strips are boards; thumbnails are the saved layouts ── */
const B5Boards = () => (
  <TmWin label="v4 · Boards switcher">
    <TitleBar session="infra-week" right={<ProcChip kind="run" />} dim />
    <div className="tm-board">
      <BCard x={72} y={74} w={436} h={290} dim kind="›_" title={<span>claude · payments-api</span>}>
        <TermCardBody><ClaudeRun /></TermCardBody>
      </BCard>
      <BCard x={606} y={96} w={392} h={324} dim kind="¶" title={<span><RepoDot c="a" /> handoff.md</span>}>
        <div className="tm-docwrap" style={{ flex: 1 }}><DocBody compact /></div>
      </BCard>
      <div className="tm-veil"></div>
      <div className="tm-boards">
        <div className="bhead">▞ <span className="q">boards</span><span style={{ opacity: 0.6 }}>— type to filter</span></div>
        <div className="tm-brow on">
          <div className="tm-bthumb">
            <i className="cy" style={{ left: 8, top: 10, width: 22, height: 14 }}></i>
            <i style={{ left: 36, top: 12, width: 18, height: 16 }}></i>
            <i className="am" style={{ left: 12, top: 32, width: 16, height: 10 }}></i>
            <i style={{ left: 34, top: 34, width: 15, height: 9 }}></i>
          </div>
          <span className="nm"><span className="glyph">▞</span> infra-week</span>
          <span className="meta"><span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> 2 running · 1 bell · 8 cards</span>
        </div>
        <div className="tm-brow">
          <div className="tm-bthumb">
            <i className="cy" style={{ left: 10, top: 14, width: 24, height: 16 }}></i>
            <i style={{ left: 42, top: 18, width: 16, height: 12 }}></i>
          </div>
          <span className="nm"><span className="glyph">▞</span> exp-search</span>
          <span className="meta">1 running · 3 cards</span>
        </div>
        <div className="tm-brow">
          <div className="tm-bthumb">
            <i className="am" style={{ left: 14, top: 12, width: 20, height: 13 }}></i>
            <i style={{ left: 40, top: 28, width: 17, height: 11 }}></i>
          </div>
          <span className="nm"><span className="glyph" style={{ color: "var(--tm-faint)" }}>▞</span> billing-fire</span>
          <span className="meta"><span style={{ color: "var(--tm-amber)" }}>● bell 12m</span> · 4 cards</span>
        </div>
        <div className="bfoot"><span>⏎ open board</span><span>⌘1-9 jump</span><span>n new board</span></div>
      </div>
    </div>
    <StatusBar right={<span>3 boards</span>}>
      <span><span style={{ color: "var(--tm-agent)" }}>▞</span> infra-week · board</span>
    </StatusBar>
  </TmWin>
);

Object.assign(window, { BCard, TermCardBody, Edge, ZoomCtl, MiniMap, Shelf, B1Board, B2Spawn, B3ZoomOut, B4Offscreen, B5Boards });
