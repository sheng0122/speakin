# 第 1 組研究報告：四個大型語音輸入專案（2026-11-07）

commit 數是 2026-09-07 之後（GitHub API 計）。四個專案都只讀原始碼，沒有執行或 build。clone 在 `$CLAUDE_JOB_DIR/tmp/repos/OWNER__REPO`。

---

## 1. altic-dev/FluidVoice（⭐12.9k）

### 基本
- Swift（SwiftUI/AppKit），macOS，Apple Silicon 為主（Whisper 和 Apple Speech 支援 Intel）。授權 GPLv3。
- 約 26 萬行 Swift（含測試），近 2 個月 355 commit，30 位貢獻者，多人團隊（altic）。有 CONTRIBUTING，PR 要連 issue、附證據。最新 v1.6.12，beta 1.6.13-beta.2（11/02）。
- 商業策略：App 開源，但最強的「Fluid Intelligence」（本機潤稿模型）是私有 runtime，另外散佈。有 Homebrew cask、iOS／Windows 候補名單。

### 功能
- **觸發**：全域快捷鍵，支援 hold／toggle，可設多組 dictation shortcut slot（每組可綁不同 prompt）。另有「Hold Space to Mute」，錄音中按住空白鍵暫時靜音、放開繼續同一段錄音，快按仍是空白。
- **ASR**：多引擎可選，用 FluidAudio（CoreML）跑 Nemotron Speech 3.5（約 40 語言、可串流）、Parakeet Flash、Parakeet TDT v2/v3、Cohere Transcribe（14 語言，含普通話）、Whisper（tiny 到 large）、Apple Speech。Parakeet 重寫過，宣稱說話到出字幾乎零延遲，有即時預覽（notch overlay）。
- **潤稿**：選用。OpenAI、Groq、自訂 OpenAI 相容端點，或私有本機模型。prompt 可依「dictation slot」和「前景 App」分別指定（`SettingsStore+PromptRouting.swift`、`DictationPostProcessingService.swift`）。
- **其他模式**：Command Mode（語音操作 Mac）、Write/Rewrite Mode（選取文字後口述改寫）、會議轉錄（含說話者分離、AEC3 回音消除，WebRTC audio processing 在 `Vendor/`）、檔案轉錄。
- **插入文字**：Accessibility 直接插入或模擬 ⌘V，有一整套貼上可靠度機制（見下）。
- **上下文**：錄音開始時就在背景讀「游標前文字」和視窗畫面文字：先 AX tree，字數太少才用 ScreenCaptureKit 截該視窗＋Vision OCR（`DictationContextCapture.swift`）。說完才取結果，逾時就丟棄。
- **口述標點／指令**：`ASRService+SpokenPunctuationFormatting.swift`，依 App 不同（Codex、Claude、Cursor、Xcode、VS Code 等）調整「at」符號之類的規則；「說完就送出」（SpokenSendParser，說出送出詞就按 Return）。
- **字典**：文字替換、內建字典（`BuiltInDictionary.swift`，使用者同字優先）、Parakeet vocabulary boosting（`ParakeetVocabularyStore`，可帶 weight 和 aliases）、聲音發音字典（見下）。

### 架構
- 巨大的 `ASRService.swift`（8.4k 行）、`GlobalHotkeyManager.swift`（2.9k 行）。`DirectCoreAudioInput.swift`（1.9k）直接用 CoreAudio，另有大量麥克風熱插拔、音訊拓撲、silent-input recovery 測試（`AudioHardwareRecoveryTests`、`DirectAudioReliabilityTests`）。
- 模型管理：`ModelRepository`、`SpeechModelInstallationSnapshot`、`CompactSpeechModelReleaseCatalog`、`SpeechModelFeed`（模型清單遠端 feed）。
- 私有本機 LLM：`PrivateAIIdleUnloader.swift`，閒置一段時間自動卸載模型釋放記憶體，進行中或錄音中會延後卸載；有硬體建議（`PrivateAIHardwareRecommendation`）。
- 自我更新：`SimpleUpdater` + `UpdateBundleValidator` + `UpdateRollbackBackup`（有回滾備份、bundle 驗證）。
- macOS 15.4 的 main-actor deinit crash 有 workaround：`nonisolated deinit {}`（swiftlang/swift#88036）。

### 值得學的技巧
1. **貼上驗證與復原**（`PasteDeliveryCoordinator.swift` 972 行、`PasteVerifier.swift`、`PreservedPasteboardSnapshot.swift`、`TypingService.swift`）：
   - 剪貼簿暫存用「promised data」，並用 pasteboard provider 觀察「有沒有人讀取」；註解寫得很清楚：讀取回報不等於插入成功，不可拿來重試。
   - 貼上後用 AX 讀回焦點欄位，判斷 landed / notLanded / unknown：notLanded 要求游標位置、欄位值或字元數都沒變；使用者在貼上後按過鍵或點擊就不下結論（`userActedAfterPaste`），避免誤報。失敗時顯示「複製」卡片，不亂重貼。
   - 剪貼簿快照只保存小的 representation（太大的略過，寧可還原得少也不阻塞貼上）；還原時若有人在期間複製了新東西（changeCount 變了）就放棄還原。
   - Cmd+V 用 CGEvent 送進 login session、標記為自己發的，不改 HID modifier 狀態；等實體 modifier 全放開才貼；鍵位用目前鍵盤配置查 "v" 的 keycode（非 QWERTY 配置才不會壞）。
   - 錄音開始時就擷取「目的地 element／window」（`captureRecordingTargetContext`），貼上前檢查焦點仍是原目標，不是的話按策略回復或改走複製。
2. **自動學字典有完整的防誤學機制**（`AutomaticDictionaryCorrectionTracker/Detector.swift`）：
   - 用 AXObserver 觀察被貼上的欄位，延遲後讀回；用前後綴比對找出被改的區段（`textChange(before:after:)`），而且該改動必須落在「我們插入的範圍內」。
   - 候選限長（40 字／70 字），同一組（聽成→改成）要在 7 天內出現 2 次才跳建議；被拒絕冷卻 7 天；本次連續忽略 3 次就停止打擾；最多存 200 組、保留 30 天（`DictionarySuggestionPolicyConfig`）。
   - 不是自動加入，而是跳建議卡由使用者確認。
3. **聲學發音字典（最特別）**：使用者唸一次詞，存 Parakeet encoder frames；之後在新的錄音 encoder frames 上用 subsequence DTW 滑動比對（`DictionaryStampMatcher.swift`），平均 cosine 距離 < 0.16 就直接取代，0.16–0.175 灰區還要字形也相似才取代。註解寫明門檻是用 2,007 次檢查（5 個詞 × 使用者最近 500 筆聽寫）調出來的：43 次真實使用抓到 40 次、1,964 次其他語音 0 次誤換。還有「負例學習」（使用者把替換改回去時，把該聲音存成負例；`DictionaryNegativeExamples.swift`），音訊證據只留 120 秒、佇列最多 4 段（<4MB）、錄音開始就取消編碼讓出資源。這套只對自己的 Parakeet encoder 有意義。
4. 「替換保護」（`DictionaryReplacementProtection.swift`）：避免規則的觸發詞又在自己的輸出裡展開（例如「fluid voice → FluidVoice」遇到已完成的 FluidVoice 不再改）。
5. 用真實資料調門檻並把調參過程寫在註解裡的作法值得學。

### 對 Speakin 有幫助的地方
| 價值 | 項目 | 位置 |
|---|---|---|
| 高 | 貼上後 AX 讀回驗證（landed/notLanded/unknown 三態，使用者有動作就不判失敗）。Speakin 的 Learner 已經會 15 秒後讀回，可以再在貼上後 0.3–1 秒內做一次「有沒有貼進去」檢查，失敗給「複製」提示而不是靜默失敗；`⌥⇧V` 再貼一次可以搭配。 | `Services/PasteVerifier.swift`、`PasteDeliveryCoordinator.swift`、`TypingService.swift: verifyPasteLanded` |
| 高 | Learner 的防誤學規則：改動必須落在我們插入的範圍內；同一組修正出現 2 次才提示；拒絕冷卻 7 天；連續忽略 3 次就暫停；上限 200 組／保留 30 天。可直接套進 Speakin 的 Learner 和智慧建議，降低亂學。 | `Services/AutomaticDictionaryCorrectionTracker.swift`（`DictionarySuggestionPolicyConfig`、`shouldShow`） |
| 高 | 錄音開始時就背景擷取上下文（AX 先、OCR 後備、字數太少才 OCR、說完才取、逾時丟棄、不 log）。Speakin 的 ScreenContext 若是停止錄音後才讀，可改成錄音開始時預讀，省掉潤稿前的等待。 | `Services/DictationContextCapture.swift` |
| 中 | 貼上用的鍵盤配置感知（用目前輸入法查 "v" 的 keycode）、等實體修飾鍵放開、剪貼簿還原時 changeCount 檢查、快照大小上限。 | `PasteKeyCodeResolver.swift`、`PasteKeyCodeCache.swift`、`PasteDeliveryCoordinator.swift: restore` |
| 中 | 本機模型閒置卸載，並在錄音中延後卸載（Speakin 的 1.7B GGUF 和本機潤稿模型可借用，控制記憶體）。 | `Services/PrivateAIIdleUnloader.swift` |
| 中 | 依前景 App／快捷鍵 slot 切換潤稿 prompt（Speakin 目前潤稿是否 per-app 可評估）。 | `Persistence/SettingsStore+PromptRouting.swift` |
| 中 | 「說出送出詞就按 Return」，對 Claude Code／ChatGPT 等聊天輸入很實用。 | `Services/SpokenSendParser.swift` |
| 低 | 更新前驗證 bundle、保留回滾備份。Speakin 的 Updater 可參考。 | `UpdateBundleValidator.swift`、`UpdateRollbackBackup.swift` |
| 低 | 聲學發音字典：技術上漂亮，但綁 Parakeet encoder，Speakin 的 Qwen ASR 沒有對應的 frame embedding，成本高。若想做，替代方案是用 TTS 把詞念出來讓 ASR 聽（見 voz）。 | `DictionaryStampMatcher.swift` |
| 低 | 中文／中英夾雜：FluidVoice 沒有針對性優化（Parakeet 無中文，Cohere 才有普通話），這方面 Speakin 的模型更對路。 | 無 |

---

## 2. opennookorg/betterwispr（⭐514）

### 基本
- Swift（SwiftUI），macOS 14+，Apple Silicon 建議。授權 Apache-2.0。約 2.9 萬行（含測試），近 2 個月 290 commit，11 位貢獻者，看起來一位主要開發者加數人；開發節奏很快（一天多 commit）。另有 `betterwispr-frontend`（網站）、CLI（`BetterWisprCLI`）和 MCP server。
- 文件很扎實：`docs/accuracy.md` 引了十幾篇論文來決定做法（見下）、`docs/testing.md`、`CHANGELOG.md` 詳細到近乎說明書。

### 功能
- **觸發**：預設 ⌥Space，hold 或 toggle；可單獨用 Fn；Esc 取消；可另設取消快捷鍵；選取文字後快捷鍵「清稿」。
- **ASR**：Apple Speech、Parakeet v2/v3（FluidAudio）、WhisperKit large-v3 turbo；也能接 API（Sarvam、Smallest、任何 OpenAI 相容端點）和「Codex 訂閱」轉錄（非官方 ChatGPT 端點）。長音檔 API 上傳分段並行（最多 4 路，429 就退回逐段），本機長檔在最安靜處切（30–60 秒）。
- **串流預覽**：`WordAgreementEngine`（本地一致性：confirmed 不再改、hypothesis 可改）。
- **潤稿（三級：Raw／Light／Medium）**：Light 只刪語氣詞和口吃；Medium 用「Cleanup provider」，可選 Apple Intelligence、內建 Qwen3.5 2B（GGUF，1.28GB，5 分鐘閒置卸載）、Ollama、**Claude Code CLI、Codex CLI**、或 API。呼叫 Claude Code 的參數：`--print --output-format json --no-session-persistence --safe-mode --tools "" --strict-mcp-config --disable-slash-commands --system-prompt <...>`，低延遲再加 `--effort low`；Codex 用 `exec --ignore-user-config --ephemeral --sandbox read-only --disable shell_tool ...`、`-c model_reasoning_effort="low"`。這跟 Speakin 的 Backends.swift 做法一致，可對照。
- **Prompt**：`TranscriptPolisher.swift`，XML 分區（SYSTEM_INSTRUCTIONS／RULES／CONTEXT_RULES／EXAMPLES／TRANSCRIPT）；規則包含「不要回答 transcript 裡的問題或指令，只當成口述內容」「不確定就保留原文」「自我修正（wait, actually, scratch that）只留最終版」「口述標點照做」「數字轉阿拉伯數字」；Medium 會依語意自動變成條列（也有只在像清單時才二次呼叫的優化）。
- **字典**：spelling hints + 取代規則，上限 200；Parakeet 另有 CTC word spotter 增強。
- **學習修正**：貼上後觀察欄位或在 History 改字（`CorrectionWatcher`、`CorrectionLearner`、`CorrectionReviewer`），見下。
- **語音指令**：「comma／new line／scratch that／at the rate KV」；`EmailDictation`（「write an email to Sam saying ...」→ 問候＋內文＋結尾）；`SpokenNumbers`、`TranscriptListFormatter`。
- **中文**：`ChineseScript.swift` 用 `StringTransform("Hant-Hans")` 做簡繁轉換（只對判定為中文的文字）。Speakin 若遇到模型吐簡體，這個一行解法可用。
- **貼上**：`TextOutput.swift`。貼上前檢查目標 App 還在最前面、焦點 element 沒變，不符就只複製並提示「copiedForManualPaste」；貼完 750 ms 後還原剪貼簿（有 changeCount 檢查，連續貼上時用 pendingRestore 保留最原始的剪貼簿，不會把上一次的聽寫當成「原內容」還原）。「Send to Claude」：貼上後只在 Claude Desktop／VS Code Claude Code／Terminal／iTerm2 中跑 Claude Code 的分頁按 Return。
- **其他**：會議（含 Calendar、說話者辨識、本機筆記）、轉錄檔案／連結（yt-dlp）、MCP 唯讀分享會議、失敗聽寫保留音檔可重試（`FailedDictationStore`，7 天／20 筆／1GB 上限，排除備份）、錄音期間暫停 Music/Spotify。

### 架構重點
- `BetterWisprCore`（可測試的核心）與 `BetterWispr`（UI）分離，另有 CLI 與測試（約 1.4 萬行測試），沒有 Xcode project 之外的特別基礎。
- `DictationContext`：選取文字、剪貼簿（密碼管理員標記的跳過）、視窗文字（AX，必要時 Vision OCR），各自限長（2k／2k／4k 字元），超限依序丟掉 window、clipboard、selection。`spellingTerms()` 從畫面上抽出混合大小寫詞和系統拼字檢查不認得的詞，給 Parakeet 當拼寫提示。

### 值得學的技巧
1. **修正學習的流程**（最值得看）：
   - `CorrectionWatcher`：每 500 ms 讀一次欄位，最多 60 次（約 30 秒）；先等欄位出現我們貼的字當 baseline，再用「前後各 16 字元的唯一錨點」找出被改的區段（`edit(of:from:to:)`，錨點要唯一才算數）；`SettledText` 等值穩定才算（避免打字中途）；`IsSecureEventInputEnabled()` 時中止；欄位被清空就中止。
   - `CorrectionLearner`：LCS 找出替換，只收 1–3 字對 1–3 字的替換；替換數超過原文一半就視為重寫而丟棄；常用字表（`commonWords`）永遠不做全域取代，只把修正後的字加成 vocabulary；編輯距離比例 ≤ 0.65 才算「聽錯」；修正後長度 <3 且無大寫就不收。
   - `CorrectionReviewer`：把規則找到的候選丟給筆記模型（改編自 VoiceInk 的 Auto Learn）判斷「值不值得學」，輸出結構化決定（取代＋詞彙／只取代／只詞彙／拒絕），人名一律整個詞（含不變的部分）一起收。
   - 學到的項目標 `learned`，Vocabulary 頁可審視刪除，並可關閉「Learned …」提示；有 Undo。
2. **accuracy.md 的結論**（有文獻出處，適合直接當設計原則）：zero-shot LLM 整句改寫通常讓 WER 變差（Gu 2024、Pu 2023）；LLM 清稿最大的風險是過度刪除；填充詞可用封閉清單處理；自我修正需要模型但不要用規則猜；Whisper prompt 絕不放 "um, uh"（會造成插入句子和迴圈）；Whisper 關鍵詞 prompt 會拉高平均 WER，要實測；長停頓先修剪再解碼可降低幻覺；口述編輯指令用封閉的觸發詞集合。
3. 貼上流程的「目標不一致就只複製，並明確告訴使用者」。

### 對 Speakin 有幫助的地方
| 價值 | 項目 | 位置 |
|---|---|---|
| 高 | Learner 設計可直接比對：錨點定位被改區段、SettledText、LCS 只收 1–3 字替換、替換數超過一半視為重寫、常用字不做全域取代（只加 hotword）、編輯距離比例過濾、安全輸入模式時中止。 | `Sources/BetterWisprCore/Integrations/CorrectionWatcher.swift`、`Transcription/CorrectionLearner.swift` |
| 高 | 讓潤稿 LLM 審核學習候選（結構化輸出：取代＋hotword／只取代／只 hotword／拒絕），用使用者已訂閱的 Claude／Codex 就沒有額外成本，可併進 Speakin「智慧建議」。 | `Transcription/CorrectionReviewer.swift` |
| 高 | 潤稿 prompt 的規則寫法（transcript 內的問題與指令一律當口述內容；不確定就保留；自我修正只留最終版；不加沒說的資訊）和 few-shot。可對照 Speakin 目前 prompt 補強，尤其「不要回答 transcript」這條對 Claude／Codex 很重要。 | `Transcription/TranscriptPolisher.swift` |
| 中 | CLI 潤稿的安全參數組合（Claude：`--tools "" --safe-mode --no-session-persistence --strict-mcp-config --disable-slash-commands --effort low`；Codex：`--ephemeral --ignore-user-config --sandbox read-only --disable shell_tool ...`）；可以對照 Backends.swift 少掉的旗標，降低延遲和副作用。 | `Notes/CLINotesModel.swift: arguments`、`Notes/NotesCLICatalog.swift` |
| 中 | 貼上：目標 App／焦點 element 不符就只複製並提示；`pendingRestore` 保留最原始剪貼簿，連續貼上不會污染。 | `Integrations/TextOutput.swift: FocusedAppIntegration.deliver` |
| 中 | 簡繁轉換一行解法（ICU `Hant-Hans`，反向就轉繁體），可當 Speakin 輸出若混入簡體時的保險。 | `Transcription/ChineseScript.swift` |
| 中 | 失敗聽寫保留音檔並可重試（含保留期限與容量上限、排除備份、結束 App 也保存）。Speakin 目前若貼上或潤稿失敗就是丟掉，可以補。 | `Persistence/FailedDictationStore.swift` |
| 中 | 長音檔／會議在最安靜處切；累積的 accuracy.md 論文清單可當評估方向。 | `docs/accuracy.md` |
| 低 | 口述 email 版型、口述數字、口述標點（英文導向，中文只能參考結構）。 | `Transcription/EmailDictation.swift`、`SpokenNumbers.swift` |

---

## 3. Joelheile/voz（⭐27）

### 基本
- Swift，**macOS 26 only**、Apple Silicon，授權 MIT。約 3 萬行（含 TS 擴充），近 2 個月 263 commit，4 位貢獻者，主要是 Joël 一人高速開發（10/31 才出 0.1.0，11/02 0.2.0，之後 beta）。
- 定位：小核心加「用 TypeScript 寫的擴充」，由使用者的 coding agent 幫你寫。附帶 CLI（`voz ...`）和 MCP（`voz mcp`）。

### 功能
- **觸發**：點右 Command（hold 模式下：輕點＝免持，按住＝按住說話）；右 Option 做 Edit／Reply 擴充。
- **ASR**：Parakeet（FluidAudio，25 語言）；也有 Apple 的 SpeechAnalyzer 當後備／預覽。
- **潤稿**：Apple Foundation Models（`SystemLanguageModel`，`guardrails: .permissiveContentTransformations`、greedy、依字數限制 `maximumResponseTokens`、session 重用與 prewarm、逾時就退回原文）。擴充可選 ChatGPT（用 ChatGPT 帳號登入）或 Claude 寫作。
- **字典**：SQLite（GRDB），詞條有 aliases、replaces；規則 `heard → word`；加上 `VocabularyBooster`（CTC rescoring）。
- **串流**：邊講邊切（`LiveChunker`，8–14 秒在最安靜的 100ms 處切）、每段平行辨識、潤稿以「單元」為單位並且預先「推測式潤稿」（`StreamingDictation`：停頓 250 ms 後就對已辨識的開放文字先跑潤稿，放開快捷鍵時若原文沒變就直接用結果）。最大開放字數 25。
- 其他：Insights（連續天數、語速、省下的時間）、檔案拖進指示器轉錄、記筆記（notch）、歷史搜尋（容錯、不分順序）。

### 「越用越準」的學習機制（重點）
Voz 真正的「學習」有三條，都在本機：

1. **編輯學習（詞彙）**（`Vocabulary/VocabularyStore.swift: EditLearner`、`VocabularyLearner.swift`）
   - 貼上後取得插入文字與欄位現值，LCS 比對；只收「等長替換」（removed.count == added.count，逐字配對）；上限 400 字。
   - `looksMisheard`：Levenshtein 相似度 ≥ 0.5；`looksLikeTermWorthLearning`：長度≥2、含字母，且含數字、camelCase、或系統字典不認識（`isKnownWord`）才算值得學。
   - 處理：如果修正後的字已在字典 → 直接新增一條替換規則（heard→word）；否則 → 變成「建議」（`vocabulary_suggestion` 表），使用者在字典頁一鍵接受或略過；接受才成為 `source: learned`。
   - **用 TTS 反推 ASR 實際會聽成什麼**（`Vocabulary/SpokenWord.swift`）：新詞進建議時，用 `AVSpeechSynthesizer` 把詞念出來、離線寫成 PCM，再丟給自己的 ASR，把聽到的結果存成 `aliases`。這樣不用等使用者再講一次，就知道「Kubernetes」常被聽成什麼並加進替換／提示。10 秒逾時。
2. **口述學習**（`Vocabulary/SpokenCandidates.swift`）：聽到拼字（「K A I T L Y N」，≥3 個單字母）就學成詞；聽到「not X」（「Kaitlyn not Caitlin」）就把 X 當正確詞、「not」前一個字當聽錯。同樣過 `isWorthLearning`。
3. **寫作風格學習（voz-reply 擴充）**（`examples/reply/style.ts`、`memory.ts`、`Extensions/DraftWatcher.swift`）
   - `DraftWatcher`：擴充插入草稿後，每秒讀一次欄位，最多 2 分鐘；用 `DraftTrace`（記錄草稿在欄位中的起訖位置，之後只算動到草稿範圍的變更）判斷結果：kept／edited／removed。
   - `style.ts`：每 5 分鐘一次、由 Apple 本機模型（無論使用者選哪個寫作模型）從「被改過或被拒絕的草稿」和「實際寄出的訊息」歸納出規則，依 App（有時依對象）分存在 SQLite；每個 App 最多 8 條 learned、3 條 observed，超過就合併；每次只給模型看 4 筆證據（模型 context 約 4k tokens）。使用者可在設定頁看到並刪除。
   - `memory.ts`：每 5 秒記下前景視窗文字（FTS5 全文索引，30 天，同視窗 5 分鐘內合併），回覆時用相符的畫面記憶當上下文。
   - 這一條較偏「寫作助理」，不是辨識準確度。

結論：它的「越用越準」其實是「詞彙層」＋「風格規則層」，不會改變 ASR 模型；辨識本身的準確度提升仰賴 Parakeet 詞彙增強（CTC rescoring）而已。

### 其他值得學的技巧
- **CleanupGuard**（`Cleanup/CleanupGuard.swift`）：潤稿結果的確定性防護——空白、拒絕語（"I'm sorry"、"here is"、"sure" 等開頭，而原文沒有）、洩漏標籤（輸出有 `<` 而原文沒有；開頭是 "Output:" 之類）、長度超過原文 1.3 倍、Light 模式下「清稿後的詞必須是原文的子序列（只能刪，容許合併相鄰詞如 "chat GPT"→"ChatGPT"，字典詞豁免）」。任何一項觸發就退回原文。
- 預熱：潤稿 session `prewarm(promptPrefix:)`，session transcript 超過 30 筆就重建。
- `KeystrokeStreamRevision`：串流輸入時用最小退格＋插入修正（以 grapheme 為單位）。
- 錯誤碼設計：CLI exit code 4 代表沒聽到語音。
- 擴充執行失敗不拖垮聽寫；資料夾隔離；隱私：讀畫面文字會略過密碼欄、密碼管理員、私密瀏覽、並遮蔽 key／token／卡號／IBAN。

### 對 Speakin 有幫助的地方
| 價值 | 項目 | 位置 |
|---|---|---|
| 高 | **CleanupGuard 的確定性防護**：潤稿輸出若空、像拒絕、洩漏標記、超過原文 1.3 倍、或（輕度模式）新增了原文沒有的詞就退回原文。Speakin 用 Claude／Codex CLI 潤稿，模型偶爾會「回答問題」或加前言，這層防護成本很低。中文可改成以字元／詞長比而不是英文 word 計數。 | `Sources/Voz/Cleanup/CleanupGuard.swift` |
| 高 | **TTS 反推別名**：新詞進字典或建議時，用 `AVSpeechSynthesizer`（中文用 zh-TW 語音）念出來、餵給 ASR，把實際輸出存成 aliases，不必等使用者再說一次。Speakin 的智慧建議與字典新增都能用，尤其對中英夾雜的英文專有名詞。 | `Sources/Voz/Vocabulary/SpokenWord.swift`、`VocabularyLearner.swift: consider/aliases` |
| 高 | 學習判斷分兩層：「修正後的詞已在字典」→ 直接加替換規則；「新詞」→ 進建議待確認；接受才寫入。比一律自動寫入安全，也適合 Speakin 的 Learner。 | `Vocabulary/VocabularyLearner.swift` |
| 中 | 口述拼字學習（K-A-I-T-L-Y-N）與「not X」校正。中文可變成「X 的 X」「是…不是…」。 | `Vocabulary/SpokenCandidates.swift` |
| 中 | 推測式潤稿：停頓 250 ms 後就對已辨識文字預先潤稿，放開快捷鍵時原文沒變就直接用。Speakin 已有 VAD 切段與 20 秒分塊平行潤稿，可評估對「短到中等長度」錄音也預先跑，降低放開後的等待。 | `Sources/Voz/Dictation/StreamingDictation.swift`（`Speculation`、`interimPause`） |
| 中 | `DraftTrace`：記錄貼上內容在欄位中的位置，之後只看動到那一段的變更（避免使用者在同欄位其他地方打字被誤判成修正）。可補強 Speakin Learner 的範圍判斷。 | `Sources/Voz/Extensions/DraftWatcher.swift` |
| 低 | 風格學習（每 App 8 條規則、證據每次 4 筆、合併）：把使用者對潤稿的修改歸納成 per-app 風格規則放進 prompt。有趣但屬進階，Speakin 現階段可先不做。 | `examples/reply/style.ts` |
| 低 | 擴充架構（TS、npm 發佈）對 Speakin 不適用；CLI／MCP 控制介面可以參考但不急。 | `Resources/Extensions/host.ts` |

---

## 4. sushilk1991/velora（⭐19）

### 基本
- Swift（App）＋ Python（本機 engine，MLX），macOS 14+、Apple Silicon，授權 MIT。約 10 萬行 Swift（其中 selftest 就有 3 萬行），近 2 個月 142 commit，單人（1 位貢獻者，多半由 AI 輔助，`AGENTS.md`/`CLAUDE.md`/`PROGRESS.md`/大量 `docs/research/` 研究報告）。另有 iOS alpha。
- 架構：Swift App（選單列、HUD、快捷鍵、插入、設定）＋獨立 `velora-engine` 行程（STT＋潤稿＋會議筆記），透過 `~/.velora/engine.sock` 框架化 JSON＋原始 PCM 溝通；另有 `control.sock`（CLI／MCP，預設關閉、擁有者限定）。

### 功能
- **觸發**：預設右 Option，hold；⌃⇧A 為 Action Mode（口述動作，如「用 Slack 傳訊息給 Priya」）；選取文字後口述改寫。
- **ASR**：預設 `whisper-large-v3-turbo`（MLX F16）；可選 large-v3、Parakeet v2/v3（串流預覽）、Hindi 專用模型；**實驗性 transcribe.cpp Q8 Whisper GGUF**（與 Speakin 同一個引擎）。實測 M4 Max 合成語料：stop→text 中位數快 33.6%、p95 快 31.5%，沒有 WER 退步；但預設仍是 MLX，要過私有真人語音門檻才換（≥18 段、≥10% 提升、無退步、RTF ≤0.9）。
- **潤稿**：本機 Qwen3.5-4B-MLX-8bit（Quality）或 2B-4bit（Compact），7 種內建模式（default/email/message/note/code/terminal/raw），可按 App 指派；Whisper 的 `initial_prompt` 用字典詞。
- **插入**：`TextInserter` ＋ `StreamTypingSession`（邊講邊打字、AX 直寫、Sublime 專用橋、keystroke 後備、預覽後備；使用者在打字就放棄串流 `StreamInputOwnership`）。每次最終結果都會留在剪貼簿。
- **上下文**：`ScreenContext.swift`（3.9k 行）、`ContextGlossary`：游標附近 AX → 視窗 → Vision OCR（需螢幕錄製），抽出最多 24 個詞、600 字，每個詞必須「字面上出現在讀到的文字中」；過濾疑似 prompt injection 的字（ignore、system、instruction…）和網址。
- **學習**：`EditWatcher`（AXObserver 觀察被貼上的欄位，改動立刻學，不用等 60 秒計時器）、`CorrectionDiff`、`LearningStore`、`DictionaryRepository`、iCloud 字典同步；engine 端 `vocab_miner.py`：閒置時用本機 LLM 從歷史聽寫挖專有名詞，**LLM 只負責提名、確定性驗證（必須字面出現在原文、形狀檢查、停用字）、候選要在 ≥2 次不同聽寫出現才升級**，上限 100 詞，使用者刪除的進 banned 清單永不重學。
- 另有會議（顯式同意、雙軌錄音、diarization、本機筆記）、Action Mode（CUA driver）、檔案轉錄、CLI/MCP。

### 值得學的技巧（含誠實的研究結論）
- **研究文件非常值得讀**（`docs/research/`）：
  - `2026-10-29-cleanup-model-decision.md`：在 303 筆自己的聽寫和 593 筆多口音公開資料上評估，**4B 潤稿的 wWER 反而高於原始 ASR 輸出**（owner 4.09% → 6.07%；EdAcc 19.6% → 22.2%），原因主要是「內容詞被刪除」（歷史 1,045 筆：raw 刪 110 詞，final 刪 765 詞）。格式（大小寫、標點）進步，但字詞錯誤增加。結論：潤稿不是準確度提升，只是格式化；最好的 pipeline 改動是「list 旁路內容刪除防護」（4B harms 91→83、164→86，修字數不變）。與 betterwispr 的 accuracy.md 結論一致。
  - `2026-10-29-cleanup-latency-roofline.md`：潤稿延遲屬記憶體頻寬極限，沒有任何速度手段通過。
  - `2026-07-28-dictation-reliability-learning-audit.md`：用自己 206 筆聽寫的實測延遲（finalization 中位 2.3 s、p90 7.2 s、p95 11.6 s；STT p90 5.3 s）發現問題是**尾端延遲**，不是平均；並發現 5 分鐘上限其實是預設值造成的靜默截斷，改為 1 小時；也列出市面上最強的使用者需求：穩定核心流程、詞彙與修正學習、長錄音不被截斷。
  - `2026-08-17-competitor-gauntlet.md`：把 FluidVoice、Superwhisper、Kivi 對照 Velora 的功能矩陣，值得整張抄來當 Speakin 的功能 gap 表。
  - `stt-multilingual-decision.md`：英文專用 Parakeet 在多語／code-switch 會產生垃圾；Whisper turbo 對 Hinglish 輸出接近完美。對應到 Speakin 的中英夾雜情境：模型要選多語的。
- **Whisper prompt echo 防護**（`engine/src/velora_engine/stt.py: strip_prompt_echo`、`build_glossary_prompt`）：glossary 當 `initial_prompt` 時，Whisper 常把 prompt 吐進轉錄（特別是靜音或長錄音尾端）。他們的作法：prompt 只放詞（用逗號分隔，不加 "Glossary:" 這種標頭字，否則會被解碼進文字）、詞序把最重要的放最後（Whisper 最看重 prompt 尾端）、保守地移除前導 echo（需 ≥3 個 prompt token 依序吻合，或 "Glossary:" 後接 ≥2 個依序詞）；另有重複尾端修剪、padding segment 防護、壓縮比／重複檢查（hallucination guard）。Speakin 把 hotword 塞進 ASR prompt，同樣有這個風險。
- 串流輸入打字時的最小退格修正，及「使用者開始打字就放棄串流」的所有權判斷。
- 設定與引擎設定的檔案鎖、原子寫入、0600；下載狀態機（queued/downloading/verifying/loading/retry_wait/ready/failed，續傳驗證 Range、Hub revision pin、SHA-256 pin），模型切換要新模型載入驗證成功才替換舊的。
- 錄音期間暫停 Music/Spotify（只在能確認唯一播放器時才暫停，並只恢復自己暫停的）；「降低其他音訊音量」選項。
- 首次 PCM 才算「ready」（`first-converted-PCM readiness`），避免錄音宣稱開始但還沒有音訊。

### 對 Speakin 有幫助的地方
| 價值 | 項目 | 位置 |
|---|---|---|
| 高 | **Whisper／ASR prompt echo 防護與 glossary 格式**：Speakin 的 hotword 進 ASR prompt（TEA-ASR 是千問 ASR，行為不同，但「prompt 內容被吐進文字」在小模型上很常見）。可實作：prompt 只放詞、重要詞放尾端、輸出後偵測並移除前導／結尾的 prompt echo、重複尾端修剪。建議先用靜音和很短的錄音測 Speakin 是否已有此問題。 | `engine/src/velora_engine/stt.py`（`build_glossary_prompt`、`strip_prompt_echo`、hallucination guard） |
| 高 | **潤稿會降低字詞準確度的實證**：潤稿要加內容刪除防護（清稿後若丟掉原文內容詞就退回）、對短句或「已乾淨」的句子直接跳過潤稿。Speakin 可以自己用歷史紀錄做同樣的評估（raw vs final 刪詞統計）。 | `docs/research/2026-10-29-cleanup-model-decision.md`、`PROGRESS.md`「list-bypass content guard」 |
| 高 | **用尾端延遲（p90/p95）而不是平均來看**：從歷史紀錄統計 finalization／STT／cleanup 的 median/p90/p95，並找出長尾（15–45 秒錄音穩定，長的才慢）；Speakin 的 20 秒分塊平行潤稿正好對應這個問題，可用同樣報表驗證。 | `docs/research/2026-07-28-dictation-reliability-learning-audit.md` |
| 中 | 閒置時用 LLM 挖歷史聽寫的專有名詞：LLM 只提名、確定性驗證（需字面出現在原文）、出現 ≥2 次才升級、使用者刪除進 banned 永不重學、上限 100。對應到 Speakin「智慧建議」，可把「出現次數」和 banned 清單機制補進去。 | `engine/src/velora_engine/vocab_miner.py`、`Learning/AutoVocabStore.swift` |
| 中 | `EditWatcher`：用 AXObserver（`kAXValueChangedNotification`）監聽被貼上的欄位，使用者一改就能學，比固定 15 秒讀回更即時，也能抓到「改完又繼續打字」的穩定時間點；不支援時退回計時器。 | `Sources/Velora/Learning/EditWatcher.swift` |
| 中 | 螢幕詞彙抽取的安全規則：每個詞必須字面出現在讀到的文字、限 24 詞 600 字、過濾疑似 prompt injection 詞（ignore／system／instruction／網址）。Speakin 的 ScreenContext 把畫面文字放進潤稿 prompt，值得加這層過濾，避免網頁內容影響潤稿 LLM。 | `Sources/Velora/Context/ContextGlossary.swift`（`instructionPattern`） |
| 中 | transcribe.cpp 的使用經驗（Q8 GGUF、pause-aligned segmentation、long-session stitching、prompt-echo 防護、失敗自動退回舊後端）和他們的後端評測 gate（私有真人語音 ≥18 段、p50/p95 ≥10% 提升、RTF ≤0.9）可當 Speakin 換模型時的驗收標準。 | `docs/research/stt-multilingual-decision.md`、`engine/scripts/benchmark_stt_backends.py` |
| 低 | 下載狀態機與續傳（Range 驗證、revision/SHA-256 pin、新模型驗證成功才替換）；Speakin 模型下載可參考其狀態與錯誤分類。 | `docs/ARCHITECTURE.md`「Model acquisition and recovery」 |
| 低 | 錄音期間唯一可確認的播放器才暫停音樂，只恢復自己暫停的。 | `Sources/Velora/Capture/MediaPlaybackCoordinator.swift` |
| 低 | Action Mode、會議、iOS：與 Speakin 定位不同。 | 無 |
