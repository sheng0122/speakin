# SpeakMore 程式碼研究（附 Typeless 逆向分析）

對象：[zephyr4123/speakmore](https://github.com/zephyr4123/speakmore)，commit `176d619`（2026-11-09），MIT，約 4.5 萬行（JavaScript／Electron 為主，Mac 小幫手 Swift 約 1,700 行、Windows 小幫手 Go）。
比對：Speakin `fe467b9`，約 4,800 行。
日期：2026-11-10。只讀程式碼，兩邊都沒有建置或執行。

> **授權**：MIT，可以照抄，保留原著作權聲明即可。
> SpeakMore 行號以 repo 根目錄為準（`src/…`、`native/…`、`targets/typeless/docs/…`），Speakin 行號以 `Sources/Speakin/` 為準。
> Typeless 的部分是 SpeakMore 作者對 Typeless 2.8.1（Electron）的靜態逆向＋一次抓包（4 次聽寫），不是我們自己驗的。

## 總結

- SpeakMore 是照 Typeless 逆向做的開源版：三個功能（語音輸入、語音翻譯、劃詞翻譯），三種識別方式（音訊大模型直出、本機或雲端轉寫＋文字模型潤稿、純本機）。**目標是簡體中文**，繁體只是收尾時用 opencc 轉。
- 它也用 transcribe.cpp 跑 Qwen3-ASR，但字典走的是 **`vocabulary` 熱詞參數**，不是 `prompt`。它量過：本機 Qwen3-ASR 0.6B 帶熱詞，90 個專有名詞認對從 21 升到 49。Speakin 用的 TEA-ASR 是 Qwen3-ASR 1.7B 的台灣版，卻把字典和上一段結尾混在 `prompt` 裡。（11/6 已在 TEA 上測過，沒有效果，見 #1 更正。）
- 其他工程面 Speakin 大多已經領先：分段時就邊錄邊辨識、潤稿可信度檢查、改口刪句、中文學字、遮個資、Esc 吃鍵、再貼一次。SpeakMore 的潤稿沒有「結果是不是同一段話」的檢查，學字也沒有（Typeless 是把修改送上伺服器學）。
- Typeless 逆向最有用的一點是**使用資料**：作者 4 個月 3,120 筆紀錄，聽寫 3,102 筆，翻譯 7 筆，「問任何事」3 筆。重度使用者幾乎只用聽寫，翻譯和語音指令改寫先不用做。
- Typeless 逆向裡第二有用的：網址、網頁標題靠輔助使用讀，不用 AppleScript，也不用跳「自動化」權限；Chromium 系的 App 先設 `AXEnhancedUserInterface` 再讀。

## 借鏡清單

標 ✅ 的已對過 Speakin 原始碼。價值以「對 Speakin 現在的使用者」計。

| # | 項目 | 來源 | Speakin 現況 | 做法 | 價值 | 成本 |
|---|---|---|---|---|---|---|
| 1 ✅ | 字典改走辨識模型的熱詞參數 | `src/server/asr/engines/transcribe-cpp.mjs:14-16,72-75`；量測在 `bench/results/vocabulary-2026-10-19.md` | 字典前 20 詞＋上一段結尾 40 字混成一個 `prompt`（`Engine.swift:259-266`、`Store.swift:239-241`）；`run()` 只設 `p.prompt`，沒設 `vocabulary`（`Backends.swift:557-562`）。transcribe.cpp v0.4.1 的 header 有 `vocabulary`／`n_vocabulary`／`prefix` 三個欄位（`transcribe.h:1239-1242`） | 先用 `transcribe_model_supports(model, TRANSCRIBE_FEATURE_VOCABULARY)` 確認 TEA 的 GGUF 支援（**要確認**）；支援的話字典放 `vocabulary`，上一段結尾留在 `prompt`。用 `eval/` 現有錄音比：認對、硬塞、`isEcho` 觸發次數 | ~~高~~ 已測過，不做 | — |
| 2 ✅ | 潤稿提示講清楚「辨識常見的錯」 | `src/server/tasks/dictate/polish-prompt.mjs:17-21`：同音字、英文被拆開或音譯成中文（「瑞艾克特」→React）、數字寫成國字、斷句錯；「拿不準就照原文」 | 規則只寫「跟字典的詞唸起來像的改成字典寫法」（`Backends.swift:148`），沒講字典外的聽錯。`eval/prompt-loop/LOOP.md` 已經在爬同一個方向 | 把 SpeakMore 那四條當 prompt-loop 的一個候選版本跑；字典那句補「他沒講到的詞不要寫進去，唸起來不像的不要硬套」（`prompt.mjs:114`） | 中 | eval |
| 3 ✅ | 瀏覽器網域當情境 | Typeless `libContextHelper`：`findWebArea` 往下找 `AXWebArea`、`findWebInfoByTraversingUp` 從焦點往上找網址和標題（`targets/typeless/docs/07-native-helpers.md:48`），不用 AppleScript | 情境只看 App 名稱（`UI.swift:215-226`、`Backends.swift:289`），Chrome 裡寫 Gmail 和寫 Slack 都算「瀏覽器」 | 焦點元素往上找到 `AXWebArea` 讀網址（屬性名逆向文件沒寫，推測是 `AXURL`，**要確認**），網域對應情境：mail.example.com 類 → 郵件、聊天網域 → 聊天。只送類別，不送網址 | 中 | ~20 行 |
| 4 | 網頁輸入框用 text marker 讀游標前後文 | Typeless `getCurrentInputState` 對網頁內容用 `AXStringForTextMarkerRange`（`07-native-helpers.md:68`）；Chromium 系先設 `AXEnhancedUserInterface` 等 30 ms（`07-native-helpers.md:46`） | `aroundCursor` 和學字都只讀 `AXValue`＋`kAXSelectedTextRange`（`System.swift:231-242,293-297`）；只對 Electron 設 `AXManualAccessibility`（`System.swift:250,282`）。Chrome 裡的 Gmail、Notion 網頁讀不讀得到：**要確認** | 先在 Chrome 的 Gmail、Notion 網頁實測 `Learner.value` 是不是空的；空的才補 text marker 路徑。注意 `AXEnhancedUserInterface` 有副作用（部分 App 視窗動畫、定位會怪），只在讀不到時才設 | 中（若實測讀不到就是高：情境和學字在網頁都瞎） | 測 10 分鐘；補做 ~40 行 |
| 5 ✅ | 錄音中膠囊顯示已辨識的字 | 本機模式每來一塊就轉最近 8 秒給懸浮條看，不潤稿、不記帳（`src/server/refine/local.mjs:31,78-85`） | 段落在錄音中就已辨識完（`Engine.swift:249-286`），膠囊只畫音量（`UI.swift:42-45`） | 每段辨識完把最後一兩行原文顯示在膠囊上。Speakin 要 5 秒＋停頓才切一段，更新會比 SpeakMore 粗 | 低～中 | ~20 行 |
| 6 | 文字潤稿看不到停頓 | SpeakMore 實測：同一份提示詞，音訊模型分段 34/38、分點 8/16；文字模型只有 25/38、7/16，原因是「純文字模型面對一長串沒有停頓的轉寫，不敢重新組織」（`docs/implementation-notes.md` 本地轉寫一節） | 切段點就是 0.5 秒停頓（`Audio.swift:161`），但接起來時直接黏（`Engine.swift:295-301`），停頓資訊丟了 | 段落之間留一個軟標記（例如換行）給潤稿，看分段、清單有沒有變好。**純推測，要 eval** | 中（未驗證） | ~5 行＋eval |
| 7 ✅ | 「比平常久」的門檻跟著錄音長度 | Typeless：6000 ms＋每 30 秒錄音加 500 ms（`10-interaction-state-machine.md:468`） | 固定 5 秒（`Engine.swift:389-391`），長錄音每次都會跳 | 改成 5 秒＋每 30 秒加 0.5 秒 | 低 | 1 行 |
| 8 | 輸出夾簡體字的防線 | SpeakMore 反方向：Gemini 長段落會冒出繁體字，同一條 6 遍有 5 遍，收尾一律 opencc 轉（`src/server/tasks/dictate/output.mjs:9,21-25`） | 沒有任何簡繁轉換（grep 不到 opencc／`Hans`）。Haiku、本機 Qwen 4B 會不會夾簡體：**要確認** | 先查歷史紀錄有沒有簡體字；有的話，偵測到簡體專用字才用 Foundation 的 `applyingTransform(StringTransform("Hans-Hant"), reverse: false)` 轉，不要整段轉（一簡對多繁會轉錯） | 待資料 | 查 10 分鐘 |
| 9 ✅ | 本機 Qwen 不要 temperature 0 | SpeakMore 實測 Gemini 拿掉溫度 0 後，同一批 60 條寫壞的從 10 條降到 5 條，截斷和整串底線沒再出現（`docs/implementation-notes.md`） | 本機 Qwen 設 `temperature: 0`（`Backends.swift:497`） | 不同模型，不能直接套。只在 Qwen 出現截斷、重複時才拿 eval 比 0 和預設值 | 低 | eval |
| 10 ✅ | 歷史「換模型重跑」 | `src/app/rerun.mjs` | 重新辨識用當下設定（`Engine.swift:431-436`） | 歷史紀錄的重新辨識多一個選單選模型。比模型時有用，日常用不到 | 低 | 小 |
| 11 ✅ | 語音翻譯 | 先整理成原文再翻，`<原文>`、`<譯文>` 兩段標籤，歷史存原文（`src/server/tasks/translate/prompt.mjs`、`output.mjs:25`） | 沒有（grep 不到 translate／翻譯） | 要做的話照它的提示詞結構：先整理再翻，原文存歷史。但見下方使用資料 | 低 | 中 |
| 12 | 選取文字＋語音指令改寫（Typeless「問任何事」） | 服務端回 `delivery`：`replace` 貼回、`reply` 開卡片、`external` 開網址（只放行 http/https/mailto）（`14-result-delivery.md`）；讀不到選取就模擬 ⌘C（`07-native-helpers.md:70`） | 沒有 | 同上，先不做 | 低 | 中～高 |

> **#1 更正（2026-11-10）**：11/6 已在 TEA-ASR 上測過（`eval/2026-11-06-asr-models.md`「字詞表 vs 前文提示」一節，28 段真實錄音、18 個詞）：只放提示、只放字詞表、兩邊都放，結果幾乎一樣，worktree、BQ 三種都還是錯；只放字詞表時模型還把整串詞抄進結果。SpeakMore 的提升是在 0.6B 上量的，TEA 1.7B 沒有同樣效果。維持現狀。

## UI／UX 可以學的

評估標準：文案極簡、不要堆說明文字、跟主畫面風格一致。截圖看過 README 的語音輸入、首頁、歷史三張。SpeakMore 的介面規範寫在 `docs/desktop-ui-spec.md`、`docs/PRODUCT.md`，文案規則還有測試把關（`test/i18n/copy-lexicon.test.mjs`）。

| # | 項目 | 它怎麼做 | Speakin 現況 | 建議做法 | 價值 | 成本 |
|---|---|---|---|---|---|---|
| U1 | 設定項不寫第二行說明 | 規範：「不寫大字一行、小字一行的說明」，名字、狀態、數字、要使用者做的事以外不加解釋，細節放滑鼠停留提示；隱私相關的事實（存在哪、發給誰）照寫（`docs/desktop-ui-spec.md` §1） | 設定頁幾乎每項都有第二行說明，有的寫到三句（`UI.swift:666-748`，例：`:694`、`:725`、`:735`） | 第二行全部移到 `.help`。只留隱私事實，縮成名詞短語：「個資、金鑰先遮掉」「僅存本機」 | 高 | 文案＋~30 行 |
| U2 | 錄音中顯示按鍵提示 | 懸浮條上方一行「再按一下 右⌥ 完成 · esc 取消」，按鍵畫成鍵帽、不寫加號；設定可關（`src/renderer/bar/bar-view.mjs:54-69`、`src/i18n/locales/zh-TW.mjs` 的 `bar.recording`） | 膠囊只有音量條和秒數（`UI.swift:39-49`）；「兩種都可以」模式下新手不知道怎麼結束、Esc 能取消 | 膠囊上方加一行淡字「Fn 完成 · esc 取消」，前 20 次顯示，之後自動隱藏（這點是我們自己的建議，SpeakMore 是用開關控制） | 中 | ~15 行 |
| U3 | 貼上後打勾 | 拿到結果、沒有別的話要說時打勾 0.9 秒再收起；取消的直接消失（`bar-view.mjs:17-21,39-40`） | 貼上後膠囊直接消失（`Engine.swift:419-421`），貼進沒反應的 App 時分不出是成功還是沒貼 | 結束時顯示一個品牌色勾，0.8 秒後收起 | 中 | ~10 行 |
| U4 | 錯誤寫「原因：去哪修」 | 「缺麥克風權限：系統設定 › 隱私與安全性 › 麥克風」「麥克風沒訊號：查輸入裝置、是否靜音」（`zh-TW.mjs` 的 `bar.*`）；錯誤和提示留 4 秒，錯誤有圖示（`bar-view.mjs:17-21`） | 「麥克風打不開」「麥克風沒收到聲音」「辨識失敗，再講一次」（`Engine.swift:211,239,398`），所有訊息都留 3 秒、同一個樣式（`Engine.swift:180-185`） | 麥克風那兩句補上去哪修；錯誤加一個小圖示、留 4 秒 | 中 | 文案＋~5 行 |
| U5 | 安全輸入提示 | 「有應用開著安全輸入，部分組合鍵暫時用不了」（`bar.secureInput`） | 沒有，1Password、密碼欄開著時 Fn 沒反應也沒提示（typewhisper.md #12） | 按 Fn 時查 `IsSecureEventInputEnabled()`，膠囊寫「安全輸入開著，Fn 暫時無效」 | 中 | ~5 行 |
| U6 | 匯入字典先預覽 | 對話框：「{檔案} 中有 N 個新詞」＋「已在詞典中 X · 檔案內重複 Y · 無效 Z」→ 按鈕「新增 N 個」（`zh-TW.mjs` 的 `vocabulary.dialogs.import`） | 選完檔案直接匯入，再跳「已匯入 N 個詞」（`UI.swift:549,590-594`）；選錯檔案要一個個刪 | 匯入前顯示數字並確認；或者匯入後提示框附「復原」 | 中 | ~30 行 |
| U7 | 刪除可以收回 | 刪詞有確認框，結果用「已刪除「X」」提示（`vocabulary.dialogs.remove`、`vocabulary.toast`） | 字典單筆刪除、勾選多筆刪除都是按了就刪，沒有確認也不能復原（`UI.swift:482,531`） | 不加確認框（太囉嗦），改成提示「已刪除 N 個 · 復原」5 秒 | 中 | ~20 行 |
| U8 | 文案規則寫成清單 | 按鈕 2～4 字的動詞、狀態用名詞、操作結果寫「已＋動詞」、不寫句尾標點；「不再使用」的說法有測試擋（`desktop-ui-spec.md` §1） | 沒有成文規則，靠每次改的人注意 | 在 Speakin repo 寫一頁文案規則（5 條＋禁用說法對照表），之後改 UI 照它檢查；先不用寫測試 | 中 | 文件 |
| U9 | 停用的按鈕說明原因 | 不能用的按鈕保留、變灰，滑鼠停留時說原因，不隱藏（`desktop-ui-spec.md` §3） | 「再貼一次」沒有結果時變灰，沒說原因（`App.swift:142-144`）；SwiftUI 選單裡的項目不能顯示停留提示 | 主視窗裡的停用按鈕補 `.help`；選單列的照舊 | 低 | 小 |
| U10 | 選單列第一行寫狀態 | 「就緒 · 按 右⌥ 說話」，缺東西時「還差：…」（`zh-TW.mjs` 的 `tray`） | 只有沒有輔助使用權限時才多一行（`App.swift:131`），平常不顯示，比較乾淨 | 不加「就緒」；「還差」的範圍從權限擴大到「辨識模型未下載」 | 低 | 小 |
| U11 | 聲波從中間往兩邊擴散 | 仿 Typeless：每個字從中間激起一道波，往兩邊遞減（`src/renderer/bar/wave.mjs:1-5`）；整理中是一道滾過去的波，取代轉圈 | 音量條往左捲動（`UI.swift:41-45`），整理中是轉圈（`UI.swift:68-81`） | 純外觀，有空再做 | 低 | 中 |
| U12 | 歷史依功能篩選、匯出 | 分段控件「全部 · 語音輸入 · 語音翻譯 · 劃詞翻譯」，右上「匯出」Markdown／JSON／CSV（截圖、`src/app/history-export.mjs`） | Speakin 只有一種功能，不需要篩選；沒有匯出 | 不用做。要匯出的話右鍵選單加一項就好 | 低 | 小 |

**Speakin 已經比較好的**：

- 歷史紀錄：滑鼠停留才出現的操作（看原文、重播、重新辨識、修正並學字、複製、刪除），搜尋也找得到「常被聽成」的寫法（`UI.swift:380-428`、`Store.swift:256-260`）。SpeakMore 只有複製、播放、換模型重跑。
- 首次引導有「按 Fn 照著唸」，並顯示聽到的字（`Onboarding.swift:301-306`）。SpeakMore 的引導刻意不讓使用者試講，只檢查按鍵和權限。
- 貼不進去時：Speakin 直接把結果留在剪貼簿，提示「已複製，按 ⌘V 貼上」（`Engine.swift:418`）。Typeless 要點懸浮條上的「點擊複製」，SpeakMore 的懸浮條也要另外攔截點擊。
- 膠囊出現在滑鼠所在的螢幕（`UI.swift:26-29`）。SpeakMore 固定在主螢幕，文件列為還沒做（`docs/implementation-notes.md`）。
- 首頁「在哪裡講話」依 App 類別分區（`UI.swift:176-205`），SpeakMore 沒有。它的熱力圖、連續天數是遊戲化設計，不用跟進。
- 懸浮條上的 ✕／✓ 按鈕不建議跟進：SpeakMore 為了點按鈕不搶焦點，另外開了一個事件攔截，代價很高（`docs/implementation-notes.md` 介面一節）。Speakin 用 Fn／Esc 就夠了。

## Typeless 逆向：Speakin 已經有、沒有、不用做的

**使用資料**（`targets/typeless/docs/08-local-data.md`，作者本機 2026-06-02～10-13）：

| 模式 | 筆數 | 平均長度 |
|---|---|---|
| 聽寫完成 | 2,854 | 31.3 秒 |
| 聽寫取消 | 248 | 7.4 秒 |
| 翻譯 | 7 | |
| 問任何事 | 3 | 4.5 秒 |

另外 2.8.1 已經拿掉「按住說話」（按住超過 600 ms 會取消並提示「按一下就好」，`10-interaction-state-machine.md:434-446`）。單一使用者的資料，只能當參考，不能代表所有人。

**Speakin 已經有的**（不用再做）：

| Typeless 做法 | Speakin 對應 |
|---|---|
| 邊說邊傳，結束時伺服器手上已有大部分音訊 | 錄音中切段就辨識（`Engine.swift:249-286`） |
| 貼上後追蹤修改 15 秒，送 `/user/traits`，伺服器自動加詞典 | 本機學字（`System.swift:299-333`），不上傳，還能「復原剛學的字」 |
| 剪貼簿寫入帶 transient 標記、用鍵盤配置找 V 的鍵碼 | `System.swift:172,212-226` |
| 再貼一次上一條（Ctrl+⌘V） | ⌥⇧V（`System.swift:5`、`Engine.swift:147-150`） |
| 按著熱鍵又按別的鍵就取消、300 ms 防連按 | `System.swift:33`、`Engine.swift:153` |
| 錄音上限 9 分鐘、最後 1 分鐘倒數 | 10 分鐘、最後 1 分鐘變橘色（`Engine.swift:46,240`） |
| 找不到可編輯的輸入框就給「點擊複製」 | 找不到焦點元素就留在剪貼簿＋提示（`Engine.swift:402-418`） |
| 錄音時把系統輸出靜音、合蓋偵測 | 靜音有（`Engine.swift:162-172`）；合蓋見 typewhisper.md #17 |
| 麥克風完全沒訊號就結束 | 5 秒沒訊號自動停（`Engine.swift:237-239`） |
| 所有 AX 呼叫設逾時 | 全域 0.3 秒（`Engine.swift:85`） |

**隱私上 Speakin 做得比較對**：Typeless 在 iTerm2 一次聽寫送出游標前 5,000 字＋可見文字 10,000 字＋周圍 1,000 字，終端機裡剛顯示的金鑰也一起上傳；它的黑名單本意是「哪些 App 的 AX 不可靠」，不是隱私分級（`06-context-capture-and-privacy.md`）。Speakin 只送游標前 300／後 100 字、視窗最後 2,000 字，送出前遮 email、金鑰、身分證、卡號、電話（`System.swift:240`、`Engine.swift:197`、`Text.swift:123-134`）。可以考慮的一步：前景是終端機（`System.swift:198` 那份清單）時不送 `<畫面>`，正規式遮不到的內部資料不會出去。價值低，看要不要。

**不用做**：

- 雲端串流、HTTP 備援賽跑、弱網降級、RSA 加密上下文、登入、雲端同步：Speakin 是本機辨識，沒有這些問題。
- 每秒常駐輪詢焦點、統計「最近 60 秒打了 60 個字就提示用語音」：要一直讀使用者的按鍵，換來的價值很小。
- 富文本貼上（HTML＋純文字）：Typeless 只在「問任何事」用。
- 熱鍵子程序隔離、App 白名單／黑名單：Speakin 的熱鍵已經在專用執行緒，名單要人工維護。

## SpeakMore 不建議跟進

- Electron＋網頁錄音（WebM/Opus）＋本機 WebSocket 伺服器：為了雙平台和照抄 Typeless 協定，Speakin 不需要。
- 音訊大模型直出（Gemini、GPT Audio）：要 API key、按量計費、要送錄音上雲。它的帳本、Gemini 提示詞快取（省 61% 提示詞費用）都是這條路衍生的。
- 去掉結尾句號（Typeless 近兩個月陳述句結尾八成沒句號）：Speakin 已經按情境決定（聊天不加句號，`Backends.swift:152`）。
- `<无人声>` 標記、開頭多出外文詞的修剪：都是音訊大模型的毛病，Speakin 的 `plausible`（`Text.swift:140-156`）和 `isEcho`（`Backends.swift:45-56`）已經涵蓋同類問題。
- 任意鍵、兩鍵組合、每個功能最多 4 組熱鍵、跟系統快捷鍵撞就不給綁：做得很細（`src/hotkeys/`、`docs/hotkey-research.md` 1,100 行），Speakin 的 Fn＋右側修飾鍵已經夠。
- 主題系統、用量熱力圖、多語系介面。

---

# 細節

## 1. 架構

- 主程序 Electron（`src/app/main.mjs`，2,125 行）把聽寫伺服器（`src/server/`）跑在同一個程序裡，懸浮條渲染程序錄音、每 3 秒一塊經本機 WebSocket 送過去，協定照抄 Typeless（`start_audio`、`set_audio_chunk_info`、`end_audio`、`audio_processing_completed`）。
- 熱鍵、貼上、取選取交給原生小幫手（`native/mac/*.swift`，約 1,700 行；Windows 用 Go）。
- 三種識別方式：直出（錄音直接交給 Gemini／GPT Audio／Qwen Omni 一次出成品）、混合（本機或雲端轉寫，再交 DeepSeek 等文字模型潤稿）、離線（本機轉寫，不潤稿）。

## 2. 辨識

- 本機：transcribe.cpp（Qwen3-ASR 0.6B Q8、SenseVoice Small）或 sherpa-onnx（CPU）。GPU 上先拿 1.5 秒合成雜訊預熱（`transcribe-cpp.mjs:21-37`）。
- 長錄音切段：在「上限的一半到上限」之間找平均音量最低的 300 ms，從中間切；全靜音的段不送模型（實測 Qwen3-ASR 拿到 7.9 秒靜音會吐 "None"）（`src/server/asr/segment.mjs`）。Speakin 已有同類做法（`Audio.swift:161-199`）。
- 量測（`bench/results/asr-round1-2026-10-16.md`，97 條真實錄音，Claude 當評審 0～5 分）：Qwen3-ASR 0.6B Q8 Metal 4.14 分、p50 231 ms；SenseVoice Q8 3.94 分、p50 73 ms。中英夾雜 Qwen3 明顯好。和 Speakin `eval/2026-11-06-asr-models.md` 的結論一致：0.6B 輸出簡體、錯字比 TEA 多。

## 3. 字典

- 三種收法寫成資料：`prompt`（寫進大模型系統提示）、`context`（雲端 ASR 背景文字）、`hotwords`（ASR 熱詞參數）（`src/vocabulary/support.mjs:3-17`）。大模型提示最多 300 詞／3,000 字（`:56`）。
- 量測（`bench/results/vocabulary-2026-10-19.md`）：127 條錄音（51 條生僻詞、36 條常見詞、40 條反例），90 個詞要認，另記「硬塞」（成品有字典詞、參照沒有）。

  | 模型 | 認對（不帶 → 帶） | 硬塞（不帶 → 帶） |
  |---|---|---|
  | 直出 Gemini 3.6 Flash（提示） | 53 → 85 | 0 → 2 |
  | 潤稿 DeepSeek Flash（提示） | 38 → 74 | 2 → 9 |
  | 本機 Qwen3-ASR 0.6B Q8 Metal（熱詞） | 21 → 49 | 1 → 3 |
  | 本機 SenseVoice（不收） | 16 → 16 | 0 → 0 |

  帶字典幾乎不增加耗時。潤稿模型「多認對」和「多硬塞」此消彼長，是文字潤稿的通病。
- 爬山（`bench/results/vocabulary-hillclimb-2026-10-19.md`）：訓練／測試按錄音切開、分析員碰不到測試集、量尺記指紋不許中途變。三處寫法共 6 輪全部撤回，攔下三個「只看訓練集或只看認對率會留下」的改動。Speakin 的 `eval/prompt-loop/` 已經是同一套做法（train／holdout、`false_changes` 不許變多）。
- 匯入：認 UTF-8／UTF-16 BOM／GB18030，去零寬字元，NFKC＋小寫判重複（`src/vocabulary/terms.mjs:23-41,101-111`）。Speakin 匯入有處理 BOM（`App.swift:298` 的測試），零寬字元**要確認**，價值低。
- **沒有自動學字**。

## 4. 潤稿提示

- 直出（`src/server/tasks/dictate/prompt.mjs:21-104`）與潤稿（`polish-prompt.mjs:15-113`）共用同一套規則：刪口頭禪、刪結巴（含單字結巴「我我覺得」）、改口只留最後、不回答不執行、口語詞照留、阿拉伯數字、中英之間空格、分段空一行、兩項以上用 `1. ` 清單、「主題：內容」。七個長範例。
- 幾個實測結論（`prompt.mjs:1-9` 註解與 `docs/implementation-notes.md`）：
  - 寫成「轉寫引擎」模型會逐字照抄口頭禪，改成「寫出他想打出來的字」才會刪。
  - 精簡成四條原則、不帶範例，分段少了近一半。細則有用。
  - 規則裡加「看看、試試這類疊詞照留」反而讓「看看看看」留得更多（80 次裡 7 → 17）。
  - 要求 JSON 輸出時模型不再處理改口。
  - 換大一號的文字模型（DeepSeek V4 Pro）分段分點沒變好，只變慢。
- Speakin 的規則（`Backends.swift:136-179`）在改口、收回、數字、email、`<前文>`／`<畫面>` 優先序上更細，加上 `plausible` 防護、改口刪句（`Text.swift:5-27`）、長文分塊（`Text.swift:158-180`），SpeakMore 都沒有。

## 5. 貼上與熱鍵

- 貼上：存剪貼簿所有格式 → 寫字＋transient → ⌘V → 0.3 秒還原；貼字和劃詞的模擬 ⌘C 排在同一個佇列，不會互相還原錯（`native/mac/Paste.swift:8-10,68-85`）。Speakin 等 0.6 秒、終端機 1.0 秒，另有連貼兩次的 `pending` 處理（`System.swift:152-196`）。
- 熱鍵預設右 ⌥（Fn 被 Typeless 和系統佔走）；只在修飾鍵按住時才開能吞鍵的 event tap；Esc 和懸浮條按鈕點擊由小幫手攔，避免焦點被搶（`docs/implementation-notes.md` 介面一節）。
- 劃詞取選取：先問 AX（`AXSelectedText`＋`AXBoundsForRange` 拿位置），問不到再模擬 ⌘C（`native/mac/Selection.swift`）。

## 6. 本機模式的模型生命週期

- 設定可選常駐或閒置 1／5／10／30 分鐘釋放；開口時開始載入、說完才等（`docs/implementation-notes.md` PR #14 一節）。Mac 開機後第一次載入 3.5～5 秒，之後 0.4 秒。Speakin 閒置 60 秒釋放、錄音開始就載（`Backends.swift:13-29`），實測第一句只慢 0.1～0.25 秒，不用改。
