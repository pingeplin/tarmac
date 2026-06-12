/* Tarmac prototype — desk: terminal + pinned doc tiles, free drag-swap */

const deskGridStyle = (n) => {
  if (n <= 1) return { gridTemplateColumns: "1fr", gridTemplateRows: "1fr" };
  if (n === 2) return { gridTemplateColumns: "1.35fr 1fr", gridTemplateRows: "1fr" };
  if (n === 3) return { gridTemplateColumns: "1.35fr 1fr", gridTemplateRows: "1fr 1fr" };
  return { gridTemplateColumns: "1.25fr 1fr", gridTemplateRows: "1.3fr 1fr" };
};
const slotStyle = (n, i) => (n === 3 && i === 0 ? { gridRow: "1 / 3" } : null);

const TermTile = ({ strip, sim, activeTerm, onTermTab, onPeek, dragProps }) => {
  const term = strip.terms.find((t) => t.id === activeTerm) || strip.terms[0];
  return (
    <React.Fragment>
      <div className="thd" {...dragProps}>
        <span className="kind">›_</span>
        {term.kind === "claude" ? (sim.exited ? "zsh · payments-api" : "claude · payments-api") : term.label}
        {term.kind === "claude" && !sim.exited && <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span>}
        {term.id === "t-infra" && sim.bell && <span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--tm-amber)" }}></span>}
        <span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>{term.kind === "claude" && !sim.exited ? sim.runSecs : ""}</span>
      </div>
      <div className="tm-term" style={{ flex: 1, minHeight: 0 }}>
        <div className="tm-ttabs">
          {strip.terms.map((t) => (
            <div key={t.id} className={"tm-ttab" + (t.id === activeTerm ? " on" : "")} onClick={() => onTermTab(t.id)}>
              {t.kind === "claude" && !sim.exited && <span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span>}
              {t.id === "t-infra" && sim.bell && <span className="wdot"></span>}
              {t.kind === "claude" ? (sim.exited ? "zsh · payments-api" : "claude · payments-api") : t.label}
            </div>
          ))}
          <span className="plus">+</span>
        </div>
        <div className="tm-tbody" style={{ flex: 1, minHeight: 0 }}>
          <TermView term={term} sim={sim} onPeek={onPeek} />
        </div>
      </div>
    </React.Fragment>
  );
};

const DocTile = ({ docId, docState, onUnpin, onPeek, dragProps }) => {
  const d = PDOCS[docId];
  const st = docState[docId] || {};
  const recent = st.changedAt && Date.now() - st.changedAt < 30000;
  return (
    <React.Fragment>
      <div className="thd" {...dragProps}>
        <span className="kind">¶</span><RepoDot c={d.c} /> {d.repo}/{d.name}
        {recent && <span style={{ color: "var(--tm-agent)", font: "400 9.5px var(--tm-mono)" }}>✎ {Math.max(1, Math.round((Date.now() - st.changedAt) / 1000))}s</span>}
        <span className="x" onClick={(e) => { e.stopPropagation(); onUnpin(docId); }} title="unpin (back to dock)">⌘⏎ ✕</span>
      </div>
      <div className="tm-docwrap" style={{ flex: 1, overflow: "hidden" }}>{renderDocBody(docId, recent)}</div>
    </React.Fragment>
  );
};

/* Desk: order = ["term", ...docIds]; drag a tile header to swap slots */
const Desk = ({ order, strip, sim, docState, activeTerm, onTermTab, onPeek, onUnpin, onSwap }) => {
  const [drag, setDrag] = React.useState(null); // {key, dx, dy, over}
  const refs = React.useRef({});

  const startDrag = (key) => (e) => {
    if (e.target.closest(".x") || e.target.closest(".tm-ttab")) return;
    e.preventDefault();
    const startX = e.clientX, startY = e.clientY;
    setDrag({ key, dx: 0, dy: 0, over: null });
    const move = (ev) => {
      let over = null;
      Object.entries(refs.current).forEach(([k, el]) => {
        if (k === key || !el) return;
        const r = el.getBoundingClientRect();
        if (ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom) over = k;
      });
      setDrag({ key, dx: ev.clientX - startX, dy: ev.clientY - startY, over });
    };
    const up = (ev) => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      setDrag((d) => {
        if (d && d.over) onSwap(d.key, d.over);
        return null;
      });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  return (
    <div className="tm-desk" style={deskGridStyle(order.length)}>
      {order.map((key, i) => {
        const isDrag = drag && drag.key === key;
        const isOver = drag && drag.over === key;
        return (
          <div
            key={key}
            ref={(el) => { refs.current[key] = el; }}
            className={"tm-tile" + (isDrag ? " dragging" : "") + (isOver ? " droptarget" : "")}
            style={Object.assign({}, slotStyle(order.length, i), isDrag ? { transform: `translate(${drag.dx}px, ${drag.dy}px) rotate(-0.5deg)` } : null)}
          >
            {key === "term"
              ? <TermTile strip={strip} sim={sim} activeTerm={activeTerm} onTermTab={onTermTab} onPeek={onPeek} dragProps={{ onPointerDown: startDrag(key) }} />
              : <DocTile docId={key} docState={docState} onUnpin={onUnpin} onPeek={onPeek} dragProps={{ onPointerDown: startDrag(key) }} />}
          </div>
        );
      })}
    </div>
  );
};

Object.assign(window, { Desk });
