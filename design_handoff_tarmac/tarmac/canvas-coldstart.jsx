/* Tarmac — cold start canvas */

const App = () => (
  <DesignCanvas>
    <DCSection id="cs" title="冷啟動 flow — 介面跟著事實長出來" subtitle="開機只有 shell;dock 在第一次 tarmac open 才誕生 · 2026-06-12">
      <DCArtboard id="cs1" label="1 · 開機 — 一個 shell,一行提示" width={1080} height={680}><CS1 /></DCArtboard>
      <DCArtboard id="cs2" label="2 · cd 進 repo、跑 claude — strip 自動改名" width={1080} height={680}><CS2 /></DCArtboard>
      <DCArtboard id="cs3" label="3 · 第一次 tarmac open — dock 誕生 + toast" width={1080} height={680}><CS3 /></DCArtboard>
      <DCArtboard id="cs4" label="4 · 第一次 peek — 焦點從未離開 prompt" width={1080} height={680}><CS4 /></DCArtboard>
      <DCArtboard id="cs-rules" label="規則" width={760} height={320}><CSRules /></DCArtboard>
    </DCSection>
  </DesignCanvas>
);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
