# 第 6 組：Windows、Linux、自架專案

調查日期 2026-11-07。只讀程式碼，沒有執行或安裝任何東西。commit 數是 2026-09-07 之後。

先講 Speakin 現況，免得重複建議：Speakin 已經有「Codex 常駐 app-server（JSON-RPC）」、`Text.plausible()`（LCS 比對潤稿輸出）、改口／收回處理（`dropRetracted`）、長文分塊潤稿、自適應 VAD 門檻（背景音 × 1.6）、字典 hotword、Learner。下面「對 Speakin 有幫助」只列它還沒有或可以做得更好的。

---

## 1. bobjoemama/LocalScribe（最值得看，Mac 專案）
1. 基本：⭐2｜TypeScript（Electron）＋ Python worker ＋ Swift 原生輔助程式｜macOS 14+ Apple Silicon｜Apache-2.0｜近 2 個月 26 commit，單人（有 AI 協作痕跡）｜活躍，已有簽章公證的 dmg（v0.1.0-dev.25）。
2. 功能：Control 長按／Control+Space 切換；ASR 有 Parakeet Unified 0.6B（FluidAudio Core ML）、Canary-Qwen 2.5B、Qwen3-ASR（MLX）、Moonshine、Phonon，**Canary 是用 transcribe.cpp 的 GGUF（BF16/Q8/Q4）**，跟 Speakin 同一個推論引擎；沒有 LLM 潤稿，改用「確定性清理」＋字典＋Snippets；有歷史、筆記、Scratchpad、App 內更新（要使用者同意、閒置才裝）。
3. 架構：Electron 主程式 ＋ Python worker（ctypes 載入 transcribe.cpp dylib，模型常駐、每塊解碼後釋放 session）＋ `active-target.swift`（取得焦點視窗／控制項指紋）。模型有 manifest（位元組數＋SHA-256）、原子安裝、下載後要手動「套用」才載入。`docs/MODEL_COMPARISON_EVIDENCE.md` 有 Mac 上各模型 WER／速度比較（Qwen3-ASR 1.7B 在 7 個資料集平均 WER 最低 5.75%，Canary-Qwen 6.37%）。
4. 對 Speakin 有幫助：
   - **[高] 貼上前後比對「目標身分」**（`src/main/insertion/safeInsertion.ts`）：錄音開始時記下 App／視窗指紋／焦點控制項指紋，貼上前再比對，不一樣就不自動貼、改成只複製（回報 `copied` 而不是亂貼到別的視窗）。另外檢查剪貼簿 changeCount 是否剛好 +1 來確認貼上有被吃掉（`clipboardAdvancedExactlyOnce`），貼完才還原原本剪貼簿，剪貼簿快照期間被別人改過就不還原。Speakin 的 Paster 可以補「換了視窗就不貼」這一層，使用者錄音時切 App 的場景很常見。
   - **[高] 字典 ASR hint 的長度預算與優先序**（`src/shared/dictionaryContext.ts`）：新加的詞優先、放不下就跳過、最高優先的放在字串尾端（Qwen 對尾端更敏感）。Speakin 目前取「權重最高 20 個」，可以參考「依字元數預算＋尾端放最重要」。
   - **[中] 確定性清理分 preset 與 per-app profile**（`src/shared/text/profiles.ts`、`fillers.ts`）：balanced／message／document／verbatim，贅字分 conservative／aggressive，保護全大寫縮寫不被當贅字刪。可作為潤稿關閉或失敗時的「不靠 LLM」退路。
   - **[中] 模型下載流程**：manifest＋SHA-256＋原子安裝＋「下載不等於啟用」，對應 Speakin 的模型下載與記憶體痛點。
   - **[中] 模型評比文件**可直接當選型參考：transcribe.cpp 維護者在 M4 Max 上 35 秒音檔，Qwen 1.7B Q8 約 959 ms、Cohere 470 ms、Granite 5 約 86 ms（見 `docs/MODEL_COMPARISON_EVIDENCE.md`）。Speakin 若想在延遲上再降，Cohere Transcribe 2B 值得測，但它有靜音幻聽與中英夾雜限制。
   - **[低] 設定有交易式寫入、診斷檔不含聽寫內容**（Copy diagnostics），可參考。

## 2. mariadb-RupeshBiswas/local-stt
1. 基本：⭐2｜Rust（Tauri）＋ whisper.cpp｜macOS（M1+）、Windows｜MIT｜55 commit，單人為主｜很活躍，已上 PyPI（`uvx local-stt`）。
2. 功能：Fn+Shift 長按、Fn+Shift+Space 免持、Esc 取消；Whisper Small 181 MB 預設；**即時預覽**；Smart formatting（口述「第一、第二」變編號清單）；會議筆記（偵測 Zoom／Meet／Teams，分辨講者並從通話 App 取名，本機 LLM 做摘要）；歷史、洞察統計；沒有雲端 LLM 潤稿。
3. 架構：Rust 直接用 C shim 呼叫 whisper.cpp 與本機 llama；切段器 `src/notes/segmenter.rs`（30 ms 一格、RMS 門檻 0.01、停頓 20 格＝600 ms 切、最長 833 格、pre-roll 10 格保住字首、短於 10 格的咳嗽聲丟掉）；`engine.rs` 有 `abort_previews`。
4. 對 Speakin 有幫助：
   - **[高] 即時預覽只重辨「最近 18 秒尾巴」每 800 ms 一次，且放開按鍵時用 abort flag 中止預覽**（`src/app.rs` 的 `LIVE_TAIL_SECS`、`LIVE_EVERY_MS`；`engine.rs` `abort_previews`/`transcribe_preview`）。成本不隨錄音變長；最終辨識不會被預覽卡住。Speakin 若要做「邊講邊看字」可以用這個模式（Speakin 目前是切段辨識，沒有預覽浮窗）。
   - **[中] 口述清單轉編號**（`src/format.rs` `numbered_points`）：只在英文輸出套用規則，其他語言只修空白，避免誤傷。Speakin 已經讓 LLM 排版，但潤稿關閉時可用。
   - **[中] 小 LLM 用 GBNF grammar 限制輸出格式**（`engine.rs` `generate(prompt, grammar, root, …)`）：Speakin 的本機潤稿（qwen via llama-server）可以考慮用 grammar 或 JSON schema 擋掉「開始回答問題」的失敗模式。
   - **[低] 硬體偵測挑模型**（`src/hwprobe`、`models.rs::evaluate`：RAM／磁碟不明時只允許最小模型）。

## 3. nexos-1/localflow
1. 基本：⭐8｜Python｜Windows 為主，macOS 實驗（mlx-whisper、AppKit overlay）｜MIT｜33 commit，單人｜近一個月較少更新（最後 push 2026-10-08）。
2. 功能：按住熱鍵；faster-whisper（Win）／mlx-whisper（Mac）；潤稿用 llama.cpp 自己的 llama-server 或 Ollama（gemma3:4b）；字典＋Snippets；語音指令（句尾「press enter」→ 按 Enter）；播放中系統音訊自動靜音（ducking）；即時預覽。
3. 架構：`pipeline.py` 順序＝ASR →（句尾語音指令）→ 潤稿 → **字典替換** → 輸出；`cleanup.py`、`stt_quality.py`、`commands.py`、`ducking.py`。
4. 對 Speakin 有幫助：
   - **[高] 字典替換放在 LLM 潤稿之後**（`pipeline.py` `process`）：小模型不會把使用者指定的寫法改回去。Speakin 目前是先字典、再把字典放進潤稿 prompt（靠 LLM 遵守）；可以在潤稿後再跑一次確定性字典，當保險。
   - **[高] 語音指令在「原始逐字稿」的句尾偵測，且在 LLM 之前剝掉**（`commands.py`）：「press enter」被 Whisper 聽成「presenter」所以內建別名。Speakin 有 Text.swift 的指令處理，可檢查是否也在潤稿前處理、有沒有加常見誤聽別名（中文如「按 enter」「按確認」）。
   - **[中] Whisper 幻聽過濾**（`stt_quality.py`）：只有「文字命中已知靜音幻聽詞」且「logprob／no_speech 機率差」才丟掉；以及 **prompt echo 過濾**（輸出只由 hint 詞組成且信心低就丟）。Speakin 的 hotword 塞進 ASR prompt，短音檔或靜音時可能把 hotword 整串吐出來，值得加類似檢查（Speakin 已在 Store.swift 註明「提示太長辨識會照抄詞」）。
   - **[中] `cleanup_min_words`：太短的話不送潤稿**（省延遲）；`_plausible` 長度比 0.4～1.8 當保險（Speakin 已有更嚴格的 LCS 版）。
   - **[中] 錄音時系統音量快速淡出靜音並有崩潰復原**（`ducking.py`，Windows COM；Mac 要用 CoreAudio 重寫）。Speakin 有 `unmute()`，看起來已有類似功能。
   - **[低] 潤稿伺服器閒置卸載模型**（llama-server `--sleep-idle-seconds`），跟 Speakin 本機模型 1 分鐘閒置放掉同思路。
   - 提示：few-shot 與「文字常是問 AI 的問題，不要回答」的規則，跟 Speakin 的 rule 一致，無新東西。

## 4. GrimFandango42/VoiceFlow
1. 基本：⭐3｜Python｜Windows｜MIT｜26 commit，單人｜活躍。
2. 功能：Ctrl+Shift 長按；faster-whisper（Distil-Whisper、GPU）；即時預覽；程式碼模式（口述 open paren 等符號）；依目的視窗分 profile（terminal／chat／editor／document）調整排版與換行；**Command Mode**（「make this more formal」改寫選取文字）；**每日學習工作**。
3. 架構：`core/textproc.py`（約 1600 行規則：清單、段落、技術詞表、同音詞消歧）；`ai/adaptive_memory.py`（學習）；`ai/daily_learning.py`（每天分析）；環形緩衝錄音 `BoundedRingBuffer`。
4. 對 Speakin 有幫助：
   - **[高] 學習機制設計**（`ai/adaptive_memory.py`）：
     - 用 `difflib.SequenceMatcher` 對 raw vs 使用者最終文字，只取 `replace` 區塊，每側最多 4 個 token；
     - **「replace 區塊後面接的 equal 區塊如果有大小寫或詞形改變，就把它併進去當成片語」**（`_has_phrase_context_signal`）；
     - 過濾：純大小寫差異、單複數／所有格差異、全是停用詞；
     - **有分數門檻**：一般來源要累積 `min_count` 次才生效，**使用者親手修正的來源門檻較低**（`user_correction_min_count`）；
     - **有保存期限**（`_is_fresh`、`_purge_expired`），久沒再出現就失效；
     - 套用時長片語優先，並保留原字的大小寫（`_match_case`）。
     Speakin 的 Learner 目前讀回欄位後比對，可以補「次數門檻＋來源加權＋過期」，減少一次性改寫污染字典。
   - **[中] 每日離線分析 + 使用者審核佇列**（`daily_learning.py`、`ai/review.py`）：用 LLM 把當天修正整理成「建議替換詞、要保護的詞、停用詞」，**預設關閉，要使用者同意才送資料**，結果進審核佇列不直接寫入。可跟 Speakin 的「智慧建議」對照。
   - **[中] 依目的視窗類型調整輸出**（`infer_destination_profile`）：Speakin 已有 App 情境給潤稿，這是同樣的概念，無新增。
   - **[低] Command Mode（對選取文字下口述指令）**：Speakin 沒有，可列為產品方向，但範圍較大。

## 5. Breakzoras/fuck-you-flow（FU Flow）
1. 基本：⭐3｜Rust（Tauri）＋ React｜Windows、Ubuntu｜MIT（Luram AI Agency，希臘）｜9 commit，公司單人專案｜活躍。
2. 功能：whisper-server 常駐子行程（whisper.cpp）；希臘文與英文為主；確定性清理（贅字、自我修正「Tuesday, no, Friday」、重複詞、標點、大小寫）＋字典＋Snippets；可選 AI 潤稿（本機 llama.cpp 或雲端）；**事後比對防呆**；建議式學習；錯誤重試用的「復原錄音」。
3. 架構：`pipeline.rs` 狀態機（每步有 timeout／取消）；邊錄邊切段並行辨識；`cleanup/{deterministic,dictionary,divergence,questions,snippets}.rs`；`learning.rs`；`journal.rs`（只記事件種類、數量、時間，不記逐字稿）。
4. 對 Speakin 有幫助：
   - **[高] 潤稿輸出防呆比 `plausible` 更細**（`cleanup/divergence.rs`）：
     - **數字、網址、email 必須原樣保留**（Speakin 目前只把數字當一團，國字轉阿拉伯數字還是會過；可再加「數值集合不變」的檢查，因為 prompt 說「值絕對不能變」但沒有程式驗證）；
     - 主要文字系統（script）不能翻轉（防止被翻譯成另一種語言；Speakin 對中英夾雜，可改成「中文字佔比不能掉太多」）；
     - 新詞比例 > 35% 且超過 6 詞就拒絕（防止憑空加內容）；
     - 輸出長度 > 1.6 倍原文拒絕。
   - **[高] 切段策略**（`pipeline.rs` 約 410–450 行）：每 250 ms 檢查，停頓夠長且靜音就**切在停頓中間**（前段留一點尾音、後段留一點頭音）；**長時間沒停頓時，在最近 3 秒內找「最安靜的 200 ms」切**，剛好落在字與字之間。Speakin 的 Segmenter 在 maxLen 25 秒是硬切（`cut = scanned`），可改成回頭找最安靜點，減少切到字中間造成的錯字。
   - **[中] 錄音復原**：貼上成功前保留一份 wav（`recovery/last.wav`），失敗可「重試」；成功才刪。Speakin 有歷史紀錄，但未必有音檔重試。
   - **[中] 字典規則支援「例外上下文」**（`cleanup/dictionary.rs` `exceptions`）：使用者說「這裡不要換」的那段前後文，之後不再替換。可降低 Speakin 字典誤替換（例如字典詞剛好是常見詞）。
   - **[中] 學習只學「1–3 個詞的明確替換」**（`learning.rs` `classify`）：分成 WordCorrection／StyleOnly／Rewrite／Deletion，改寫與刪除一律不學、只有標點大小寫變動記為 style。邏輯簡單可直接搬。
   - **[低] 剪貼簿 delayed-render 貼上**（Windows 專用 `WM_RENDERFORMAT`，不能搬）；Mac 對應概念是 NSPasteboard promise，可是風險高，不建議。
   - **[低] 純規則問句判斷**（`cleanup/questions.rs`）：ASR 聽不到語調，所以靠疑問詞判斷加問號；中文「嗎、呢、什麼」可類比，但 Speakin 由 LLM 處理，優先度低。

## 6. CocaKova/orpheus
1. 基本：⭐5｜Kotlin（Android）＋ Python（伺服器、桌面）｜Android、Windows、Linux 客戶端，伺服器需 NVIDIA GPU｜MIT｜7 commit，單人｜活躍度一般。
2. 功能：自架 OpenAI 相容 `/v1/audio/transcriptions`，Parakeet TDT 0.6B v2；確定性預處理 → LLM 潤稿 → 守門 → 補回句尾標點 → 條列 → 依游標前後文調整；Android 懸浮球讀欄位前後文；每 App 風格。
3. 架構：`server/formatting.py` 一個檔案做完整管線（註解寫得很清楚）。
4. 對 Speakin 有幫助：
   - **[高] 內容保留守門的三種失敗型態**（`guard()`）：缺字過多（>15% 且至少 3 個）、**最後一個內容詞被吃掉（結尾被刪）**、**第一個內容詞被吃掉（開頭被刪）**。註解說結尾被刪是聊天模型「整理」最常見的錯誤。Speakin 的 LCS 比對允許最多刪 4 成，可能漏掉「只少最後一句」的情況，加首尾檢查成本很低。
   - **[高] 游標前後文進 prompt 的規則**（`request_hints`、`fit_context`）：給 LLM 看游標前文（最後 N 字）與後文前 80 字，**若游標在句中（前文沒以句號結尾），要求用小寫起頭**（除非專名、I、縮寫），並在 LLM 後再用確定性程式補一次。對 Speakin 的 ScreenContext 是直接可借的細節（英文部分，中文則是「句中不加句號、不起新段」）。
   - **[中] `restore_terminal`**：LLM 把句尾標點或句尾詞吃掉時補回；以及**聊天風格只有一句時去掉句號、程式碼風格去句號**，用程式做而非靠 prompt。
   - **[中] 口述符號預處理只處理「無歧義」的詞**（`prepass`）：「new line、open paren、exclamation point」直接轉；「period、comma、dot、dash」只在前後有停頓／大寫等條件才轉，其餘交給 LLM 看上下文。對應 Speakin 的「口述 email 照講順序」問題，可作為規則切分的參考。
   - **[低] 條列的三層做法**（口述標記 → LLM → 確定性 `listify` 兜底：「I need A, B, C」）。

## 7. NathanNT/llm-mascot
1. 基本：⭐4｜Python（Tkinter）｜Windows｜MIT｜16 commit，單人｜桌面吉祥物＋用量顯示，聽寫只是其中一塊。
2. 功能：faster-whisper 本機轉寫（法／英）；**用 Codex 或 Claude 訂閱做改寫**；8 種風格（修正、校對、精簡、詳細、coding task、條列、專業、口語）＋自訂；插入用鍵入（SendInput）不用剪貼簿、不按 Enter；最近 5 次聽寫（30 分鐘內）當改寫上下文。
3. 架構：`core.py`（`rewrite_with_claude`：`claude -p --tools "" --no-session-persistence --output-format text`，在 temp 目錄執行避免載入專案設定）、`codex_server.py`（常駐 `codex app-server`）。
4. 對 Speakin 有幫助：
   - **[中] Codex app-server 做法與 Speakin 相同**（`exec` 約 9 秒 → app-server 每次 0.2 秒開新暫時對話）。Speakin 已實作，**無新增**；可對照確認：`thread/start` 帶 `ephemeral: true`、`sandbox: read-only`、`approvalPolicy: never`、`baseInstructions`，`thread/unsubscribe` 收尾，常駐失敗時退回 `codex exec`（Speakin 是否有這個退路可檢查）。
   - **[中] 最近幾次聽寫當上下文**（`dictation_context.py`：最多 5 筆、30 分鐘內、每筆 700 字內，只存記憶體）：解決「它、那個檔案」的指代。Speakin 有畫面文字和前文，但跨次錄音的指代可以用這個補，成本低。要注意 Speakin 現在是「每次錄音開新對話免得 Haiku 抄前幾次」，所以放進 prompt 的標籤要明確標示「僅供理解指代，不輸出」。
   - **[中] 風格 preset 的 prompt 設計**（`styles.py`）：「coding task」風格（目標一句、Where／Current vs expected／Constraints／Done when，不發明檔名）對寫程式的使用者很實用，可當 Speakin 的一個潤稿模式（Speakin 目前有「理順句子」模式）。
   - **[低] 專有詞 prompt 的量測**（`vocab.py`）：法文夾英文術語，用「含術語的一句話」當 Whisper prompt，錯誤率 3.2%→0%（large-v3）、21%→4.8%（medium）；hint 只有前約 520 字元有效，使用者詞放前面。支持 Speakin 用 hotword 的方向，並提示「放句子比放詞條更有效」可以實測（對 Qwen ASR prompt 不一定成立）。

## 8. better-slop/hyprwhspr-rs
1. 基本：⭐36｜Rust｜Linux（Hyprland／Omarchy）｜MIT｜4 commit（近期較少）｜單人。
2. 功能：whisper.cpp、Groq、Gemini、Parakeet TDT（ONNX）、Codex 帳號（custom.openai-codex）、任何 OpenAI 相容端點；**Fast VAD 修剪音訊**；**文字管線 11 步**（含 ITN 反向文字正規化、控制指令「newline／tab／open parenthesis」）；word overrides；熱重載設定。
3. 架構：`audio/vad.rs`（earshot VAD，30 ms 一格；**依近期判定的波動度動態在 4 個積極程度間切換**；pre-roll／post-roll；靜音逾時才結束一段；段長不足丟棄）；`text/normalize.rs`；`tests/tip/*`（固定音檔＋黃金文字、WER 類正確率、各階段 CPU／RSS 計時、diff 報告）。
4. 對 Speakin 有幫助：
   - **[中] 把「辨識前修剪靜音」當成降延遲手段**：先 VAD 去掉段內長靜音再送 ASR，減少推論時間（`audio/vad.rs` `trim`）。Speakin 已切段，段內長靜音仍可修剪；但要避免剪掉字首（所以才要 pre-roll）。
   - **[中] 固定音檔＋黃金文字的回歸測試與分階段計時**（`tests/tip/README.md`）：特別有一點值得抄——**測試時關掉使用者字典**，因為字典會掩蓋文字管線的 bug。Speakin 的 `--polish ... --rule` 測試入口已經類似，可補一組「固定音檔 → 預期文字」的回歸。
   - **[低] ITN 用 FluidInference/text-processing-rs（Rust 版 NeMo ITN）**：可處理英文數字、日期、符號；對中文無用，Speakin 的數字規則在 prompt 裡，不需要。

## 9. blakkd/faster-whisper-hotkey
1. 基本：⭐31｜Python｜Linux／Windows／macOS（終端機選單）｜WTFPL｜54 commit，單人｜活躍。
2. 功能：按住熱鍵；可選模型很多（parakeet-ultra、faster-whisper、Granite Speech 4.1／5.0、Cohere Transcribe、Qwen3-ASR 1.7B-hf、Canary 1B v2、Voxtral）；**可選 LLM 校正**（任何 OpenAI 相容端點）；`capitalization.py`（針對全小寫模型補首字大寫）。
3. 架構：README 內有 CPU 上 40 秒音檔各模型速度表（parakeet-ultra 2.6 秒、Qwen3-ASR 1.7B 48 秒）；`test_audio_data/transcription_results.md` 有各模型輸出比較。
4. 對 Speakin 有幫助：
   - **[低] LLM 校正 prompt 的「保真」寫法**（`llm_corrector.py`）：含一句「若原文已正確就原樣回傳」，外加 `chat_template_kwargs: enable_thinking=false` 關閉思考模式。若 Speakin 本機潤稿模型是會思考的 Qwen3 系列，這個參數可確認是否已設。
   - **[低] API key 可用 `env:VAR` 參照**，不落設定檔（Speakin 不存金鑰，無需要）。
   - 其餘為 Linux 貼上（wtype／X11 Ctrl+Shift+V 判斷終端機），平台專屬略過。

## 10. LuiInventions/OpenFlow
1. 基本：⭐17｜Electron（JS）＋ PowerShell 輔助｜Windows｜GPL-3.0｜63 commit，單人，更新頻繁（有 AI 協作痕跡）。
2. 功能：Ctrl+Win 長按；內建 Parakeet v3；浮動氣泡；**三種聽寫模式（原文／潤稿／壓縮）**；筆記與 AI 改善；螢幕截圖 dock；自訂腳本指令。潤稿只走 API（需 key）。
3. 架構：潤稿 prompt 公開在 `docs/dictation-polish-system-prompt.txt`、`dictation-compact-system-prompt.txt`；輸出必須是 `{"text": "..."}` JSON；長文 6,000 字一塊、2 個並行請求；**token 先記帳再驗輸出**。
4. 對 Speakin 有幫助：
   - **[中] 要求模型回 JSON 單一欄位並嚴格驗證**（只允許剛好一個字串欄位 `text`），非 JSON 或有多餘欄位就視為失敗退回原文；另外本機檢查「數字、網址、email、否定詞、不確定詞（可能、好像）、程式碼」是否保留。**否定詞與不確定語氣詞保留**是 Speakin 的 plausible 沒有顯式檢查的（中文可檢查「不、沒、別、可能、應該、好像」的出現數是否不變）。
   - **[低] 「壓縮」模式**（把口述縮成精簡要點）：可當 Speakin 一個額外模式，優先度低。GPL-3.0，不能抄程式碼，只能參考想法。

---

## 整組可借鏡 5 點（依價值排序）
1. **貼上前確認目標沒換**：錄音開始記視窗／控制項指紋，貼上前比對，不一致就只複製不貼；用剪貼簿 changeCount 確認貼上被吃掉（LocalScribe）。
2. **潤稿輸出再加三道程式檢查**：首尾內容詞不能被吃、數字／網址／email 與否定詞必須原樣、新詞比例與長度比上限（orpheus `guard`、fuck-you-flow `divergence`、OpenFlow）。
3. **切段：長時間沒停頓時回頭找最安靜的 200 ms 切，不要硬切；停頓則切在中間**（fuck-you-flow、local-stt）；即時預覽只重辨最近 18 秒尾巴、放開鍵時中止預覽（local-stt）。
4. **Learner 加門檻與過期**：只學 1–4 詞的 replace 區塊、併入有改變的相鄰詞成片語、使用者自己改的來源門檻較低、次數不足不生效、久未再現就失效、改寫與刪除不學（VoiceFlow、fuck-you-flow）。
5. **字典在 LLM 潤稿後再跑一次確定性替換**，字典規則可帶「例外上下文」；ASR hint 用字元預算、最重要的詞放尾端（localflow、fuck-you-flow、LocalScribe）。

另外值得記一筆：LocalScribe 的模型評比文件（Qwen3-ASR 1.7B 平均 WER 最佳；Cohere Transcribe 2B 速度約 Qwen 的 2 倍但有靜音幻聽與中英夾雜限制）與跨次聽寫上下文（llm-mascot）。

## 沒有實質借鏡的
- 本組其餘平台專屬內容（Windows COM ducking、Win32 delayed-render 貼上、Wayland wtype、Android 無障礙服務、Hyprland）略過。

## 授權提醒
OpenFlow 是 GPL-3.0，只能參考想法。其餘為 MIT／Apache-2.0／WTFPL，可參考實作但仍建議自己重寫。
