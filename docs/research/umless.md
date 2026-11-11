# Umless 程式碼研究

對象：[jatinbishla/Umless](https://github.com/jatinbishla/Umless)，commit `59e0322`（2026-11-08），Apache-2.0，⭐8，約 1.3 萬行 Rust（Mac／Windows／Linux）。
比對：Speakin `0ba0501`。
日期：2026-11-12。只讀程式碼，沒有建置或執行。

> **授權**：Apache-2.0，可以照抄，保留著作權聲明、改過的檔案註明有改。
> Umless 行號以 repo 根目錄為準，Speakin 行號以 `Sources/Speakin/` 為準。
> `ARCHITECTURE.md` 大半是設計稿（KV 快取、prompt-lookup 推測解碼、風格統計、snippet 多數沒做或關掉），下面只採有程式碼、或 `docs/bench/` 有量測的部分。

## 總結

- 單人專案，11/2 建 repo，6 天 73 個 commit。目標是**英文**（含印度英文、Hinglish），本機 Parakeet／Whisper＋本機 Qwen 潤稿，分 Lite／Standard／Max 三級。中文完全沒處理，字典的「子音骨架」比對也只對英文有用。
- 它的量測和 Speakin 自己的結論一致，可以當旁證：
  - **ASR 熱詞沒用**：boost 3/token 幾乎沒差，6 以上 Parakeet 開始憑空吐出熱詞，預設關掉（`docs/benchmarks.md:125`）。Speakin 11/6、11/10 兩次實測也是這樣。
  - **字典才是主要槓桿**：Max 4.2% → 1.5%、Standard 7.2% → 3.6%（`docs/benchmarks.md` 11/3 一節）。辨識模型多半「聽對、拼錯」，事後換字比改解碼有效。
  - **合成資料微調救不了真實語音**：Lite 0.8B 用 4,826 筆合成資料微調，合成測試集 0.4% WER、170/200 全對，真實錄音 6.6% → 6.9%，平手（`docs/bench/2026-11-04-lite-finetune-r1.md`）。第二輪 6.3%，風格改寫反而變差。要動本機 Qwen 的話，不要走合成資料微調。
- 對 Speakin 最有用的是**讀 Chrome 畫面的細節**（#1）：Chromium 不吃 `AXManualAccessibility`，要另外設 `AXEnhancedUserInterface`，而且 Chrome 過一陣子會把輔助樹關掉，要定期重設。Speakin 目前只設前者。
- 其他工程面 Speakin 大多已經有、或做得更細：短句不潤稿、潤稿不合格退回、改口刪句、學字（Speakin 的結算時機比它的 10／30／90 秒細）、終端機用送出紀錄學字、遮個資。

## 借鏡清單

標 ✅ 的已對過 Speakin 原始碼。價值以「對 Speakin 現在的使用者」計。

| # | 項目 | 來源 | Speakin 現況 | 做法 | 價值 | 成本 |
|---|---|---|---|---|---|---|
| 1 ✅ | Chrome 系瀏覽器要設 `AXEnhancedUserInterface` 才讀得到網頁 | `crates/umless-context/src/lib.rs:325-376`：先設 `AXManualAccessibility`，失敗且 bundle id 是 Chrome／Edge／Brave／Arc／Vivaldi／Opera 才設 `AXEnhancedUserInterface`（只限 Chromium，AppKit App 設了會拖慢視窗動畫）；第一次要求後等 2.5 秒樹才建好；Chrome 沒有輔助 App 一陣子會自己關掉，每 30 秒重設一次 | 學字和前文只設 `AXManualAccessibility`、每個 pid 一次（`System.swift:359`）；讀整個視窗每次都設，同樣沒有 Enhanced（`System.swift:283`）。Chrome 裡的 Gmail、Notion 網頁讀不讀得到：**要確認**（同 speakmore.md #4） | 先在 Chrome 開 Gmail，看 `Learner.value` 和 `ScreenContext.window` 是不是空的。空的就照它的條件補：Chromium 才設 Enhanced、30 秒重設、記住 pid 改成記時間 | 中～高（讀不到的話，網頁上的前文、畫面、學字全瞎） | 測 10 分鐘；補做 ~15 行 |
| 2 ✅ | 用視窗標題分辨瀏覽器分頁是哪個網頁 App | `lib.rs:186-206`、`:312-322`：讀 `AXFocusedWindow` 的 `AXTitle`，標題含 "gmail"／"outlook" 算郵件、"chatgpt"／"claude"／"gemini" 算 AI 對話 | `<情境>` 只看 App 名稱分類（`Zone.of(app)`，`Backends.swift:289`），Chrome 裡寫 Gmail 和寫 Slack 是同一類 | 比 speakmore.md #3 的「往上找網址」簡單：不用猜屬性名、不用走樹。瀏覽器時把視窗標題前 40 字也送進 `<情境>`，讓 Haiku 自己判斷是郵件還是聊天 | 中 | ~10 行 |
| 3 | 潤稿防護：改口只放寬「改口詞前 8 個詞」 | `crates/umless-cleanup/src/guard.rs:24-45,91-156`：改口詞（no wait、actually、make that…）前 8 個詞可以消失；其他地方的內容詞最多掉 1 個，否則退回 | 原文有改口詞時，**整段**放寬到可刪 6 成或 20 字（`Text.swift:183-185`）。講一句「算了」，同一段後面整句被吃掉也會過 | 改成：改口詞前 N 個字可以刪，其他位置照原本 4 成／8 字。中文用字數算，N 先抓 15 字，拿 `eval/` 的改口案例調。屬於 landscape README #1 的一部分 | 中 | ~15 行＋eval |
| 4 | 潤稿結果有 ``` 或 ** 就當成「在回答」 | `guard.rs:237`：改寫結果出現 ``` 或 `**` 直接判失敗 | `plausible` 只看 LCS 比例（`Text.swift:169-186`），Haiku 回一段帶粗體的答案，只要用了夠多原文的字就會過 | `plausible` 開頭加一行：原文沒有 ``` 和 `**`、結果有，就回 false | 低～中 | 1 行 |
| 5 | 數字、人名不能憑空出現或消失 | `guard.rs:172-258`（`check_rewrite`）：結果裡的數字和非句首大寫詞，原文要講過（「$12,400」對得到「twelve thousand four hundred」）；原文的人名不能不見 | 數字整串當一個字比 LCS（`Text.swift:174`），值變了也看不出來 | 同 landscape README #1，不重複列。它的「國字數字和阿拉伯數字視為同一個」可以參考 `guard.rs:366-420` 的 `mentions`、`spoken_digits` | （併入 landscape #1） | — |
| 6 | 讀視窗時略過選單列、選單、工具列、捲軸 | `lib.rs:484-487`：這四種 role 整棵跳過；`AXWebArea` 裡的字另外收，跟瀏覽器外框分開 | 每個元素都讀 Value／Title／Description（`System.swift:293`），選單和工具列的字都進 `<畫面>` | 遇到 `AXMenuBar`、`AXMenu`、`AXToolbar`、`AXScrollBar` 就不往下走。先抓一次 Chrome、Slack 的 `<畫面>` 看雜訊多不多再決定 | 低～中 | ~3 行 |
| 7 | 終端機、AI App 改寫成精簡的 prompt | `crates/umless-cleanup/src/lib.rs:46,167-175`：講給 AI 聽的話改寫成指令，保留每個要求、數字、路徑、識別字，多件事排清單，不回答、不寫程式。另一條值得抄的：「使用者說他會提供的東西（『我等下貼 log』）要保持是他的陳述，不能變成叫 AI 做」 | 沒有這個模式；終端機和一般 App 走同一套規則 | 先不做整套模式（它自己的 0.8B 做不好，Speakin 的使用者也不一定想被改寫）。最後那條「誰做什麼不能對調」可以當 prompt-loop 的一個候選規則跑看看 | 低（模式）／低～中（那條規則） | eval |
| 8 | 辨識把贅字聽成真的字 | 它的 prompt 寫明「uh 常被聽成 I'll／all，um 常被聽成 I'm，當贅字刪」（`docs/benchmarks.md` 11/6 一節），guard 也把這幾個字當可以消失（`guard.rs:20-22`） | 規則只列「呃、嗯、那個、就是說、喔對」（`Backends.swift:142`） | 先查歷史紀錄：TEA 會不會把「呃」「嗯」寫成「餓」「恩」「啊」之類的字。有的話補進贅字那一行 | 待資料 | 查 10 分鐘 |

## 實測結果（2026-11-12，branch `umless-borrow`）

用本機紀錄回放（`logs/*/log.txt`、`logs/*/screen.txt`、`data.sqlite`），沒有重新錄音。

| # | 結果 | 決定 |
|---|---|---|
| 1 | Chrome 的輸入框前文 32 次讀到 28 次；`screen.txt` 裡 Google Chat、Notion 的網頁內容都有讀到。前提不成立 | 不做 |
| 2 | `<畫面>` 已經看得出是聊天還是文件，標題能多給的資訊有限 | 不做 |
| 3 | 590 次潤稿有 31 次原文帶改口詞；改成「只放寬改口詞前 15 字（或 25 字）」，判斷一次都沒翻轉：不會誤擋，但也沒擋到任何東西 | 不做 |
| 4 | 680 筆歷史結果沒有一筆含 ``` 或 `**` | 不做 |
| 6 | 回放時發現更大的問題：`<畫面>` 同一句話重複 3～4 次（外層的說明已經包含每一格的字，Title 和 Description 又常常一樣）。736 份去重後字數剩 67% | **做了**：`ScreenContext.add`（`System.swift`），跟上一筆重疊或最近 8 筆出現過就不收；selftest 加一條。略過選單、工具列沒做：Notion 那些重複是網頁裡的元素，role 不是 `AXMenu`，擋不到 |

還沒驗證：去重後潤稿有沒有變好（要拿真實錄音跑一輪 eval）、現場讀視窗的結果（測試時螢幕鎖定，`--axwindow` 讀不到）。

## 不用學的

| 項目 | 原因 |
|---|---|
| 字典的音近比對（子音骨架＋編輯距離 34%） | 只對英文拼字有用；Speakin 用「常被聽成」精確對應＋交給 Haiku 判斷，中文不適用 |
| 字典在潤稿前後各套一次 | Speakin 已把字典送進潤稿（`<字典>`），潤稿後再套沒看到需求 |
| 學字只收「字典會把舊字對到新字」的替換 | 這是為了配合它的音近比對；Speakin 學到的是「常被聽成」，本來就是精確對應 |
| 學字在 10／30／90 秒和下次口述前讀回 | Speakin 的結算時機更細：Enter、停手 3 秒、換輸入框、5 秒沒動、15 秒（`System.swift:376-404`），加上終端機的送出紀錄 |
| 貼上後 250 ms 還原剪貼簿 | 比 Speakin 的 0.6 秒更短、風險更高；正解是 landscape README #2 的「等對方讀走」 |
| 短句跳過潤稿（≤ 6 個詞、沒有贅字和改口詞） | Speakin 已有（不到 10 個字，`Engine.swift:327`） |
| 本機 LLM 的 KV 快取、prompt-lookup 推測解碼 | Speakin 走 `claude -p` Haiku，用不到。它自己也寫了 Qwen3.5 是混合架構，推測解碼關著 |
| Command 模式（選字＋語音指令改寫） | 同 speakmore.md #12，先不做 |
