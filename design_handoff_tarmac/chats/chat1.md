# macOS 應用設計

_Started 2026-06-12 04:19 UTC_

---

## User

我們來根據我貼上的文字來設計一款新產品吧。這會先以 macos app 的形式呈現

## Assistant

_[tool: questions_v2]_

讀完這份 brief 了 — 這是個很有趣的題目:一個 path-centric 的 agent cockpit,終端機 + live markdown 並排,而且 agent 是介面的共同駕駛。§6 和 §7 留了很多開放問題,正好是設計該回答的。

在開始之前,我需要先確認幾個方向性的問題(特別是 brief 裡明確說「待定」的那些):

## User

Questions answered:
- design_context: 沒有,從零開始(你來定視覺方向)
- aesthetic: 混血:暗色但精緻,介於 terminal 和 native 之間(類似 Zed 的感覺)
- agent_power: 分情境:閒置時可切換、人類正在閱讀時只標記
- layout: 完全自由:窗格可移動、可多開
- tab_model: Decide for me
- deliverable: 靜態 hi-fi 畫面集(canvas 上多張並排比較)
- key_moments: 全部都要
- variations: 4
- provenance: 很低調:小圓點/微妙色彩就好
- doc_render: 設計上不預設,兩種都能套
- terminal_chrome: 要 tabs + splits

## Assistant

_[tool: update_todos]_

_[tool: copy_starter_component]_

很好的答案組合 — 「Zed 感的混血暗色 + 完全自由窗格 + 低調 provenance + 全部關鍵時刻」給了我清楚的骨架。開始動工:

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: done]_

_[tool: fork_verifier_agent]_

第一輪探索畫布已經開好了。內容:

**00 · Read me** — 我的假設(奪焦規則、agent 動詞、session 命名提案「strip」)、視覺系統(暗色混血:SF Pro + IBM Plex Mono、青=agent、琥珀=等你、repo 色點)、provenance 語言。

**01 · 四個方向**(同一份工作狀態,可混搭):
- **A · Two-up** — 經典雙窗格,doc tabs 在標題列
- **B · Index** — repo 分組側欄 + 全寬「跑道」終端
- **C · Tiles** — 完全自由窗格,文件/終端是對等磚塊(畫了拖曳中狀態)
- **D · Tower** — 閱讀優先 + agent 活動時間軸 + 抽屜終端

**02 · 八個關鍵時刻** — 空狀態、flag 不奪焦、改寫保留位置、閒置自動切換 + ⌫ 返回、session restore、⌘K strip 切換器、agent 三態語言、tab 解剖與撞名消歧。

備註與下一步:
- Read me 板上的假設請當作待糾正清單 — 尤其閒置門檻(我先設 3 分鐘)和 agent 動詞集
- 看完後告訴我想混哪些(例如 B 的側欄 + D 的活動軌),下一輪可以收斂成 1–2 個方向再深化,或直接做成可互動 prototype

## User

Found issues — fixing…

## User

No issues found

## User

No issues found

## Assistant

修好了,驗證通過。畫布已就緒:

- **00** 先看 Read me 板 — 假設清單請當作待糾正項
- **01** 四個方向(Two-up / Index / Tiles / Tower)— 可混搭
- **02** 八個關鍵時刻 — 適用於任一方向

看完告訴我想收斂的組合(例如「B 的側欄 + D 的活動軌」),或哪個時刻的處理要再推幾個變化,下一輪深化。

## User

design system 都可以。
整體而言我希望 terminal 是互動主體，viewier 是需要時可以叫出來看。我覺得 Tiles 的方向不錯，但會需要一個類似 Index 的功能來知道已經開了哪些 docs 還有 Tower 的 agent activities 來切換到不同的 session。
關鍵時刻設計的不錯

## Assistant

_[tool: write_file]_

_[tool: write_file]_

Tiles 為骨架、terminal 為主體、Index + Activity 變成兩側可收合的 rail — 這個組合很清楚。我來做收斂版 v2:

_[tool: write_file]_

_[tool: write_file]_

_[tool: done]_

_[tool: fork_verifier_agent]_

v2 收斂版完成。核心模型一句話:**terminal 是主體,文件是召喚物** — 三態是 **dock**(左欄收合的 Index,repo 分組 + provenance 點)→ **peek**(滑出層,焦點永不離開 terminal,esc 即收)→ **pin**(釘成 Tiles 磚塊)。

七張畫面:

- **00** 模型與快捷鍵語言(⌘P peek / ⌘E index / ⌘K strips / ⌘⏎ pin)
- **01 三態流程** — Runway 預設整窗 terminal → agent 輸出裡的文件路徑就是召喚入口(⌘click)→ Peek → Pin
- **02 導航** — ⌘E 展開左 dock 成 Index;右 rail = strips 切換 + Tower 的活動時間軸

備註:
- 「agent 輸出路徑可點」是這版的 signature interaction — 文件入口就在 agent 說話的地方,不用離開 terminal
- v1 的八個關鍵時刻(flag、改寫保留位置、restore…)全部相容,沿用即可
- 下一步建議:選定後做成可互動 prototype(能真的 ⌘P 召喚、切 strips),或先對 peek 的寬度/釘選行為再出變化

## User

我在想我們 agent 的行為應該是不需要做那麼細，我是只打算用 terminal 來呼叫 claude code 等 cli tool，沒有想要做一層 wrapper or 自己的 harness。原本提到的 agent activities 就會是有打開的 tool process with a name

## Assistant

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

這個釐清很關鍵 — Tarmac 不做 harness,那介面就只能建立在「app 真的觀察得到的訊號」上。我把 v2 的語意層全部換成誠實訊號:**process 表(前景程序名)、fswatch(檔案 mtime)、`tarmac open` 的呼叫來源、terminal bell**。出 v3:

_[tool: done]_

_[tool: fork_verifier_agent]_

v3 完成。整個語意層換成四個可觀察訊號,介面不再假裝懂 agent:

**替換表**(00 板有完整對照):
- 「agent working」→ 前景程序還在跑(⠧ + 程序名 + 時長,來源:process 表)
- 「agent 開了文件」→ `tarmac open` 被呼叫(青點 — 它就是普通 CLI,claude 跑或你跑都一樣)
- 「agent 改寫了」→ fswatch 看到 mtime 變了(光環脈衝)
- 「waiting on you」→ 背景 tab 響了 bell(琥珀 — 由工具自己發 BEL)
- 「activity 時間軸」→ rail 變成 **processes + file events** 兩段

**畫面**:terminal tab 標籤直接是 `claude · payments-api` 這種「程序名 + cwd」;rail 列出 strips / 跑著的程序 / 檔案事件;peek 的 meta 只說事實(「✎ 5s · during claude」);新增「程序結束」時刻 — exit 0 + toast 告訴你跑動期間哪些文件變了。

備註:
- 輸出裡的路徑連結化(⌘click peek)保留 — 那只是 regex,不算 harness
- 「during claude」是時間相關性不是因果,設計上刻意用這種措辭
- dock/peek/pin 三態與快捷鍵沿用 v2

下一步可以做可互動 prototype,或先確認 bell 當「唯一等你訊號」夠不夠用(claude code 會在需要確認時響 bell,但不是所有工具都會)。

## User

這版的 tiles 可以像 v1 C 選項那樣可以自由拖拉的設計嗎？

## Assistant

_[tool: write_file]_

_[tool: str_replace_edit]_

_[tool: str_replace_edit]_

可以 — pin 本來就該落進 v1 C 那種自由磚塊系統。我把它接起來:**peek 是浮層,⌘⏎ pin 就是把文件「放上桌面」,放哪裡自己拖**。補三張畫面:

_[tool: done]_

_[tool: fork_verifier_agent]_

v3 加了「02 · 自由磚塊」一節,三張畫面把 v1-C 的拖拉接進來:

- **Pin 落桌** — 從 peek 拖出去:拖到邊緣出現分割預覽(青色虛線區),拖到磚上交換位置;⌘⏎ 就地釘下
- **Tiles 四磚自由排** — 文件與 terminal 是對等磚塊,畫了一磚拖拉中(lift + 虛線 dropslot),磚頭顯示誠實訊號(claude ⠧ 4m12s、bell 3m、✎ 5s)
- **磚內 splits** — 一磚裡仍可上下分割(claude + shell 同磚),tab/splits 不因磚塊化而消失

規則:peek 永遠是浮層;pin 才落進桌面;**佈局存在 strip 上**,restore 時整桌還原。

下一步建議:這個模型(dock → peek → pin/拖拉 + 誠實訊號)感覺已經收斂得差不多,可以做成可互動 prototype 驗證拖拉手感了 — 要嗎?

## User

好那我覺得先用這版做一次 prototype

## Assistant

_[tool: copy_starter_component]_

好,把 v3 做成可互動 prototype。先拿 tweaks 面板的腳手架:

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: done]_

_[tool: fork_verifier_agent]_

Prototype 完成,v3 模型全部可動。打開後 claude run 會自動開跑(約 22 秒一輪):

**可以試的事**
- **看 claude 跑** — 輸出逐行出現;~9s 寫入 `handoff.md`(dock 圖示脈衝 + file event)、~12s 它呼叫 `tarmac open` 開了 runbook(toast + 青點)、~12s infra tab 響 bell(琥珀)、~22s exit 0 + toast
- **召喚文件** — 點 dock 圖示、點輸出裡的路徑連結、點 rail 的 file event,都會 peek(滑出層);`esc` 收
- **釘磚 + 拖拉** — peek 裡 `⌘⏎`(或點 pin)落桌;抓磚塊標題列拖到另一磚上交換位置,terminal 磚也能拖
- **快捷鍵** — `⌘P` peek 最新變更、`⌘E` 展開 Index、`⌘K` strip 切換器(exp-search 可切過去;billing-fire 是 detached 空狀態)
- **Tweaks** — accent 色 ×4、peek 寬度、右 rail 開關、motion 開關、**Replay claude run** 重播模擬

**已知簡化**:拖拉只做「交換」不做「拖到邊緣分割」;磚內 splits 沒做;bell 點進 infra tab 即清除。

試完手感後告訴我:peek 的觸發/寬度、拖拉要不要升級成邊緣分割、或哪個時刻的節奏不對,下一輪修。

## User

lgtm

## Assistant

_[tool: snip]_

👍 收工。目前專案裡有三份產出:

- **Tarmac — Interactive Prototype** — 最新的可互動版(v3 模型)
- **v3 No-harness** / **v2 / v1 canvas** — 歷次靜態探索,留作決策紀錄

之後想繼續的自然下一步:把拖拉升級成邊緣分割、磚內 terminal splits、或開始整理成給工程的 handoff 規格。隨時叫我。

## User

欸我想知道這樣我們要怎麼開始？

## Assistant

好問題 — 設計收斂到這裡,可以開工了。我建議這樣切:

**先做三個技術決定**(都影響架構,越早定越好):
1. **Terminal 引擎** — libghostty(brief 原本的傾向)或 SwiftTerm。這決定 app 殼:libghostty 偏向 Swift/AppKit 原生殼
2. **Markdown 渲染** — webview(快、樣式即我們的 CSS)或原生(之後再換)。建議 v0 先 webview,設計上本來就兩種都能套
3. **`tarmac open` 的通道** — CLI 寫一個小 binary,透過 unix socket 跟 app 講話(最簡單、agent 跑起來也自然)

**里程碑切法**(每個都是可用的 app,不是半成品):
- **M0 走路骨架**:一個視窗 = 一個 terminal + `tarmac open foo.md` 能讓文件以 peek 滑出 + FSEvents 監看改動就重新渲染 → 這時你就可以真的拿 claude code 工作了
- **M1 文件三態**:dock / peek / pin 磚塊 + 拖拉交換、青點/脈衝訊號
- **M2 誠實訊號**:tab 標籤 = 前景程序名(`tcgetpgrp`)、bell 偵測、exit toast、rail 的 processes + file events
- **M3 strips**:tmux attach/detach、session restore、⌘K 切換器

**我這邊能直接幫上的**:把 prototype 整理成 **Claude Code 的開發 handoff 包** — 設計規格(tokens、間距、所有狀態)、互動行為表(快捷鍵、奪焦規則、訊號對照)、加上 M0–M3 的驗收條件,讓你直接餵給 Claude Code 開始蓋。

要我現在做 handoff 包嗎?還是你想先討論技術選型(例如 libghostty vs SwiftTerm 的取捨)?

## User

我是指從 0 開始叫起 tarmac，也是要有從 terminal 開始嗎？

## Assistant

對 — 在這個模型裡,**開機畫面就是一個 shell**,沒有別的。Tarmac 本質上是「會長出文件的 terminal」,不是「附了 terminal 的文件 app」。

冷啟動兩條路:

1. **從 Dock/Spotlight 開 app** → 得到一個新 strip,裡面就是一個 zsh(在 `~` 或上次的 cwd)。你 `cd` 進 repo、跑 `claude`,該發生的就開始發生 — dock 是空的,第一份文件出現的瞬間就是有東西呼叫了 `tarmac open`
2. **從任何現有 terminal** → 打 `tarmac .`,把當下 cwd 收進一個 strip(像 `code .` 的習慣)

關鍵是:**文件區完全不需要「設定」或「匯入」** — 它只反映誰呼叫過 `tarmac open`。所以第一次啟動唯一要教的就是這一個指令(v1 空狀態畫面就是這樣設計的,只印兩行用法提示)。

要不要我把冷啟動序列畫出來?四格:空 shell → 你跑 claude → 第一次 `tarmac open` 長出 dock → 第一次 peek。這樣 onboarding 的節奏就定了。

## User

nji3u3

## Assistant



## User

好你畫一下 flow

## Assistant

_[tool: write_file]_

_[tool: write_file]_

_[tool: write_file]_

_[tool: done]_

_[tool: fork_verifier_agent]_

冷啟動 flow 畫好了,四格 + 規則板:

1. **開機** — 就一個 shell。唯一教學是 prompt 下方一行小字(出現過一次就不再出現)
2. **cd + 跑 claude** — strip 自動從 `strip-1` 改名成 `payments-api`(取自 cwd)
3. **dock 誕生** — 第一次 `tarmac open` 才長出左欄;不是「空 dock」,是之前根本沒有 dock。配 toast「first doc」
4. **第一次 peek** — 焦點從未離開 prompt;到這裡使用者已見過全部核心概念

規則板上最重要的一條:**介面跟著事實長出來** — 沒有歡迎頁、沒有設定。另一條入口是在任何 terminal 打 `tarmac .`(同 `code .` 習慣)。

有個值得想的點:第 2 格 strip 自動命名我假設取 cwd 的 repo 名 — 如果一個 strip 裡跨多個 repo(像 infra-week 那種),首次命名後就不再自動改。OK 的話這份 flow 可以併進 handoff 規格。

## User

Found issues — fixing…

## User

No issues found

## User

No issues found

## Assistant

驗證通過,chips 不再換行。冷啟動 flow 完工 — 目前 Tarmac 的設計資產:

- **Interactive Prototype** — v3 模型可互動版
- **Cold Start Flow** — 開機到第一次 peek 的四格 + 規則
- v1–v3 靜態畫布 — 決策紀錄

下一步隨你:做 Claude Code handoff 包(規格 + M0–M3 驗收條件),或繼續磨某個細節。

## User

好，就先這樣，準備一個 handoff package 吧。

## Assistant

_[tool: read_skill_prompt]_

_[tool: write_file]_

_[tool: copy_files]_

_[tool: present_fs_item_for_download]_

Handoff 包好了,上面可下載。內容:

- **README.md** — 自足的實作規格:核心模型(三態 + 四個誠實訊號對照表)、9 個 view 的精確尺寸/顏色/字級、互動規則(奪焦政策、pulse 衰減、focus 規則)、design tokens 全表、state 結構、M0–M3 里程碑與驗收條件
- 全部 HTML 設計檔(prototype + v1–v3 + cold start)與原始碼,README 開頭註明這些是設計參考、不是 production code

兩個小提醒:README 裡技術選型(libghostty vs SwiftTerm、unix socket)寫成建議而非定案,留給實作時決定;要不要附畫面截圖進包裡?預設沒放,需要就說。

