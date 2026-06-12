/* Tarmac prototype — terminal views (streamed claude run, static shells) */

const SLine = ({ s, onPeek }) => {
  const d = s.doc ? PDOCS[s.doc] : null;
  const link = d && (
    <span className="tm-doclink" onClick={(e) => { e.stopPropagation(); onPeek(s.doc); }}>
      {d.repo === "payments-api" ? "" : d.repo + "/"}{d.name}
    </span>
  );
  switch (s.k) {
    case "hdr": return <div className="tl dim">{s.text}</div>;
    case "cmd": return <div className="tl"><span className="dim">❯</span> <span className="wh">{s.text}</span></div>;
    case "step": return <div className="tl dim">  {s.text}</div>;
    case "ok": return <div className="tl dim">  · ran npm test → <span className="gr">41 passed</span></div>;
    case "wrote": return <div className="tl dim">  {s.text}{link}</div>;
    case "open": return <div className="tl dim">  {s.text}{link}</div>;
    default: return null;
  }
};

const ClaudeStream = ({ elapsed, exited, runSecs, onPeek }) => {
  const visible = CLAUDE_SCRIPT.filter((s) => s.t <= elapsed);
  return (
    <div className="tm-stream">
      <div className="lines">
        {visible.map((s, i) => <SLine s={s} key={i} onPeek={onPeek} />)}
        {!exited && <div className="tl"><span className="cy tm-blink">⠧</span> <span className="dim">working …</span></div>}
        {exited && (
          <React.Fragment>
            <div className="tl"><span className="gr">✓</span> <span className="dim">claude exited 0 · ran {runSecs}</span></div>
            <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
          </React.Fragment>
        )}
      </div>
    </div>
  );
};

const StaticTerm = ({ kind, bell }) => (
  <div className="tm-stream"><div className="lines">
    {kind === "waiting" && (
      <React.Fragment>
        <div className="tl dim"># infra · main</div>
        <div className="tl"><span className="dim">❯</span> <span className="wh">terraform plan -out=tfplan</span></div>
        <div className="tl dim">  Plan: 4 to add, 1 to change, 0 to destroy.</div>
        {bell && <div className="tl"><span className="am">◉</span> <span className="dim">bell — confirm before apply</span></div>}
        <div className="tl"><span className="dim">❯</span><span className="tm-cursor"></span></div>
      </React.Fragment>
    )}
    {kind === "shell" && <TermShell />}
    {kind === "dev" && (
      <React.Fragment>
        <div className="tl dim"># search-svc</div>
        <div className="tl"><span className="dim">❯</span> <span className="wh">npm run dev</span></div>
        <div className="tl dim">  ready on :3000 · watching</div>
        <div className="tl dim">  GET /search?q=retry · 12ms</div>
      </React.Fragment>
    )}
  </div></div>
);

const TermView = ({ term, sim, onPeek }) => {
  if (term.kind === "claude") {
    return <ClaudeStream elapsed={sim.elapsed} exited={sim.exited} runSecs={sim.runSecs} onPeek={onPeek} />;
  }
  return <StaticTerm kind={term.kind} bell={term.id === "t-infra" && sim.bell} />;
};

Object.assign(window, { TermView });
