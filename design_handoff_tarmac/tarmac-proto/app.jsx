/* Tarmac prototype — main app: state, sim engine, keyboard, tweaks */

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "oklch(0.78 0.11 200)",
  "peekWidth": 47,
  "showRail": true,
  "motion": true
}/*EDITMODE-END*/;

const initialStripState = (id) => ({
  dock: STRIPS[id].dock.slice(),
  order: ["term"],
  activeTerm: STRIPS[id].terms.length ? STRIPS[id].terms[0].id : null,
  peek: null,
});

const fmtRun = (ms) => {
  const s = Math.floor(ms / 1000);
  return Math.floor(s / 60) + "m" + String(s % 60).padStart(2, "0") + "s";
};

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [stripId, setStripId] = React.useState("infra-week");
  const [stripStates, setStripStates] = React.useState({
    "infra-week": initialStripState("infra-week"),
    "exp-search": initialStripState("exp-search"),
  });
  const [docState, setDocState] = React.useState({});
  const [fileEvents, setFileEvents] = React.useState([]);
  const [indexOpen, setIndexOpen] = React.useState(false);
  const [switcher, setSwitcher] = React.useState(false);
  const [toasts, setToasts] = React.useState([]);
  const [simStart, setSimStart] = React.useState(() => Date.now());
  const [now, setNow] = React.useState(() => Date.now());
  const [bell, setBell] = React.useState(false);
  const processed = React.useRef(new Set());

  const ss = stripStates[stripId] || initialStripState("infra-week");
  const strip = STRIPS[stripId];
  const patchStrip = (patch) =>
    setStripStates((prev) => ({ ...prev, [stripId]: { ...prev[stripId], ...patch } }));

  const elapsed = Math.min(now - simStart, CLAUDE_EXIT_T + 600);
  const exited = now - simStart >= CLAUDE_EXIT_T;
  const sim = {
    elapsed: now - simStart, exited, bell, startTs: simStart,
    runSecs: fmtRun(exited ? CLAUDE_EXIT_T : now - simStart),
  };

  const pushToast = (toast) => {
    const id = Math.random().toString(36).slice(2);
    setToasts((prev) => [...prev.slice(-2), { ...toast, id }]);
    setTimeout(() => setToasts((prev) => prev.filter((x) => x.id !== id)), 7000);
  };

  const openPeek = (docId) => {
    patchStrip({ peek: docId });
    setDocState((prev) => ({ ...prev, [docId]: { ...prev[docId], read: true } }));
  };
  const closePeek = () => patchStrip({ peek: null });
  const pinPeek = () => {
    if (!ss.peek || ss.order.includes(ss.peek)) { closePeek(); return; }
    patchStrip({ order: [...ss.order, ss.peek], peek: null });
  };
  const unpin = (docId) => patchStrip({ order: ss.order.filter((k) => k !== docId) });
  const swapTiles = (a, b) => {
    const order = ss.order.slice();
    const ia = order.indexOf(a), ib = order.indexOf(b);
    if (ia < 0 || ib < 0) return;
    order[ia] = b; order[ib] = a;
    patchStrip({ order });
  };

  const replay = () => {
    processed.current = new Set();
    setSimStart(Date.now());
    setBell(false);
    setFileEvents([]);
    setDocState({});
    setStripStates((prev) => ({ ...prev, "infra-week": initialStripState("infra-week") }));
    setToasts([]);
  };

  /* sim clock + events */
  React.useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 400);
    return () => clearInterval(iv);
  }, []);
  React.useEffect(() => {
    SIM_EVENTS.forEach((e, i) => {
      if (now - simStart < e.t || processed.current.has(i)) return;
      processed.current.add(i);
      if (e.ev === "fileChange") {
        setDocState((prev) => ({ ...prev, [e.doc]: { ...prev[e.doc], changedAt: Date.now(), lastDuring: true } }));
        setFileEvents((prev) => [{ doc: e.doc, ts: Date.now(), during: true }, ...prev]);
      }
      if (e.ev === "openDoc") {
        setStripStates((prev) => {
          const iw = prev["infra-week"];
          if (iw.dock.includes(e.doc)) return prev;
          return { ...prev, "infra-week": { ...iw, dock: [...iw.dock.slice(0, 2), e.doc, ...iw.dock.slice(2)] } };
        });
        setDocState((prev) => ({ ...prev, [e.doc]: { ...prev[e.doc], openedByCli: true } }));
        pushToast({ icon: "✚", title: "tarmac open infra/runbook.md", body: "called from claude · payments-api", doc: e.doc });
      }
      if (e.ev === "bell") setBell(true);
      if (e.ev === "exit") {
        pushToast({ icon: "✓", title: "claude exited 0 · " + fmtRun(CLAUDE_EXIT_T), body: "1 open doc changed during the run", doc: "pay-handoff" });
      }
    });
  }, [now, simStart]);

  /* keyboard */
  React.useEffect(() => {
    const onKey = (e) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key.toLowerCase() === "p") {
        e.preventDefault();
        const latest = fileEvents[0] ? fileEvents[0].doc : (stripStates[stripId] || {}).dock?.[0];
        if (latest) openPeek(latest);
      } else if (meta && e.key.toLowerCase() === "e") {
        e.preventDefault(); setIndexOpen((v) => !v);
      } else if (meta && e.key.toLowerCase() === "k") {
        e.preventDefault(); setSwitcher((v) => !v);
      } else if (meta && e.key === "Enter") {
        e.preventDefault(); pinPeek();
      } else if (e.key === "Escape") {
        if (switcher) setSwitcher(false);
        else if ((stripStates[stripId] || {}).peek) closePeek();
        else setToasts([]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const onTermTab = (id) => {
    patchStrip({ activeTerm: id });
    if (id === "t-infra") setBell(false);
  };
  const switchStrip = (id) => { setStripId(id); setSwitcher(false); setIndexOpen(false); };

  const changedCount = new Set(fileEvents.map((f) => f.doc)).size;
  const accentDim = t.accent.replace(")", " / 0.16)");
  const chip = !exited && stripId === "infra-week"
    ? <span className="tm-chip work"><span className="tm-blink">⠧</span>claude · {sim.runSecs}</span>
    : bell
      ? <span className="tm-chip wait"><span className="wdot"></span>bell · infra</span>
      : <span className="tm-chip idle"><span className="idot"></span>at prompt</span>;

  return (
    <div
      className={"tm-win tm-app" + (t.motion ? "" : " still")}
      data-screen-label="Tarmac prototype"
      style={{ "--tm-agent": t.accent, "--tm-agent-dim": accentDim }}
    >
      <TitleBar session={strip.label} right={chip} />
      <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
        {!strip.detached && (indexOpen
          ? <PIndex dock={ss.dock} docState={docState} activePeek={ss.peek} stripLabel={strip.label} onPeek={openPeek} onToggleIndex={() => setIndexOpen(false)} />
          : <PDock dock={ss.dock} docState={docState} activePeek={ss.peek} pinned={ss.order} onPeek={openPeek} onToggleIndex={() => setIndexOpen(true)} />)}

        {strip.detached ? (
          <div className="tm-detached">
            <div style={{ font: "600 22px var(--tm-mono)", color: "var(--tm-amber)" }}>▞</div>
            <div style={{ font: "500 13px var(--tm-mono)", color: "var(--tm-text)" }}>billing-fire is detached</div>
            <div style={{ font: "400 11px var(--tm-mono)", color: "var(--tm-faint)", background: "var(--tm-term-bg)", border: "1px solid var(--tm-line-soft)", borderRadius: 8, padding: "10px 18px" }}>
              $ tarmac attach billing-fire
            </div>
            <div style={{ font: "400 10.5px var(--tm-mono)", color: "var(--tm-faint)" }}>⌘K to switch back</div>
          </div>
        ) : (
          <Desk
            order={ss.order} strip={strip} sim={sim} docState={docState}
            activeTerm={ss.activeTerm} onTermTab={onTermTab}
            onPeek={openPeek} onUnpin={unpin} onSwap={swapTiles}
          />
        )}

        {t.showRail && !strip.detached && (
          <PRail stripId={stripId} sim={sim} fileEvents={fileEvents} onPeek={openPeek} onStripSwitch={switchStrip} onJumpTerm={onTermTab} />
        )}

        {!strip.detached && <PPeek docId={ss.peek} docState={docState} peekWidth={t.peekWidth} onPin={pinPeek} onClose={closePeek} />}
        {switcher && <PSwitcher stripId={stripId} onPick={switchStrip} onClose={() => setSwitcher(false)} />}

        <div className="tm-toasts">
          {toasts.map((toast) => (
            <div className="tm-toast" key={toast.id}>
              <span className="ic">{toast.icon}</span>
              <div className="bd">
                <div className="t">{toast.title}</div>
                {toast.body && <div className="b">{toast.body}</div>}
              </div>
              <div className="keys">
                {toast.doc && <kbd className="tm-kbd btn" onClick={() => { openPeek(toast.doc); setToasts((prev) => prev.filter((x) => x.id !== toast.id)); }}>⏎ peek</kbd>}
                <kbd className="tm-kbd btn" onClick={() => setToasts((prev) => prev.filter((x) => x.id !== toast.id))}>esc</kbd>
              </div>
            </div>
          ))}
        </div>
      </div>
      <StatusBar
        right={
          <React.Fragment>
            {changedCount > 0 && <span style={{ color: "var(--tm-agent)", cursor: "pointer" }} onClick={() => fileEvents[0] && openPeek(fileEvents[0].doc)}>{changedCount} doc{changedCount > 1 ? "s" : ""} changed · ⌘P peek</span>}
            <span>{ss.dock.length} docs · {ss.order.length - 1} pinned</span>
            {chip}
          </React.Fragment>
        }
      >
        <span><span style={{ color: "var(--tm-agent)" }}>▞</span> {strip.label}</span>
        <span>tmux {strip.detached ? <span style={{ color: "var(--tm-amber)" }}>detached</span> : <span style={{ color: "var(--tm-ok)" }}>attached</span>}</span>
        <span style={{ color: "var(--tm-faint)" }}>⌘P peek · ⌘E index · ⌘K strips · ⌘⏎ pin</span>
      </StatusBar>

      <TweaksPanel>
        <TweakSection label="Theme" />
        <TweakColor label="Accent" value={t.accent}
          options={["oklch(0.78 0.11 200)", "oklch(0.75 0.12 255)", "oklch(0.78 0.1 160)", "oklch(0.78 0.1 80)"]}
          onChange={(v) => setTweak("accent", v)} />
        <TweakToggle label="Motion" value={t.motion} onChange={(v) => setTweak("motion", v)} />
        <TweakSection label="Layout" />
        <TweakSlider label="Peek width" value={t.peekWidth} min={36} max={62} unit="%" onChange={(v) => setTweak("peekWidth", v)} />
        <TweakToggle label="Right rail" value={t.showRail} onChange={(v) => setTweak("showRail", v)} />
        <TweakSection label="Simulation" />
        <TweakButton label="Replay claude run" onClick={replay} />
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
