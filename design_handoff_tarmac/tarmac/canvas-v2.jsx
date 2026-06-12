/* Tarmac v2 — canvas assembly */

const V2Intro = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "28px 36px", display: "grid", gridTemplateColumns: "1fr 1fr", gap: 36, fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>收斂後的模型</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        <b>Terminal 是主體,文件是召喚物。</b><br />
        · 預設整窗都是 terminal(tabs + splits)<br />
        · 文件三態:<b>dock</b>(收在左欄)→ <b>peek</b>(滑出層,<br />　 焦點不離開 terminal)→ <b>pin</b>(釘成磚塊,Tiles)<br />
        · 左 dock = Index 的收合形:repo 分組、provenance 點<br />
        · 右 rail = Tower 的活動軌 + strips 切換,⌘K 召喚<br />
        · agent 在輸出裡提到的文件路徑就是入口 —<br />　 ⌘click peek,⌘⏎ pin
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>快捷鍵語言</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        ⌘P peek 最新 agent 文件 · ⌘E index 展開/收合<br />
        ⌘K strips 切換 · ⌘J 跳到活動事件<br />
        ⏎ peek · ⌘⏎ pin/unpin · esc 關 peek · ⌫ 返回<br /><br />
        <b>不變的規則:</b>peek 永不奪走 terminal 焦點;<br />
        關鍵時刻(flag / 改寫保留位置 / restore)沿用 02 區。
      </Annot>
    </div>
  </div>
);

const App = () => (
  <DesignCanvas>
    <DCSection id="v2-intro" title="00 · v2 收斂:Terminal-first" subtitle="Tiles 骨架 + Index 左 dock + Tower 活動軌 · 2026-06-12">
      <DCArtboard id="v2-readme" label="模型與快捷鍵" width={1080} height={360}><V2Intro /></DCArtboard>
    </DCSection>

    <DCSection id="v2-flow" title="01 · 文件的三態:dock → peek → pin" subtitle="同一份文件被召喚的過程">
      <DCArtboard id="r1" label="Runway — 預設:整窗 terminal,左 dock 收著 6 份文件" width={1180} height={740}><R1Runway /></DCArtboard>
      <DCArtboard id="r6" label="召喚入口 — agent 輸出裡的文件路徑可 hover/⌘click" width={1180} height={740}><R6Links /></DCArtboard>
      <DCArtboard id="r2" label="Peek — 滑出層;焦點留在 terminal,esc 即收" width={1180} height={740}><R2Peek /></DCArtboard>
      <DCArtboard id="r3" label="Pin — 釘成磚塊;terminal 仍占主導" width={1180} height={740}><R3Pin /></DCArtboard>
    </DCSection>

    <DCSection id="v2-nav" title="02 · 導航:Index 與 Strips" subtitle="左 dock 展開 = Index;右 rail = strips + agent 活動">
      <DCArtboard id="r4" label="Index — ⌘E 展開左 dock,repo 分組" width={1180} height={740}><R4Index /></DCArtboard>
      <DCArtboard id="r5" label="Rail — strips 切換 + 活動時間軸" width={1180} height={740}><R5Rail /></DCArtboard>
    </DCSection>
  </DesignCanvas>
);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
