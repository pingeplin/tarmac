/* Tarmac v3 — canvas assembly */

const V3Intro = () => (
  <div style={{ width: "100%", height: "100%", background: "#faf8f4", borderRadius: 10, padding: "28px 36px", display: "grid", gridTemplateColumns: "1.1fr 1fr", gap: 36, fontFamily: "var(--tm-sans)", textAlign: "left" }}>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>修正:沒有 harness,只有訊號</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        Tarmac 不包裝、不解析 agent。terminal 裡跑的就是<br />
        claude / npm / pytest 本人。介面只建立在四個可觀察事實上:<br /><br />
        · <b>process 表</b> — 每個 tab 的前景程序名 + cwd + 起訖/exit code<br />
        · <b>fswatch</b> — 已開文件的磁碟變更(mtime)<br />
        · <b>CLI 呼叫</b> — tarmac open 是普通指令,誰都能跑(包括 agent)<br />
        · <b>bell</b> — BEL 字元;工具自己決定何時需要人
      </Annot>
    </div>
    <div>
      <div style={{ font: "600 11px var(--tm-mono)", letterSpacing: "0.14em", color: "#b3aa97", marginBottom: 14 }}>語意層的替換表</div>
      <Annot style={{ color: "#5c564a", fontSize: 11.5, lineHeight: 1.9 }}>
        「agent working」→ <b>前景程序還在跑</b>(⠧ + 程序名 + 時長)<br />
        「agent 開了文件」→ <b>tarmac open 被呼叫</b>(青點)<br />
        「agent 改寫了」→ <b>檔案 mtime 變了</b>(光環脈衝)<br />
        「waiting on you」→ <b>背景 tab 響了 bell</b>(琥珀)<br />
        「activity 時間軸」→ <b>process 列表 + file events</b><br /><br />
        v2 的 dock / peek / pin 三態與快捷鍵全部保留。
      </Annot>
    </div>
  </div>
);

const App = () => (
  <DesignCanvas>
    <DCSection id="v3-intro" title="00 · v3:No harness" subtitle="只用可觀察訊號:process 表 · fswatch · CLI · bell — 2026-06-12">
      <DCArtboard id="v3-readme" label="訊號模型與替換表" width={1080} height={380}><V3Intro /></DCArtboard>
    </DCSection>

    <DCSection id="v3-screens" title="01 · 主畫面" subtitle="tab 標籤 = 程序名;rail = processes + file events">
      <DCArtboard id="h1" label="Runway — claude 就是個普通前景程序" width={1180} height={740}><H1Runway /></DCArtboard>
      <DCArtboard id="h2" label="Rail — strips / processes / file events" width={1180} height={740}><H2Rail /></DCArtboard>
      <DCArtboard id="h3" label="Peek — meta 只說事實:✎ 5s · during claude" width={1180} height={740}><H3Peek /></DCArtboard>
      <DCArtboard id="h5" label="程序結束 — exit 0 + 「跑動期間 2 份文件變了」" width={1180} height={740}><H5Exit /></DCArtboard>
    </DCSection>

    <DCSection id="v3-tiles" title="02 · 自由磚塊（v1-C 的拖拉）" subtitle="pin = 把文件放上桌面；文件與 terminal 是對等磚塊，佈局隨 strip 保存">
      <DCArtboard id="t2" label="Pin 落桌 — 拖到邊緣分割、拖到磚上交換" width={1180} height={740}><T2PinDrop /></DCArtboard>
      <DCArtboard id="t1" label="Tiles — 四磚自由排，一磚拖拉中" width={1180} height={740}><T1Tiles /></DCArtboard>
      <DCArtboard id="t3" label="磚內仍可 splits — claude + shell 同一磚" width={1180} height={740}><T3TermSplit /></DCArtboard>
    </DCSection>

    <DCSection id="v3-anatomy" title="03 · 訊號解剖" subtitle="每個記號對應一個可觀察事實 — 不猜意圖">
      <DCArtboard id="h4" label="記號 → 訊號來源對照" width={960} height={420}><H4Signals /></DCArtboard>
    </DCSection>
  </DesignCanvas>
);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
