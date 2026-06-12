/* Tarmac — canvas assembly: intro board + sections */

const Swatch = ({ v, n }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 5, alignItems: "center" }}>
    <div style={{ width: 40, height: 40, borderRadius: 8, background: v, border: "1px solid rgba(0,0,0,0.18)" }}></div>
    <span style={{ font: "400 9px var(--tm-mono)", color: "#7a7264" }}>{n}</span>
  </div>
);

const IntroBoard = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "30px 36px", display: "grid", gridTemplateColumns: "1.1fr 1fr 1.1fr", gap: 36, fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>假設(請糾正)</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        · macOS 原生 host;chrome 全自製<br />
        · 文件 v1 唯讀;渲染不預設 webview/native,<br />　 兩種都能套這套樣式<br />
        · agent 經 local endpoint 行動,動詞至少:<br />　 <b>open · focus · annotate · status</b><br />
        · 奪焦規則(你選的分情境):<br />　 閱讀中 → 只標記;閒置 ≥3min → 可切換,<br />　 但必附 banner + ⌫ 一鍵返回<br />
        · session 命名提案:<b>strip</b>(航管 flight strip,<br />　 呼應 Tarmac 的停機坪隱喻)
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>視覺系統</div>
      <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 16 }}>
        <Swatch v="#0c0e12" n="bg0" />
        <Swatch v="#12151a" n="bg1" />
        <Swatch v="#191d24" n="bg2" />
        <Swatch v="#d8dbe2" n="text" />
        <Swatch v="oklch(0.78 0.11 200)" n="agent" />
        <Swatch v="oklch(0.78 0.11 75)" n="wait" />
      </div>
      <div style={{ display: "flex", gap: 10, marginBottom: 16 }}>
        <Swatch v="oklch(0.72 0.09 25)" n="repo·a" />
        <Swatch v="oklch(0.72 0.09 145)" n="repo·b" />
        <Swatch v="oklch(0.72 0.09 265)" n="repo·c" />
        <Swatch v="oklch(0.72 0.09 320)" n="repo·d" />
      </div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        UI:SF Pro(系統字)· 路徑/狀態/終端:IBM Plex Mono<br />
        密度 10.5–13.5px · 圓角 6/10 · 介於 terminal 與 native
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>PROVENANCE 語言(低調版)</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.85 }}>
        一條規則:<b>青色 = agent 碰過</b>。<br />
        · 青點 = agent 開的(未讀)<br />
        · 青色光環脈衝 = 剛被改寫<br />
        · 琥珀 = agent 在等你(唯一可拉注意力的色)<br />
        · repo 色點 = 身分,跨 tab/側欄/切換器一致<br />
        · 永不彈 modal、永不動你的捲動位置<br /><br />
        <b>看圖順序:</b>01 比空間組織(四個方向可混搭),<br />
        02 比時刻 — 這些時刻適用於任一方向。
      </Annot>
    </div>
  </div>
);

const App = () => (
  <DesignCanvas>
    <DCSection id="intro" title="00 · 前提與設計系統" subtitle="Tarmac cockpit — 給 EP 的第一輪探索 · 2026-06-12">
      <DCArtboard id="readme" label="Read me first" width={1180} height={440}><IntroBoard /></DCArtboard>
    </DCSection>

    <DCSection id="dirs" title="01 · 四個整體方向" subtitle="同一份工作狀態(3 repos、agent 進行中),四種空間組織 — 可混搭">
      <DCArtboard id="dir-a" label="A · Two-up — 經典雙窗格,tab 在標題列" width={1180} height={740}><DirA /></DCArtboard>
      <DCArtboard id="dir-b" label="B · Index — repo 分組側欄 + 跑道式終端" width={1180} height={740}><DirB /></DCArtboard>
      <DCArtboard id="dir-c" label="C · Tiles — 完全自由窗格,文件與終端是對等磚塊" width={1180} height={740}><DirC /></DCArtboard>
      <DCArtboard id="dir-d" label="D · Tower — 閱讀優先 + agent 活動軌 + 抽屜終端" width={1180} height={740}><DirD /></DCArtboard>
    </DCSection>

    <DCSection id="moments" title="02 · 關鍵時刻" subtitle="Signature interactions — 適用於任一方向">
      <DCArtboard id="m1" label="首次啟動 / 空狀態" width={880} height={560}><M1Empty /></DCArtboard>
      <DCArtboard id="m2" label="你在閱讀 → agent 開了新文件:只標記" width={880} height={560}><M2Flag /></DCArtboard>
      <DCArtboard id="m3" label="你正在讀的文件被改寫:位置保留" width={720} height={520}><M3Rewrite /></DCArtboard>
      <DCArtboard id="m4" label="你閒置 → agent 切了分頁:banner + 一鍵返回" width={880} height={300}><M4Switch /></DCArtboard>
      <DCArtboard id="m5" label="重開 app:session restore" width={880} height={560}><M5Restore /></DCArtboard>
      <DCArtboard id="m6" label="多 session:strip 切換器(⌘K)" width={880} height={560}><M6Strips /></DCArtboard>
      <DCArtboard id="m7" label="agent 狀態語言:working / waiting / idle" width={760} height={300}><M7States /></DCArtboard>
      <DCArtboard id="m8" label="tab 解剖:provenance 與撞名消歧" width={920} height={400}><M8Anatomy /></DCArtboard>
    </DCSection>
  </DesignCanvas>
);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
