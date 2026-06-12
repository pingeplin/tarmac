/* Tarmac prototype — dock, index, rail, peek, strip switcher */

const PDock = ({ dock, docState, activePeek, pinned, onPeek, onToggleIndex }) => (
  <div className="tm-dock">
    {dock.map((id) => {
      const d = PDOCS[id]; const st = docState[id] || {};
      const recent = st.changedAt && Date.now() - st.changedAt < 30000;
      return (
        <div
          key={id}
          className={"doc" + (activePeek === id || pinned.includes(id) ? " on" : "") + (recent ? " pulse" : "")}
          title={d.repo + "/" + d.name}
          onClick={() => onPeek(id)}
        >
          ¶
          <span className="rd" style={{ background: `var(--tm-repo-${d.c})` }}></span>
          {st.openedByCli && !st.read && <span className="ad"></span>}
        </div>
      );
    })}
    <div className="sep"></div>
    <div className="hint" onClick={onToggleIndex} style={{ cursor: "pointer" }}>⌘E index</div>
    <div className="foot"><span className="glyphbtn">▞</span></div>
  </div>
);

const PIndex = ({ dock, docState, activePeek, stripLabel, onPeek, onToggleIndex }) => {
  const groups = {};
  dock.forEach((id) => { const d = PDOCS[id]; (groups[d.repo] = groups[d.repo] || { c: d.c, items: [] }).items.push(id); });
  return (
    <div className="tm-side" style={{ width: 224 }}>
      <div className="cap" onClick={onToggleIndex} style={{ cursor: "pointer" }}>OPEN DOCS · ⌘E</div>
      {Object.entries(groups).map(([repo, g]) => (
        <div className="tm-sgroup" key={repo}>
          <div className="hd"><RepoDot c={g.c} />{repo}</div>
          {g.items.map((id) => {
            const st = docState[id] || {};
            const recent = st.changedAt && Date.now() - st.changedAt < 30000;
            return (
              <div className={"it" + (activePeek === id ? " on" : "")} key={id} onClick={() => onPeek(id)}>
                {PDOCS[id].name.replace("docs/", "")}
                {st.openedByCli && !st.read && <AgentDot />}
                {recent && <span style={{ width: 7, height: 7, borderRadius: "50%", background: "var(--tm-agent)", flex: "none" }}></span>}
              </div>
            );
          })}
        </div>
      ))}
      <div style={{ font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "6px 8px" }}>⏎ peek · ⌘⏎ pin</div>
      <div className="foot"><span className="glyph">▞</span>{stripLabel}<span style={{ marginLeft: "auto", color: "var(--tm-faint)" }}>▾</span></div>
    </div>
  );
};

const fmtClock = (ts) => {
  const d = new Date(ts);
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
};

const PRail = ({ stripId, sim, fileEvents, onPeek, onStripSwitch, onJumpTerm }) => (
  <div className="tm-rail2">
    <div className="cap">STRIPS · ⌘K</div>
    {Object.keys(STRIPS).map((id) => {
      const s = STRIPS[id];
      return (
        <div className={"tm-strip" + (id === stripId ? " on" : "") + (s.detached ? " off" : "")} key={id} onClick={() => onStripSwitch(id)}>
          <span className="glyph">▞</span> {s.label}
          <span className="meta">
            {s.detached
              ? <span style={{ color: "var(--tm-amber)" }}>● detached</span>
              : id === "infra-week"
                ? (sim.exited ? "idle" : <React.Fragment><span className="tm-blink" style={{ color: "var(--tm-agent)" }}>⠧</span> running</React.Fragment>)
                : "1 running"}
          </span>
        </div>
      );
    })}
    <div className="sep"></div>
    {stripId === "infra-week" && (
      <React.Fragment>
        <div className="cap">PROCESSES</div>
        {!sim.exited
          ? <div onClick={() => onJumpTerm("t-claude")}><RailItem t={"started " + fmtClock(sim.startTs) + " · " + sim.runSecs} ic="⠧" label="claude — payments-api" hi /></div>
          : <div onClick={() => onJumpTerm("t-claude")}><RailItem t={"exit 0 · ran " + sim.runSecs} ic="✓" cls="ok" label="claude — payments-api" /></div>}
        <div onClick={() => onJumpTerm("t-infra")}>
          {sim.bell
            ? <RailItem t="bell · confirm apply" ic="◉" cls="wait" label="zsh — infra · at prompt" />
            : <RailItem t="at prompt" ic="·" label="zsh — infra" />}
        </div>
        <div onClick={() => onJumpTerm("t-scratch")}><RailItem t="at prompt" ic="·" label="zsh — scratch" /></div>
        <div className="sep"></div>
        <div className="cap">FILE EVENTS · fswatch</div>
        {fileEvents.length === 0 && <div style={{ font: "400 10.5px var(--tm-mono)", color: "var(--tm-faint)", padding: "2px 8px" }}>no changes yet</div>}
        {fileEvents.map((fe, i) => (
          <div key={i} onClick={() => onPeek(fe.doc)}>
            <RailItem t={fmtClock(fe.ts) + (fe.during ? " · during claude" : "")} ic="✎" label={PDOCS[fe.doc].repo + "/" + PDOCS[fe.doc].name.replace("docs/", "")} hi={i === 0} />
          </div>
        ))}
      </React.Fragment>
    )}
    {stripId === "exp-search" && (
      <React.Fragment>
        <div className="cap">PROCESSES</div>
        <div onClick={() => onJumpTerm("t-dev")}><RailItem t="up 2h · :3000" ic="⠧" label="npm run dev — search-svc" hi /></div>
        <div onClick={() => onJumpTerm("t-sh")}><RailItem t="at prompt" ic="·" label="zsh — search-svc" /></div>
      </React.Fragment>
    )}
    <div style={{ marginTop: "auto", font: "400 10px var(--tm-mono)", color: "var(--tm-faint)", padding: "8px 6px", borderTop: "1px solid var(--tm-line-soft)" }}>
      click process → tab · click event → peek
    </div>
  </div>
);

const PPeek = ({ docId, docState, peekWidth, onPin, onClose }) => {
  const d = docId ? PDOCS[docId] : null;
  const st = (docId && docState[docId]) || {};
  const recent = st.changedAt && Date.now() - st.changedAt < 30000;
  return (
    <div className={"tm-peek" + (docId ? " open" : "")} style={{ width: peekWidth + "%" }}>
      {d && (
        <React.Fragment>
          <div className="phd">
            <RepoDot c={d.c} /> {d.repo}/{d.name}
            {recent && <span style={{ color: "var(--tm-agent)", opacity: 0.85 }}>✎ {Math.max(1, Math.round((Date.now() - st.changedAt) / 1000))}s{st.lastDuring ? " · during claude" : ""}</span>}
            <span className="pin">
              <kbd className="tm-kbd btn" onClick={onPin}>⌘⏎ pin</kbd>
              <kbd className="tm-kbd btn" onClick={onClose}>esc</kbd>
            </span>
          </div>
          <div className="pbody tm-docwrap" style={{ overflow: "hidden" }}>{renderDocBody(docId, recent)}</div>
        </React.Fragment>
      )}
    </div>
  );
};

const PSwitcher = ({ stripId, onPick, onClose }) => (
  <React.Fragment>
    <div className="tm-veil" onClick={onClose}></div>
    <div className="tm-palette">
      <div className="inp">⌘K <span className="q">switch strip…</span><span className="tm-cursor"></span></div>
      {Object.keys(STRIPS).map((id) => {
        const s = STRIPS[id];
        return (
          <div className={"tm-prow" + (id === stripId ? " on" : "")} key={id} onClick={() => onPick(id)}>
            <span className="glyph" style={s.detached ? { color: "var(--tm-faint)" } : null}>▞</span> {s.label}
            <span className="meta">
              {s.detached ? <span style={{ color: "var(--tm-amber)" }}>detached</span> : `${s.dock.length}+ docs · ${s.terms.length} terms · tmux ✓`}
            </span>
          </div>
        );
      })}
      <div className="pfoot"><span>click to switch</span><span>esc close</span></div>
    </div>
  </React.Fragment>
);

Object.assign(window, { PDock, PIndex, PRail, PPeek, PSwitcher, fmtClock });
