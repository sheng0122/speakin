# 第 7 組：Windows／Linux／其他平台小專案（18 個 repo）

快速掃過，只看可搬到 Mac 的管線、潤稿、VAD、學習機制。所有 repo 都是 0–3 顆星的小專案，以下只列星數有出入者。clone 在 `$CLAUDE_JOB_DIR/tmp/repos/OWNER__REPO`，只讀沒執行。

## 整組最值得借鏡的 5 點
1. **潤稿結果的防呆檢查**（andrew99666/whisper-dictate、99Arrzel/voice-dictate、flowlite、whisper-ptt）：LLM 改太多就退回原文。Speakin 的 Backends.swift 目前沒有這類檢查，價值高。
2. **Claude CLI 呼叫的細節**（99Arrzel/voice-dictate、bensvoice-windows）：`--safe-mode`、`--effort`、`--output-format json`，加上 system prompt 放檔案。
3. **邊講邊跑的 LLM**（HayGrouve/dictum）：每次停頓就把目前全文丟去潤稿，放開按鍵時結果往往已在路上。有 generation 序號可以取消作廢的預測，也有逾時就貼原文的退路。
4. **依游標前後文調整插入格式**（Moggeth/push-to-talk-realtime）：讀游標前後各 256 字，句中自動把開頭字母降成小寫、補空格、去掉句尾句號。
5. **終端機貼上保護與辨識幻覺過濾**（kagangungor/TRWhisper）：貼到終端機時把換行壓成單行，避免看不見就直接執行；另外有 Whisper 幻覺句黑名單。

## 概況表
| repo | ⭐／授權 | 技術 | 近 2 個月 commit | 活躍度 | 對 Speakin 價值 |
|---|---|---|---|---|---|
| HayGrouve/dictum | 0／MIT | Rust、Parakeet TDT ONNX、Win＋Mac | 38 | 單人活躍 | 高 |
| andrew99666/whisper-dictate | 1／自訂（非商用） | Python、Groq | 4 | 單人 | 高 |
| 99Arrzel/voice-dictate | 0／MIT | Python、Whisper＋claude -p／Ollama、Linux | 1 | 單人，剛發 | 高 |
| Moggeth/push-to-talk-realtime | 0／無 | Python、OpenAI、Windows | 43 | 單人活躍 | 中高 |
| kagangungor/TRWhisper | 3／MIT | C#、whisper.cpp＋Silero VAD | 23 | 單人活躍 | 中 |
| pistonpunk/silisten | 2／MIT | Python、sherpa-onnx、Linux | 47 | 單人活躍 | 中低 |
| Akilaydin/OriApps.SayForge | 0／AGPL | Tauri、React、雲端 ASR | 100+ | 單人活躍（主要一位作者） | 中低 |
| nathannncurtis/whisper-ptt | 0／GPL | Python＋AHK、OpenVINO NPU | 1 | 單人 | 低 |
| powell-clark/voice-to-text | 0／Apache | Rust、whisper.cpp＋Parakeet、Metal | 34 | 單人，CI 很重 | 低 |
| benlaval23/bensvoice-windows | 0／MIT | Python、Parakeet＋Claude | 4 | 單人 | 中低 |
| rvboris/charon | 0／MIT | Tauri、Rust、Linux | 17 | 單人 | 低 |
| DustinHyle/whytype | 0／無 | Python、whisper.cpp、跨平台含 Mac | 11 | 單人 | 低 |
| itsprocess/VoiceHook | 0／無 | C#、webhook | 9 | 單人 | 無 |
| gutsmcd-cmd/onsei-nyuryoku | 0／MIT | TS、PWA、transformers.js Whisper base | 8 | 單人 | 低（日文規則） |
| Komiljon006/uzbek-dictation | 0／其他 | Swift＋whisper.cpp C bridge、Mac | 3 | 單人 | 低 |
| erikchristi/open-whisper | 2／Apache | Python、Parakeet v3、Windows | 2 | 單人 | 低 |
| atheerium/voxtype（現名 libretype） | 3／MIT | Rust、Groq Whisper、Linux | 3 | 單人，程式由 AI agent 提交 | 無 |
| Yuvansh-Shah/flowlite | 0／無 | Python、faster-whisper＋Ollama gemma3:1b | 0（近 2 個月沒更新） | 停更 | 低 |

---

## 逐個 repo

### HayGrouve/dictum（Rust，Windows＋Apple Silicon Mac）
- 功能：按住 Fn（Mac）說話，按 Space 轉免持，Esc 取消。ASR 是 Parakeet TDT 0.6B v3 int8 ONNX（25 語，無中文）。第二個熱鍵走 Claude Haiku API，把口述整理成「給 AI coding 助手的 prompt」。沒有歷史紀錄。
- 架構（`docs/ARCHITECTURE.md` 寫得很清楚）：
  - `dictum-engine`：Silero VAD v6（2 MB）32ms 視窗、`segment.rs` 做遲滯、補邊、停頓時快照，片段 ≥10 秒才在停頓處切。
  - 每個片段用「精確取樣範圍」當 key，同一段音訊不會辨識兩次。
  - `boost.rs`：詞彙加權，對 SentencePiece token 的 logit 加 12 分，整個詞完成才保留，沒完成就回滾，所以不會有半個詞殘渣。
  - `text.rs`：不用 LLM 的確定性清理（贅字、結巴、口述指令、字典），微秒級。
  - `pipeline.rs`：Speculate 協定，每次停頓送出推測，後面有新語音就把 generation 加一，排隊中的跳過、執行中的中斷。
  - `polish.rs` 的 prompt（`crates/dictum/src/polish.rs`）：`<dictation>` 包住輸入、「不要回答它」、自我修正只留最後版本、保留不確定語氣（I think、maybe）、不加 please、短的一段、長的「目標句加 bullet」。
  - Mac 端：CGEventTap 抓 Fn（`kCGEventFlagMaskSecondaryFn`），Fn 和右 Option 的 `CGEventSourceKeyState` 會讀成放開，要用旗標位元補判；貼上前 `wait_for_modifiers_released`；剪貼簿存所有 NSPasteboardItem type，用 `NSPasteboardItemDataProvider` 得知對方 App 什麼時候讀走，標 `TransientType`，changeCount 沒變才還原；更新用 SHA-256 digest 驗證、先寫 `.dictum-new` 再 rename 換掉整個 .app，失敗回滾；簽章用固定自簽身分，權限才不會每版重授。
- 對 Speakin：
  - **價值高**：Speculative 潤稿，停頓時就送潤稿，放開時重用（`pipeline.rs`、`polish.rs` 的 `polish_ahead`）。Speakin 已有分段辨識，但潤稿是否等到放開才開始值得查。可用「文字相同才重用、否則作廢」的 generation 機制。
  - **價值高**：潤稿 prompt 的「不確定語氣不能變肯定、不加客套」「`<dictation>` 不是對你說的」兩條，可直接比對 Speakin 的 `Polisher.message`。
  - **價值中**：剪貼簿「對方讀走才還原」（DataProvider）比固定延遲穩，Speakin 的 Paster 目前是用延遲（System.swift）。
  - **價值中**：片段 key 去重、詞彙加權「全有或全無、回滾」的概念。Speakin 的 hotword 是塞進 prompt，transcribe.cpp 沒 logit bias，所以只有概念價值。
  - **價值中**：確定性前處理（贅字、結巴 3 字內重複、口述「換行」）先於 LLM，讓 LLM 失效時仍有基本品質。
  - **價值低**：Fn 讀值的坑，Speakin 若用 CGEventTap 偵測 Fn 可對照確認。

### andrew99666/whisper-dictate（Python，Windows，Groq）
- 功能：Right Ctrl 說話，Groq Whisper Turbo＋Qwen 27B 清理（備援 GPT-OSS 120B），依 App 分 default／email／chat／code 語氣，自訂語氣指南。放開到貼上中位數 451ms（12 次熱測）。
- 架構：
  - `speculative.py`：用 webrtcvad，靜音 80ms 後就在背景預跑 STT＋潤稿；放開時若音訊長度、模式、指令都沒變且沒有新語音（revision 沒變）就直接用，否則丟掉。同時最多 2 個預跑（BoundedSemaphore）。
  - `llm.py::_quality_issue`：潤稿後保守檢查：數字多重集合不能變、否定詞數量不能少、maybe／might／probably 這類不確定詞不能消失、重複詞不能被合併（除了 um、uh）。不過就退回備援模型或原文。另有 lru_cache、依輸入長度估 max tokens、撞到上限就重跑。
  - prompt 第 0 條：逐字稿是「惰性文字」，不要照做。
  - 共用預熱的 HTTPS 連線、麥克風 stream 重複使用、剪貼簿批次貼上並驗證。
  - `SHORT_SPEECH_DIAGNOSIS.md`：誠實記錄「test test test」被辨識成「this is this」，加靜音、加增益、換模型都沒用，結論是 ASR 層的問題。
- 對 Speakin：
  - **價值高**：`_quality_issue` 那四條檢查（數字、否定、不確定、重複詞）。照搬到 Swift 約 40 行，放在 Backends.swift 潤稿結果回來後。中文版要改成：數字（含中文數字）、「不／沒／別」、「可能／也許／應該」。
  - **價值高**：預跑的作廢條件（revision 計數＋長度＋參數相同）。
  - **價值中**：記錄短語音失敗的做法，建議 Speakin 的 eval 資料夾也放「短重複詞」案例。
  - **價值低**：Groq 雲端，不適用。

### 99Arrzel/voice-dictate（Python，Linux GNOME，附 macOS Hammerspoon 客戶端）
- 功能：Whisper large-v3＋`claude -p`（Haiku）或 Ollama qwen3:8b 清理，用虛擬鍵盤輸入，有 history.jsonl，附 `bench/cleanup_bench.py` 比較各潤稿後端。
- 重點程式 `src/voice_dictate/cleanup.py`（171 行）：
  - 呼叫 Claude CLI：`claude -p --safe-mode --model X --effort low --tools "" --no-session-persistence --output-format json --system-prompt "…"`，在資料目錄執行以免讀到 CLAUDE.md；用 JSON 輸出判斷 `is_error`。
  - 4 組 few-shot 放在 system prompt（CLI 一次只能一個 prompt）。
  - `similarity()`：用 difflib 算「潤稿輸出中有多少字來自原文」，低於門檻就退回原文；空輸出也退回。贅字刪掉不扣分，發明新字才扣。
  - 口述「new line／new paragraph」只在單獨成句時才算指令（regex 要求前後有標點），「a new line of products」不會被誤判。
  - normalize：全形引號、破折號、不斷行空格轉換。
  - 清單：偵測「number one … number two」轉成編號清單。
- 對 Speakin：
  - **價值高**：相似度防呆。中文版用字元或 bigram 比對，代替 difflib 的詞。
  - **價值高**：確認 Speakin 的 Claude 呼叫有沒有 `--effort`（Speakin 已有 `--tools ""`、`--setting-sources ""`、`--no-session-persistence`，見 Backends.swift:225）。`--safe-mode`、`--effort` 可能再省啟動與思考時間，需要測。
  - **價值中**：`bench/cleanup_bench.py` 的做法（同一批樣本跑各後端比較），Speakin 有 `eval` 資料夾，可以對照。
  - **價值中**：口述指令只在單獨成句時觸發。

### Moggeth/push-to-talk-realtime（Python，Windows，OpenAI 即時轉寫）
- 功能：按住熱鍵錄音（Shift 錄系統音），另一個熱鍵記工作日誌；轉寫後依游標前後文格式化插入；選取文字後可「Tidy」或 rewrite 並有確認彈窗；SQLite 存原始與最終輸出；本機瀏覽器看歷史；監督程序自動重啟；游標旁圈圈進度會依歷史耗時學習。
- 重點：
  - `insertion_formatting.py`（367 行）：用 UI Automation 讀游標前後 256 字，判斷邊界種類（empty／newline／space／sentence／opening／closing／word），句中把開頭英文字降小寫（選取詞是小寫時也沿用）、補或去空格、接在未完成句後面時去掉句尾句號、忽略 rich editor 的零寬字元與物件佔位符、縮寫（e.g.）不當句尾。
  - `rewrite_replacement.py`：替換前驗證焦點控制項、整份文件與游標沒變，變了就退成複製。
  - `output_transaction.py`：貼上與輔助程式替換用同一個互斥鎖。
  - 進度圈依「模型＋音訊長度」的歷史耗時推進。
- 對 Speakin：
  - **價值中高**：Speakin 已有 ScreenContext 讀游標附近文字，可再用來決定「接在句子中間要不要去句號、要不要補空格、英文要不要小寫」。中英夾雜時句中補空格尤其實用（中文接英文詞）。
  - **價值中**：贅詞外，對「選取文字後說話＝改寫」（`selected_text_tidy.py`）提供了完整流程，含失敗退回複製。
  - **價值中**：處理中進度依歷史耗時估算，可用於 Speakin 的選單列／浮窗，讓長潤稿有預期感。
  - **價值低**：mouse gesture、Swiftpoint 觸覺等周邊功能略過。

### kagangungor/TRWhisper（C#，Windows 11，土耳其語）
- 功能：whisper.net（CUDA）＋Silero VAD，三種模式（按住、切換、靜音自動結束），LLM 潤稿支援多家（Ollama、Gemini、OpenAI、Groq、DeepSeek、Claude Haiku），依前景 App 自動切換 persona（VS Code、Outlook 等）、每日呼叫上限、API key 用 DPAPI 加密並提醒輪替、歷史搜尋與「節省時間」統計、語言快速切換熱鍵、串流預覽。
- 重點：
  - `Core/Native/ConsolePasteGuard.cs`：貼到終端機（cmd、Windows Terminal、mintty、PuTTY）時把所有換行、Tab、控制字元壓成單行，因為換行等於 Enter 會直接執行。VS Code 內建終端機無法用視窗類別判斷，所以不處理。
  - `Core/Speech/TranscriptCleaner.cs`：去掉時間戳、`[MÜZİK]` 這類非語音標籤，以及 Whisper 在靜音時編造的已知字幕句（黑名單比對）。
  - `Core/Normalization/*`：土耳其語口語數字、百分比、日期、單位的規則式正規化。
  - 模型閒置自動卸載，Model 分頁顯示記憶體卡片；模型下載附 SHA-256 驗證。
- 對 Speakin：
  - **價值中高**：終端機貼上保護。Speakin 有辨識「終端機」類 App 的清單（UI.swift:218），可延伸：當前景是 Terminal／iTerm／Ghostty／Warp 時，把多行潤稿結果壓成單行，或貼上後不帶換行，避免命令被誤執行。
  - **價值中**：幻覺句黑名單。Backends.swift 已有部分 prompt 回聲過濾（行 47–50），可補中文常見幻覺（「字幕由…提供」「謝謝觀看」「請訂閱」等）。
  - **價值低**：中文口語數字規則式正規化（「百分之二十」→ 20%、「三點五公斤」）可參考 TRWhisper 的結構，是否放在 LLM 前或交給潤稿 prompt 要評估。

### pistonpunk/silisten（Python＋Qt，Linux，有說話者標籤）
- 功能：Whisper large-v3（或 turbo）＋Silero VAD（sherpa-onnx，threshold 0.5、最短靜音 0.35 秒、單段最長 30 秒）；拖入音訊或影片檔轉寫並標說話者（sherpa-onnx pyannote segmentation＋CAM++ embedding，約 40 MB，閾值 0.7）；「Talk more」可接續附加；自動停止靜音 1.6 秒；有羅馬尼亞文微調模型。
- 重點：
  - 微調模型輸出若「不像羅馬尼亞文」或退化（重複），自動回退用基礎模型重跑（`engine.py::_looks_romanian`、`_degenerate`）。
  - `attach_speakers`：把 ASR 片段與說話者區段按重疊比對，只有一個說話者就不加標籤。
- 對 Speakin：
  - **價值低**：Speakin 沒有會議模式，說話者標籤暫時用不到，若以後做會議記錄，sherpa-onnx 的兩個小 ONNX 模型（約 40 MB）是現成路線。
  - **價值低中**：「專用模型輸出不合格就退回通用模型」的模式，若 Speakin 未來有繁中專用與通用兩個 ASR，可借用。退化偵測（重複字）可直接用在 Speakin 的 TEA-ASR 輸出上。

### Akilaydin/OriApps.SayForge（Tauri＋React＋Rust，Windows，雲端 ASR）
- 功能：全域按住說話＋免持，OpenAI 相容的轉寫端點與 chat/audio 端點（input_audio，MP3 64kbps 或 WAV），hotwords、本機文字替換、單一轉寫 prompt、歷史搜尋與匯出、簽章自動更新。已刻意拿掉串流與 AI 潤稿，只剩 ASR 加本機文字轉換。
- 重點：
  - `inject/observation.rs`：貼上前後用 UI Automation 只取「編輯器文字長度」（不取內容；密碼欄位直接不觀察），判斷貼上是否真的生效，沒生效就顯示「可複製的卡片」當退路。
  - 麥克風數位增益 +6 dB 預設、關閉瀏覽器 AGC，避免改動系統輸入音量；低音量警告用 RMS，說話開始後不再重複警告。
  - ASR 協定自動偵測：只在確定是路由或 payload 不相容時才換協定，401／429／5xx／逾時一律不重試。
  - 更新流程：簽章 latest.json，使用者同意才下載。
- 對 Speakin：
  - **價值中**：「貼上有沒有成功」的驗證與失敗退路（浮出可點擊複製的卡片）。Speakin 有 ⌥⇧V 再貼一次，但貼上失敗時使用者未必知道。可用 AX 讀取游標欄位字數變化（Learner 本來就會讀回欄位），沒變就提示。
  - **價值低中**：低音量／靜音偵測提示（麥克風被硬體靜音時給提示），Speakin Onboarding 或錄音時可加。
  - 其他（NSIS、i18n、CSP）與 Mac 無關。

### benlaval23/bensvoice-windows（Python，Windows，Parakeet＋Claude）
- 功能：Right Alt 聽寫（本機 Parakeet），Right Ctrl「Compose」模式（說「回覆說週四可以週五不行」，Claude Haiku 寫成成品，帶 App 名稱與選取文字）。
- 重點：
  - 模型放在子行程，閒置 2 分鐘自動結束，把約 850 MB 還給系統；按下熱鍵時就在背景預熱，放開時通常已就緒；子行程恰好逾時時重新啟動並重試一次。
  - Claude 路徑：有 API key 走 API，否則走 `claude -p --system-prompt-file … --tools "" --no-session-persistence --strict-mcp-config --setting-sources "" --disable-slash-commands`。
  - system prompt 依 App 調語氣（Slack 輕鬆、Outlook 專業、Terminal 技術）。
- 對 Speakin：
  - **價值中**：「Compose」＝指令模式：說一句指令由 LLM 產出整段文字，與 Speakin 純潤稿互補，且 Speakin 已有 ScreenContext 與 Claude 通道，成本小。是否做看產品方向。
  - **價值中**：按下就預熱模型、閒置自動卸載的記憶體策略（Speakin 的 1.7B GGUF 需要檢查是否有閒置卸載；uzbek-dictation 也是 3 分鐘卸載）。
  - 價值低：API key 優先、CLI 備援的雙通道。

### powell-clark/voice-to-text（Rust，Win／Mac／Linux）
- Whisper（whisper.cpp＋Vulkan／Metal）與 Parakeet，按住 Scroll Lock 說話，托盤選單設定，GitHub Release 檢查更新只提示不自動裝。有 CT2 daemon（faster-whisper）通訊協定文件。重點在 CI 很重（adversarial-review、regression gate、smoke transcribe、PII gate）。
- 對 Speakin：**價值低**。可看的只有：`scripts/ci/check-regression-gates.sh` 與 `smoke-transcribe.sh` 這種「固定音檔跑轉寫、WER 退步就擋」的 CI，對應 Speakin 的 eval。Mac 端 Metal，無新做法。

### rvboris/charon（Tauri＋Rust，Linux）
- 按住／切換／auto-VAD 三種觸發，auto-VAD 用 RMS 閾值（3 倍底噪、下限 0.012、靜音 900ms、5 秒沒開口就結束），送到任何 OpenAI 相容 `/audio/transcriptions`，再可選一個 OpenAI 相容 LLM 做校正（使用者自訂 prompt、10 秒逾時、失敗就用原文並顯示警告），Wayland 用 evdev sidecar。
- 對 Speakin：**價值低**。「自適應底噪閾值」可參考，但 Speakin 已用 VAD；校正失敗顯示 `correction_warning` 但仍插入原文的處理方式可以看，Speakin 應該也有。

### DustinHyle/whytype（Python，跨平台含 Mac）
- whisper.cpp（Vulkan／Metal／CUDA）、按住或切換、模擬逐字輸入、錄音時靜音其他播放、浮動小膠囊顯示音量。README 明講 Mac 的 Fn 鍵在它用的鍵盤後端收不到，所以預設用 Ctrl+Cmd。
- 對 Speakin：**價值中的一點**：「錄音時自動把其他播放（音樂）靜音／降音量」，避免串進麥克風。Speakin 若沒做，可用 CoreAudio 降低系統輸出音量（需要權限評估）。其他無。

### nathannncurtis/whisper-ptt（Python＋AHK，Windows Intel NPU）
- AHK 前端加本機 HTTP 後端（純文字 body，`/start`、`/stop`、`/cancel`、`/ping` 在模型載入時回 503）。OpenVINO 跑 Whisper，NPU→CPU→GPU 備援，裝置要「建立成功且暖機成功」才算數。可選 Phi-3.5-mini INT4 清理。
- `cleanup.py`：prompt 刻意很短（system prompt 每次都要預填，長度就是延遲）；串流輸出時檢查開頭是不是「Sure／Here is／I'm sorry」之類 LLM 在聊天而不是清理，輸出超過 `2×原長+30` 字就中止並退回原文，任何錯誤都退回原文。
- 對 Speakin：
  - **價值中**：把防呆做在串流中途（開頭像聊天就中止、長度暴增就中止）比等整段回來再檢查更省時間，對 Speakin 的本機模型與 CLI 串流都適用。
  - **價值中**：prompt 越短越快的取捨，值得檢查 Speakin 潤稿 prompt 長度（尤其本機模型）。

### erikchristi/open-whisper（Python，Windows，Parakeet v3 via onnx-asr）
- 德文專案；剪貼簿貼上或直接輸入兩種方式；`recorder.py` 有 pre-roll 環形緩衝（熱鍵按下前的一小段音訊也納入，避免開頭被切）。
- 對 Speakin：**價值低中**：pre-roll 緩衝。Speakin 若是按下 Fn 才開 AVAudioEngine，開頭幾十 ms 可能漏掉，可以檢查是否已有常駐引擎或預熱。

### gutsmcd-cmd/onsei-nyuryoku（TS PWA，日文＋英文）
- 瀏覽器內 Whisper base 8-bit（約 76 MB）via transformers.js，離線。`src/clean.ts` 是完全規則式清理：日文贅詞（えーっと、あの、うーん…）只在獨立出現時刪（「あの人」保留）、全形半形空格規則、日文不加空格、口述「改行」「新しい段落」轉換行，附單元測試。
- 對 Speakin：**價值低**：可借的是「贅詞只在獨立出現時才刪」這個原則，套用到中文的「那個、就是、然後」，避免誤刪；以及 CJK 與英數之間空格規則（中英夾雜）。

### Komiljon006/uzbek-dictation（Swift＋whisper.cpp C bridge，Mac）
- 單檔 `dictate.swift`（289 行）選單列 App：⌃⌥D、NSPasteboard＋CGEvent ⌘V、模型閒置 180 秒卸載、whisper.cpp 以 C bridge 呼叫、自訂 rubaiSTT 微調 Whisper（`scripts/convert_model.sh` 轉 GGML）。
- 對 Speakin：**價值低**。架構與 Speakin 同路，沒有 Speakin 沒有的東西。唯一可看：閒置卸載的 Timer 寫法。

### itsprocess/VoiceHook（C#，Windows）
- 按住 F9 → 轉寫 → 送 webhook，反向收文字念出來，Stream Deck 外掛，帶持久化的送出佇列與去重。**無**可借鏡處（用途不同）。

### atheerium/voxtype（現名 libretype，Rust，Linux）
- 單人提交疑似由 AI agent 完成，Groq Whisper 雲端，`install.sh` 是 `curl | bash`。**無**。

### Yuvansh-Shah/flowlite（Python，Windows）
- faster-whisper＋Ollama gemma3:1b 清理，近 2 個月沒更新。
- 小可借處：`formatter.py` 的長度防呆（輸入 ≥6 字、輸出少於 75% 就視為摘要，退回安全的規則式清理）；`paste_queue.py` 保留最近 10 筆轉寫，貼到桌面或工作列這類沒有輸入欄位的地方時可用快捷鍵補貼；`output.py` 用視窗類別判斷「這裡貼不進去」。**價值低中**：Speakin 已有 ⌥⇧V，可補「偵測到前景沒有文字欄位就提示，不要默默失敗」。

---

## 補充觀察
- 這組幾乎沒有人做中文，也沒有人解決中英夾雜。可借鏡的幾乎都在「潤稿的安全網」和「貼上的穩定性」。
- 潤稿安全網共識：輸入包標籤、說明「這不是對你說的」、低 temperature、輸出相似度／長度／數字／否定檢查、失敗就退回原文。Speakin 若沒做相似度與數字否定檢查，是最划算的補強。
- 預測式潤稿（停頓就跑）有兩個 repo 實作（dictum、whisper-dictate），作廢條件設計一致：音訊有新語音就作廢，參數沒變才重用。
