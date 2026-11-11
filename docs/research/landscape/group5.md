# 第 5 組：Mac 上的小專案（Parakeet／FluidAudio／notch／Hammerspoon）

統計方式：commit 數是 2026-09-07 之後（gh api），全部都是單人專案（Murmeln、ptarmigan-flow 另有 github-actions bot）。星數幾乎都是 0（只有 sflow 22）。原始碼 clone 在 `$CLAUDE_JOB_DIR/tmp/repos/OWNER__REPO`，只讀沒有執行。

## 整組最值得借鏡的 5 點
1. **LocalAgreement 串流＋逐字打字**（local-whisper-dictation-macos）：連續兩次重跑結果一致的字才「確認」，確認後就不會再變；窗口滑動，標點延後釋放。可以拿來替換 Speakin 現在只靠 VAD 切段的做法。
2. **安全的潤稿輸出驗證**（opennotch、aside）：用長度比 0.5～1.35 或詞集合相似度 >= 0.5 擋掉「模型在回答或摘要」的輸出，不合格就退回規則清理或原文；加 `<transcript>` 圍欄和「短句跳過 LLM」。
3. **邊講邊潤稿＋prewarm**（whisper-dictation-macos by urihell）：句子確認後就先送潤稿，保留最後一句（因為自我修正通常緊接著），結尾只潤剩下的尾巴；不一致就整段重潤。對應 Speakin 的 20 秒分塊平行潤稿，可改成錄音中就開始。
4. **貼上流程的細節**（aside、WhisperKey、Murmeln、whisper-dictation-macos）：AX 直接寫入並用「游標有沒有動」驗證、changeCount 驗證才還原剪貼簿、Electron 沒回 AX role 時看 Secure Input、ConcealedType/TransientType 標記、依 app 切換貼上方式、依鍵盤配置找 V 的 keycode。
5. **Hammerspoon 版的 `claude -p` 潤稿咒語**（Pierre-Mike/hammerspoon）：`--tools "" --setting-sources "" --safe-mode --strict-mcp-config --no-session-persistence`，加上每個預設的 `maxGrowth` 長度上限、逾時 10 秒後退回原文。Speakin 跑 Claude Code CLI 時可以直接比對旗標是否齊全。

---

## 1. cmwright/aside
1. 基本：0 星、Swift（mac＋iOS＋Cloudflare Worker）、macOS 14+／iPhone、MIT、65 commits、單人、很活躍（有測試、Sparkle 更新、公證）
2. 功能：右 Option 按住說話、雙擊免持；ASR 可選本機 Parakeet v3（FluidAudio，下載約 470 MB，放開後才整段辨識）、雲端 Groq／Fireworks／OpenAI；潤稿可選 Cerebras／Groq／OpenAI／Ollama／Apple 本機模型／自架 Worker；字典（term→replacement），ASR 時當 Whisper prompt，潤稿時當指示；歷史、重試上一次、iOS 鍵盤。無 per-app、無學習。
3. 架構：`DictationPipeline`（mac/Sources/DictationPipeline.swift）用 `DictationPlan` 快照設定，所以錄音中改設定不影響這一次；STT 結果先存歷史（checkpoint）再潤稿；潤稿 10 秒逾時＋暫時性錯誤重試一次，仍失敗就貼「原文＋字典替換」；有 `Task.checkCancellation` 保護，新錄音不會被舊結果覆蓋。
4. 對 Speakin 有幫助：
   - **價值高**：`TextInserter.swift` 的貼上策略。優先用 AX `kAXSelectedTextAttribute` 直接寫入，再用「選取範圍有沒有移動」判斷 Chromium/Electron 是不是假成功，失敗才退回 ⌘V；貼之前讀游標前一個字元決定要不要補空格（`needsLeadingSpace`，只讀 1 個 UTF-16 單位，不抓整份文件）；AX 逾時設 1.5 秒避免卡死選單列；貼完 0.4 秒後只在 `changeCount` 沒變時才還原剪貼簿，且完整保存所有 item／type。
   - **價值高**：`DictationPipeline.clean` 的退路設計：潤稿失敗時顯示「Cleanup unavailable (xxx); raw transcript kept」並把原因記到歷史；`similarity(raw, cleaned) >= 0.5` 的詞集合比對擋「離題輸出」。
   - 價值中：事件 tap 被系統關掉時偵測並重建、每次喚醒重建（README 說明），以及選單裡顯示「別的 app 開了 Secure Keyboard Entry」。
   - 價值中：「Retry Last Dictation」只重跑潤稿、錄音只放記憶體。

## 2. kjagsadvisors/opennotch
1. 基本：0 星、Swift（SwiftPM）、macOS 26+、MIT、21 commits、單人、活躍。
2. 功能：按住 fn 聽寫、右 ⌥ 下指令（開 app、點按鈕、選單、改寫選取文字、多步驟 agent loop）；ASR 是 Parakeet（FluidAudio，v3／ultra／redux 可選）＋ Apple SpeechAnalyzer 當下載期間的備援；潤稿用 Groq gpt-oss-20b／Cerebras／Claude Haiku／Ollama，Apple 本機模型刻意不預設（3B 會摘要）；notch UI；Sparkle；有無麥克風的 CLI 測試（`--say`、`--polish`、`--route`）。
3. 架構：Parakeet 是批次模型，所以錄音中每 0.9 秒、至少多 1 秒新音訊就對「目前整段音訊」重跑一次，給 notch 顯示即時字幕（`Speech/ParakeetSpeech.swift`），放開再跑最後一次；指令模式在 partial 文字上就先「投機」決策，最後文字相同就直接用（`AppController.speculate`）。
4. 對 Speakin 有幫助：
   - **價值高**：`Intelligence/Polisher.swift`。三層：規則（去 um/uh、疊字，<10 ms）→ 判斷「是否需要模型」（>= 8 字或含自我修正／口述標點關鍵字才送）→ 模型；system prompt 用 `<transcript>` 圍欄、「不回答、不摘要、不改寫」；輸出驗證用長度比 0.5～1.35（口述格式詞先扣掉），不合格退回規則版；3 秒逾時。Speakin 目前走 CLI 潤稿延遲高，短句直接跳過模型可以省很多時間。
   - 價值中：partial 時的投機處理（對 Speakin 就是「句子確認後先潤稿」）；讀螢幕用 Accessibility tree 且在說話期間就讀，不增加延遲（Speakin 的 ScreenContext 若還是放開才讀可以參考）。
   - 價值低：`--say`／`--polish` 這種無麥克風的 CLI 測試入口，方便做潤稿回歸測試。

## 3. alexellis/VoiceShim
1. 基本：0 星、Swift、macOS 14+、MIT（OpenFaaS Ltd）、3 commits、單人。
2. 功能：Parakeet TDT 0.6B v3（FluidAudio）＋ Kokoro TTS，提供 speechd REST API 給 superterm；選單列 Option+Space；可選 OpenAI 相容端點潤稿且 fail-open。
3. 架構很小（1400 行）：`Delivery.swift` 的 paste 模式是剪貼簿＋⌘V，沒有還原剪貼簿。
4. 對 Speakin 有幫助：無（潤稿 fail-open 的想法其他專案已有更完整的做法）。

## 4. nitkrar/personal_scribe_mac（Ninimma／Seshat）
1. 基本：0 星、Swift（SwiftPM 多模組，約 9.5 萬行含測試）、macOS 14+、MIT（README 寫 TBD，DECISIONS 寫 MIT）、162 commits、單人（大量用 Claude/Codex 協作，有 BACKLOG／heartbeat 契約）、非常活躍。
2. 功能：Parakeet-TDT（FluidAudio，含 Silero VAD、Parakeet EOU 串流、離線 diarization）、WhisperKit、whisper.cpp 當備援；toggle＋VAD 自動停止；「WorkflowMode」把 capture／processor／output sink 組成可設定的 recipe；SQLite＋FTS5 歷史搜尋；字典；規則式後處理（去填充詞、標點），LLM 還沒做（Phase 4）。
3. 架構：`SessionPipelineOrchestrator`（2500 行）＋ `StreamingTranscriptAccumulator`；串流時「LiveCursorOutput」把每個 EOU chunk 用剪貼簿＋⌘V 貼進去，結束時再用整段重跑的「第二遍」結果當定稿；全域快捷鍵用 `RegisterEventHotKey` 不用 event tap，所以不需要輸入監控權限（DECISIONS #25）。
4. 對 Speakin 有幫助：
   - 價值中：`PasteboardSnapshotService`＋`ClipboardWriteToken`：寫入時記下 changeCount，還原前比對，一致才還原（跟 aside 同概念，抽象得更乾淨）。
   - 價值中：`PasteTarget`（Output/、Paste/）：決定「這個 frontmost 能不能貼」，自己的視窗只有在 first responder 是文字輸入時才貼，否則留在剪貼簿。
   - 價值中：串流＋第二遍定稿的設計（DECISIONS #24、#056）。即時貼 chunk、結束用全錄音重跑覆蓋，對應 Speakin「邊講邊辨識」之後怎麼收尾的問題。但即時貼上在文字欄會有「已經貼出去的字改不回來」的問題，要評估。
   - 價值低：DECISIONS.md 的「指令與聽寫用不同快捷鍵，自動判斷會毀掉信任」、「權限漸進式（先麥克風，其他用到再要）」可以當 Onboarding 設計佐證。

## 5. alexktitarov/local-whisper-dictation-macos
1. 基本：0 星、Swift（SwiftUI＋AppKit，約 2600 行）、macOS 14+、MIT、2 commits（剛上傳）、單人。
2. 功能：右 ⌥ 按住說話／單擊免持；WhisperKit（Neural Engine）即時串流，邊講邊用「合成 Unicode 鍵盤事件」打字（完全不碰剪貼簿）；混語模式（俄文／烏克蘭文夾英文）；Prompt mode（⇧＋右⌥，用 Groq LLM 把口述改成結構化 AI prompt）；字彙表；統計（速度、延遲、節省時間）。
3. 架構：`StreamingSession.swift` 是 whisper_streaming 的 LocalAgreement 實作。
4. 對 Speakin 有幫助：
   - **價值高**：`StreamingSession.pass`。每次對「滑動窗口」重新辨識（新增 >= 0.35 秒才跑），連續兩次一致的前綴字才 commit；窗口在已確認的 segment 邊界截斷（>6 秒才截，最長 20 秒）；用文字比對（最近 2～4 個已確認字）而不是時間戳去重；最後一個字的標點先扣住，等下一批字出現才決定（因為 Whisper 每次都因為以為音訊結束而加句號）；窗口之前的已確認字（最近 40 字）當 prompt 讓語言與拼字延續；首次偵測到的語言會鎖住整段。TEA-ASR 是千問系 ASR，不是 Whisper，標點與 timestamp 行為不同，不能整份照搬，但「兩次一致才確認」「窗口截斷」「用已確認文字當 prompt」這三點可以測。
   - **價值高**：`Typer.swift`：把文字切成 16 個 UTF-16 單位一組，用 `keyboardSetUnicodeString` 打進去（不拆 surrogate pair），事件標記 `eventSourceUserData` 讓自己的 hotkey 監聽忽略，`flags = []` 避免繼承使用者正按著的 ⌥，並且 `IsSecureEventInputEnabled()` 時不打。可當 Speakin 貼上失敗（遠端桌面、終端機、不吃 ⌘V 的 app）的備援。
   - 價值中：統計面板（字數、省下時間、延遲）可以給 Speakin 歷史紀錄加料。

## 6. Skeptomenos/Murmeln
1. 基本：0 星、Swift（約 1.6 萬行）、macOS 14+、授權未標示、7 commits（github-actions bot 為主）、單人、文件很多（specs、tasks、docs）。
2. 功能：按住 Fn（>400 ms）說話、雙擊右 Option 鎖定免持；ASR 可選 FluidAudio Parakeet v2/v3、Cohere Transcribe INT8、WhisperKit、雲端（OpenAI／Groq／Gemini／GPT-4o，後兩者一次轉錄＋潤稿）、本機 Whisper server；潤稿用 Ollama 或雲端；Prompt 預設 Casual／Structured／Markdown／Verbatim／自訂；Parallel Audit（同一段錄音跑多個預設比較）；個人字典；歷史。
3. 架構：`AudioService` 的 persistent tap＋0.35 秒 pre-roll ring buffer（按下 Fn 就開引擎，等到 400 ms 才真正開始寫檔，把環形緩衝補進去）；停止時固定等 350 ms 寬限期收尾音；buffer 只用 1024 samples（64 ms）；鎖定狀態用 `OSAllocatedUnfairLock`（docs/audio-cutoff-fix.md，寫得很清楚）。`CapturedPasteTarget` 在錄音開始時記下目標編輯器與游標，交付時必須完全一致才貼；Secure Input 開著時只允許驗證過的 TextEdit／Notion。
4. 對 Speakin 有幫助：
   - **價值高**：docs/PROMPT-ENGINEERING-LEARNINGS.md。小模型的兩個失敗模式：Command Hijacking（口述「寫一份文件」被當指令執行）和 Intro Trimming（把開頭幾句當 meta 話刪掉）；對策是「身份鎖定（你是被動的逐字稿整理器，不能回應）」、「用數量門檻代替模糊規則（>=3 項才用條列）」、「結尾放 Echo 強制規則（從頭到尾都要包含）」；附 5 步測試階梯（中性、指令、問題、meta 劫持、長開場）。可直接拿來做 Speakin 潤稿 prompt 的回歸測試集，特別是 Haiku/本機小模型。
   - **價值高**：pre-roll ring buffer。按下 Fn 就開始緩衝，補進開頭 0.35 秒，解決「第一個字被吃掉」；以及停止後固定 350 ms 尾音寬限。Speakin 若有開頭／結尾被切的回報，這是現成的解法。
   - 價值中：`specs/013-keyboard-layout-paste.md`、`PasteService.keyCode(for:)`：用目前鍵盤配置反查 V 的 keycode（Dvorak、Colemak 上 0x09 不是 V）。Speakin 的 `System.swift Paster` 若寫死 0x09 要檢查。
   - 價值中：貼上前記下目標、貼的當下若焦點或游標變了就不貼，改成留在歷史並顯示「複製」通知（避免文字貼到錯的地方）。
   - 價值低：Cohere Transcribe 第一次載入要 90 秒、記憶體很大，是「模型冷啟動」的負面案例。

## 7. yung-sun-xxi/WhisperKey
1. 基本：0 星、Swift（SwiftPM 多模組＋Xcode，約 2.2 萬行）、macOS 14+、MIT、106 commits、單人、很活躍（有 UI snapshot hook、主題系統）。
2. 功能：純雲端（OpenAI／Groq Whisper），沒有 LLM 潤稿；右 Option／右 Command／右 Shift，tap 或 hold；Esc 取消；Keychain；歷史（可設保留期）；用量統計；「quick-paste」彈窗（按住鍵選最近剪貼簿項目）。
3. 架構：`Sources/PasteEngine/PasteEngine.swift` 把貼上決策寫成純函式 `decide(focus, secureInputActive, secureFieldPolicy)` 並完整單元測試。
4. 對 Speakin 有幫助：
   - **價值中**：`PasteEngine.decide` 的規則：AX subrole 是 `AXSecureTextField` 就不貼（自動貼上才拒絕，使用者主動選的才允許）；role 在 TextField／TextArea／ComboBox 白名單就貼；AX 查不到（Electron）時只有在 Secure Input 沒開才貼。AX 逾時 0.5 秒、失敗 80 ms 後重試一次。Speakin 可以把「貼進密碼欄」的保護做成這個決策表。
   - 價值低：quick-paste 歷史彈窗（hold-to-reveal）可當 ⌥⇧V 的延伸。

## 8. BillMillWIll/local-flow
1. 基本：0 星、Swift、macOS 14+、All rights reserved（不可複製）、5 commits、單人。德文為主。
2. 功能：fn／自訂鍵按住說話、雙擊免持；Apple Speech（macOS 26）／Parakeet v3／Whisper Large v3 Turbo（whisper.cpp＋Silero VAD）；Apple Intelligence 潤稿；字典（想要的拼法＋一個實際聽錯的版本，一對多）；口述指令與文字片段（`neue Zeile = \n`）。
3. 架構：模型下載固定 revision＋sha256 驗證（`ModelInstaller.swift`、`Engines.swift`）；Whisper 靜音幻聽防護：最短 0.4 秒、VAD、片語過濾（`LocalFlowCore.swift` 約 668 行）。
4. 對 Speakin 有幫助：
   - **價值中**：字典設計。「正確寫法＋觀察到的錯誤聽法」成對，跑在所有引擎之後；替換在「原文一次掃過」，最長片語優先，避免連鎖替換；不改到較長字串或識別字內部（AUDIT-2026-10.md 有踩雷清單）。對應 Speakin 的 Store.swift 字典與 Learner 自動學的結果，可拿來檢查替換邏輯有沒有這些 bug。UI 誠實說明「prompt 是辨識提示，不是訓練」。
   - 價值中：模型下載 pin revision＋sha256。Speakin 下載 GGUF 時可以照做。
   - 價值低：授權不開放，只能參考想法。

## 9. NAKAK10/ptarmigan-flow
1. 基本：0 星、Python（約 2 萬行，Homebrew＋py2app 式 .app＋web UI 設定）、macOS（Apple Silicon 與 Intel）、授權未標示、75 commits、單人＋bot、活躍。
2. 功能：全域快捷鍵按住說話；ASR 是 Moonshine（另有 Granite、vLLM realtime、speech.cpp 後端）；LLM 潤稿透過 Ollama／OpenAI 相容端點，有日文與英文兩套 prompt；字典式修正（`transcription_corrections.toml` 的 exact 與 regex 兩段，可附 LLM glossary）；輸出方式 clipboard_paste 或 Quartz 打字；簽章公證 .app，**內建自我更新**（下載、驗證 code signature／Gatekeeper／Team ID／bundle ID／版本，再原地替換並重啟）。
3. 架構：`text_processing/llm.py`：`<transcript>` 圍欄、few-shot 例子、glossary 附在 system prompt、30 秒 circuit breaker（連續失敗後暫停呼叫）、長文以句界切開分段（`_split_for_correction`）。
4. 對 Speakin 有幫助：
   - **價值中**：`app_updater.py` 的更新驗證清單（簽章、Gatekeeper、Team ID、bundle ID、版本一致才替換；不能寫入時退回開 release 頁；權限因簽章不變而保留）。Speakin 的 Updater.swift 可對照。
   - 價值中：潤稿 prompt 每種語言一份、含 few-shot（例如「一周→issue」「ピーアール→PR」這類 ASR 把英文術語聽成日文的修正例）。Speakin 的中英夾雜可以仿照做「中文諧音→英文術語」的 few-shot 例子與 glossary 提示（「聽起來接近時優先用這個拼法」）。
   - 價值低：circuit breaker（潤稿 CLI 連續失敗時 30 秒內直接用原文，不再等逾時）。
   - 價值低：permissions 頁說明「ad-hoc 簽章每次 rebuild cdhash 變，設定顯示 ON 但實際沒授權」，可放進 Speakin 的權限疑難排解。

## 10. Pierre-Mike/hammerspoon
1. 基本：0 星、Lua＋Python（約 3.1 萬行，含大量測試）、macOS、MIT、64 commits、單人、活躍。是個 plugin 系統，其中 `dictation` 只是一個 plugin。
2. 功能（dictation）：按住 Fn 說話；STT 為 parakeet-mlx（本機常駐 `parakeet_server.py`，batch 與串流都有，另可換 mlx-audio 模型）；錄音中每秒對累積音訊重轉、顯示即時字幕；放開後進 **review 面板**（Enter 貼上、⇧Enter 逐字打字、⌥1～⌥9 用 Claude 重寫、⌥0 回原文、Esc 取消）；重寫走 `claude -p`；另有「英文發音訓練」（從你自己的口述找出你唸不好的字，用 phoneme scorer 出練習）、喚醒詞、TTS。
3. 架構：`lib/transcript_filter.lua` 去 Whisper 式幻聽（整段只有「Thanks for watching」才丟，並且只合併「相連的」重複句）；`lib/text_actions.lua` 管 prompt 預設，使用者可用 `text_actions.json` 覆寫或新增，檔案改了就自動重載；`ctx` 管所有 timer／task／hotkey 以便整個 plugin 關閉時收乾淨。
4. 對 Speakin 有幫助：
   - **價值高**：`lib/text_actions.lua` 的 `claude -p` 呼叫旗標：`--system-prompt`、`--model claude-haiku-5-5`、`--tools ""`、`--setting-sources ""`、`--safe-mode`、`--strict-mcp-config`、`--no-session-persistence`、`--output-format json`、`--max-budget-usd`；文字走 stdin、固定短 `-p` 指令，使被注入的文字只能產生文字。對 Speakin（Backends.swift）可檢查是否漏了 `--tools ""`／`--setting-sources ""`／`--no-session-persistence`（避免使用者的 CLAUDE.md、hooks、MCP 讓潤稿變慢或不穩定、避免把口述存進 session 歷史）。
   - **價值高**：每個預設有 `maxGrowth`（清理 2 倍、簡化 1.5、縮短 1）：輸出比輸入長太多就視為模型亂寫，退回。比 opennotch 的固定比例更細。
   - 價值中：review 面板「放開後先給你看、再決定貼不貼」的流程，可做成 Speakin 的選項（尤其對長錄音的潤稿結果）；面板不搶焦點所以 Enter 可以貼進原 app。
   - 價值中：`CLEANUP_TIMEOUT = 10`：逾時就貼原始辨識文字。
   - 價值中：Pronunciation：Learner 的另一個方向（從使用者口述抓「常聽錯的字」）。Speakin 的智慧建議（Suggest.swift）也是找聽錯的詞，可看 `lib/pronunciation.lua` 怎麼定義「一次 slip」與何時再出現。
   - 價值低：plugin 的 ctx 概念（把所有副作用登記起來統一關閉）；Speakin 不需要。

## 11. daniel-carreon/sflow
1. 基本：22 星、Python（PyObjC＋Groq Whisper API，約 4900 行）、macOS 15+、MIT、近 2 個月只有 1 commit，README 開頭說這是 v1/v2 歷史版本，現在在 `sflow-next`（Swift 重寫）。
2. 功能：Ctrl+Shift 按住、雙擊 Ctrl 免持；浮動 pill；貼上有兩種：keystroke（`CGEventKeyboardSetUnicodeString`，不碰剪貼簿，預設）與剪貼簿，貼完會恢復原 app 焦點。
3. 一行帶過：已停止維護。
4. 對 Speakin 有幫助：無（Unicode 打字備援在 local-whisper-dictation-macos 有更完整的版本）。

## 12. egornefedovcz/whisper-dictate
1. 基本：0 星、TypeScript／Python 伺服器＋單檔 Swift menubar app（約 2500 行）、macOS 13+、MIT、1 commit、單人。
2. 功能：Fn+Space 把錄音傳到自己的 CPU 伺服器（faster-whisper large-v3-turbo、int8），同時有 Telegram bot 摘要語音訊息（Claude）、每日團隊摘要。
3. 伺服器 `stt.py`：一個模型一把鎖、`vad_filter=True`、`beam_size=1`、語言 auto 時先偵測並只在允許語言清單裡選、`hotwords` 帶字典。
4. 對 Speakin 有幫助：無（`hotwords` 帶字典是 Speakin 已有的做法）。

## 13. jvkenny/parchment
1. 基本：0 星、Lua（Hammerspoon）＋Python FastAPI 伺服器＋Android overlay、macOS／Android、MIT、3 commits、單人。
2. 功能：右 ⌥ 按住說話，16 kHz PCM 送自家 GPU 上的 faster-whisper large-v3-turbo；可選 `?clean=1` 用 Ollama（預設 CPU）潤稿。
3. 潤稿 prompt 很短，`keep_alive: 30m`、temperature 0.1，沒有輸出驗證。
4. 對 Speakin 有幫助：無（只有「Ollama keep_alive 讓模型常駐」這個小細節，Speakin 若用本機潤稿模型已有類似設定）。

## 14. urihell/whisper-dictation-macos
1. 基本：0 星、Swift（約 8200 行，XcodeGen）、macOS 14+、MIT、12 commits、單人、活躍。
2. 功能：WhisperKit 即時串流（AudioStreamTranscriber，HUD 顯示 confirmed／unconfirmed）；Apple Speech 引擎（短語／部分語言）；hold／toggle／雙擊單鍵觸發；直接 Unicode 打字（預設）或剪貼簿貼上；字典＋取代；口述標點（英西法德葡希伯來中文）；可選 Apple Intelligence 潤稿（錄音中就先處理）；**per-app 覆寫**（語言、是否按 Return、是否用剪貼簿、輸入裝置）；Shortcuts／Siri 動作；Copy Last Transcript；設定匯出匯入；Voice Isolation。
3. 架構：`IncrementalCleaner`、`SpeechCleaner.prewarm`、`HallucinationFilter`（含「疑似幻聽但時間範圍內 VAD 確有語音就保留」的二次判斷）、`MicUsageMonitor`（偵測別的 process 開始用麥克風就釋放自己保持溫熱的引擎）、`AppProfile`。
4. 對 Speakin 有幫助：
   - **價值高**：`IncrementalCleaner.swift`。錄音中已確認的完整句子累積到 >= 80 字且 worker 空閒時送一塊去潤稿（不排隊，等待中的文字併進下一塊）；永遠扣住最後一句（自我修正常緊接）；放開時只潤尾巴；**安全閥**：最後文字不是以「已潤稿的原文」開頭就整段重潤（divergence 偵測）；已知取捨是跨塊的自我修正可能漏掉。對應 Speakin 的 20 秒分塊平行潤稿，可以改成錄音中就開始，放開後延遲只剩最後一塊。
   - **價值高**：`SpeechCleaner.prewarm()`：錄音一開始就預熱模型，session 用完即丟（不跨次沿用，避免前一次口述洩漏進下一次 prompt）。對 Speakin 的 CLI 潤稿，可以在按下 Fn 時就預熱一次（例如先送極短 prompt 或先啟動 process），隱藏冷啟動；「session 不重複使用」的隱私觀點值得確認 Backends 有沒有做到。
   - **價值中**：`minCleanupLength = 60`：少於 60 字不潤稿，一句話直接貼，立刻出字。
   - **價值中**：`AppProfile`（依 bundle id 覆寫貼上方式、語言、是否按 Return、麥克風）。Speakin 已有 ScreenContext 但沒有 per-app 行為設定；「Slack 貼完按 Return」「某 Electron app 改用剪貼簿」是實用需求。
   - 價值中：`TextInserter` 貼上時設 `org.nspasteboard.ConcealedType`／`TransientType`，剪貼簿管理員（Maccy、Raycast）不會把口述內容記進歷史。Speakin 的 Paster 用剪貼簿，這是一行就能加的隱私改善。
   - 價值低：`MicUsageMonitor` 用 `kAudioHardwarePropertyProcessObjectList` 偵測別的 app 正在用麥克風（會議中避免干擾）。
   - 價值低：HallucinationFilter「時間對齊 VAD 當佐證」的想法（TEA-ASR 不是 Whisper，幻聽型態不同，但若遇到靜音時吐出固定句可借用）。
