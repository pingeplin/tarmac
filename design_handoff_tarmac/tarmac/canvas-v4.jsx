/* Tarmac v4 — canvas assembly: strip = whiteboard, term/doc = cards */

const V4Intro = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "28px 36px", display: "grid", gridTemplateColumns: "1.1fr 1fr", gap: 36, fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>v4:從 tiling 到無限白板</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        v3 的自由磚塊仍是「分割一塊固定的桌面」。v4 改成<br />
        無限畫布:佈局不是 split,而是<b>空間位置</b> — 空間就是記憶。<br /><br />
        · <b>strip = 一塊白板</b> — 位置、大小、縮放、視角全部隨 strip 保存<br />
        · <b>terminal = 卡片</b> — 標題就是前景程序名(process 表)<br />
        · <b>開啟的文件 = 卡片</b> — tarmac open 在哪個 shell 跑,<br />
        　卡片就落在那張 terminal 卡旁,並留下一條來源虛線<br /><br />
        v3 的訊號模型一個都沒換:process 表 · fswatch · CLI · bell。
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>無限空間帶來的兩個新問題</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        <b>1 · 訊號會跑出視野</b> — bell 響在畫布另一頭怎麼辦?<br />
        　→ 訊號貼在視窗邊緣(⏎ 飛過去,esc 飛回來)<br /><br />
        <b>2 · 縮小之後字變螞蟻</b> — 內容在 36% 沒有意義<br />
        　→ 語意縮放:內容淡出,只剩程序名 / 檔名 + 訊號<br /><br />
        被取代的概念:pin / dock 消失 — open 即落卡;<br />
        不想上板的文件待在 <b>shelf</b>。peek 保留(⌘click 浮起,<br />
        ⌘⏎ 才落卡)。磚塊的「拖到邊緣分割」整個不需要了。
      </Annot>
    </div>
  </div>
);

const App = () => (
  <DesignCanvas>
    <DCSection id="v4-intro" title="00 · v4:Strip = 白板" subtitle="無限畫布 · terminal 與文件都是卡片 — 2026-06-13">
      <DCArtboard id="v4-readme" label="概念對應與新問題" width={1080} height={400}><V4Intro /></DCArtboard>
    </DCSection>

    <DCSection id="v4-board" title="01 · 白板主畫面" subtitle="卡片自由擺放 · 來源虛線 = tarmac open 的呼叫關係 · shelf = 未上板">
      <DCArtboard id="b1" label="Board — 4 張卡 + 來源虛線 + minimap" width={1180} height={740}><B1Board /></DCArtboard>
      <DCArtboard id="b2" label="落卡 — 卡片落在呼叫 tarmac open 的 terminal 旁" width={1180} height={740}><B2Spawn /></DCArtboard>
    </DCSection>

    <DCSection id="v4-space" title="02 · 空間的代價與解法" subtitle="訊號不能跑出視野 · 縮小要有語意">
      <DCArtboard id="b4" label="視野外訊號 — 貼邊指示,⏎ 飛過去" width={1180} height={740}><B4Offscreen /></DCArtboard>
      <DCArtboard id="b3" label="語意縮放 36% — 內容淡出,訊號留下" width={1180} height={740}><B3ZoomOut /></DCArtboard>
    </DCSection>

    <DCSection id="v4-boards" title="03 · Strips = Boards" subtitle="⌘K 換白板;縮圖就是上次離開的佈局">
      <DCArtboard id="b5" label="Boards switcher — 縮圖 + running / bell 計數" width={1180} height={740}><B5Boards /></DCArtboard>
    </DCSection>

    <DCSection id="v4-primacy" title="04 · Terminal 主體性" subtitle="白板上人人平等?不 — 三個可疊加的機制:focus 模型 · 重力 · 駕駛艙">
      <DCArtboard id="f0" label="三個機制(可疊加,不是三選一)" width={1080} height={330}><V4bIntro /></DCArtboard>
      <DCArtboard id="f1" label="Focus 模型 — 打字永遠進 terminal,⌥tab 只巡 terminal" width={1180} height={740}><F1Focus /></DCArtboard>
      <DCArtboard id="f2" label="重力 — 文件是衛星,拖 terminal 星座一起走" width={1180} height={740}><F2Gravity /></DCArtboard>
      <DCArtboard id="f3" label="駕駛艙 — ⏎ 把 terminal 接進視窗,白板在後面流動" width={1180} height={740}><F3Dock /></DCArtboard>
    </DCSection>

    <DCSection id="v4-edit" title="05 · 文件可編輯之後" subtitle="focus 的家在 terminal — 編輯是借用,esc 永遠回家;寫入帶來新的誠實問題">
      <DCArtboard id="e0" label="規則升級 + 誠實模型多一條:寫入" width={1080} height={360}><V4cIntro /></DCArtboard>
      <DCArtboard id="e1" label="借用 focus — 編輯中,esc 回 claude" width={1180} height={740}><E1Edit /></DCArtboard>
      <DCArtboard id="e2" label="寫入衝突 — claude 改了你正在編輯的檔,不仲裁只報告" width={1180} height={740}><E2Conflict /></DCArtboard>
    </DCSection>
  </DesignCanvas>
);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
