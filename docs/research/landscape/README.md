# 語音輸入專案全景掃描

對象：GitHub 上 2026-09-07 之後有 push 的語音輸入專案，共 76 個。搜尋用 `gh search repos`，13 組關鍵字，結果在 `search-results.txt`。
比對：Speakin `bfc923c`。
日期：2026-11-07。只讀程式碼，沒有建置或執行。

> 這是**廣度掃描**，7 個 subagent 各負責 4～18 個 repo，每個 repo 只看幾分鐘，借鏡項目大多停在概念層。逐行對照 Speakin 的深度研究，請看同層的 `../typewhisper.md`、`../hyday-talk.md`、`../voz.md`、`../open-dictate.md`、`../oliv.md`、`../speakmore.md`。
> 「Speakin 現況」欄有對照原始碼查證過。標「TW #N」的項目，`../typewhisper.md` 的待修清單已有，以那邊的寫法為準。
> 各組完整報告在 `group1.md`～`group7.md`，每個 repo 都有基本資料、功能、架構，以及借鏡項目和價值高低。

## 最大結論

- **直接競品：mukiwu/hyday-talk**。同樣按 Fn、用 transcribe.cpp 跑 TEA-ASR 1.1、呼叫 Claude Code。單人開發，近 2 個月 88 個 commit。它的自動學習規格寫得最完整（`CONTEXT.md`、`CorrectionLearning.swift`），值得細讀。→ group2
- **其他專案都不是針對繁中加中英夾雜做的**。FluidVoice（⭐12.9k）用的 Parakeet 沒有中文；SayIt 走簡體、以雲端為主。TEA-ASR 是 Speakin 的差異化。
- **多個專案各自得出同一個結論：潤稿會刪掉內容**。velora 用 303 筆自己的聽寫實測，4B 模型潤稿後 wWER 從 4.09% 升到 6.07%。至少 10 個專案各自做了「潤稿結果不合格就退回原文」的防護。

## 建議優先順序

| # | 作法 | 來源 | Speakin 現況 | 價值 |
|---|---|---|---|---|
| 1 | 潤稿防護補強：數字、否定詞、「可能／也許」、英文詞、字典詞必須原樣保留；首尾內容詞不能被吃掉；失敗的那一塊退回原文 | voz `CleanupGuard.swift`、open-dictate `guard.ts`、dictate、oliv `cleanup_guard.rs`、hyday-talk | `Text.plausible`（`Text.swift:121`）只有 LCS 整體比例，允許刪 4 成，結尾少一句抓不到 | 高 |
| 2 | （TW #2、#8）剪貼簿還原：等目標 App 真的讀走才還原（promise／DataProvider），不用固定延遲 | SpeakoFlow `paste_tx/`、SayIt、Plume、dictum、jarvis-voice | 固定等 0.6 秒（`System.swift:162`）；已有 TransientType 和 changeCount 檢查 | 高 |
| 3 | 貼上前切到 ASCII 輸入源，貼完切回（注音使用者） | Lamitype `InputSourceManager.swift` | 沒有（grep 找不到 TIS 相關程式碼） | 高（要先實測會不會出問題） |
| 4 | （部分同 TW #18）Learner 防誤學：只收 1～3 字替換；同一組出現 2 次才生效；被拒絕後冷卻或永久不學；整段重寫不學；讀回時機改成 Enter 前、切 App、下次按 Fn，或用 AXObserver | hyday-talk、voz、betterwispr、FluidVoice、murmur、VoiceFlow | 固定 15 秒讀回 | 高 |
| 5 | （TW「錄音中先潤已完成的塊」）邊講邊潤稿：確認的句子累積到約 80 字就先送潤稿，放開只潤最後一段；或停頓 250 ms 先潤，放開時原文沒變就直接用 | urihell `IncrementalCleaner`、voz、dictum、open-dictate（14 秒口述放開後約 0.25 秒貼上） | 超過 20 秒才分塊平行潤稿 | 高 |
| 6 | 用離線歷史錄音重跑 eval：把使用者的修正當答案，只保留讓分數變高的調整。另可拿 Common Voice zh-TW 和 ASCEND（中英夾雜）當測試集 | owl `learner.rs`、`eval.rs`、`scripts/eval/fetch_public.py` | `eval/` 有手動比較 | 中～高 |
| 7 | ASR prompt echo 和靜音幻覺：靜音時 hotword 被吐回來就丟掉；加中文幻覺句黑名單（「謝謝觀看」「字幕由…提供」）；重要的詞放尾端 | velora `stt.py`、murmur `DecodeCoverage.swift`、TRWhisper、LocalScribe | 要先用靜音和很短的錄音測，看有沒有這個問題 | 中 |
| 8 | （TW #19）切段：沒停頓時往回 3 秒找最安靜的 200 ms 切，不要硬切 | fuck-you-flow | 25 秒硬切（`Audio.swift:118`） | 中 |
| 9 | 開頭吃字：0.35 秒 pre-roll ring buffer；停止後多錄 350 ms；麥克風暖機（藍牙耳機排除） | Murmeln、open-dictate `warm.ts`、oliv（AirPods 開頭整段是 0 的事故檢討） | 要確認 | 中 |
| 10 | 貼上驗證：貼後用 AX 讀回，判斷貼上了、沒貼上、不確定三種狀態，失敗就提示可以複製；錄音開始時記下目標 App 和欄位，貼上前比對，不一樣就只複製不貼 | FluidVoice `PasteVerifier.swift`、LocalScribe `safeInsertion.ts`、OutLoud | 沒有 | 中 |
| 11 | 用 TTS 反推別名：新詞進字典時，用系統語音念給自己的 ASR 聽，把聽到的結果存成別名 | voz `SpokenWord.swift` | 沒有 | 中 |
| 12 | （TW 待確認項）Claude CLI 旗標：可以加 `--safe-mode`、`--effort low`、`--output-format json`（用 is_error 判斷） | betterwispr、voice-dictate、hammerspoon | 已有 `--tools ""`、`--setting-sources ""`、`--strict-mcp-config` 等（`Backends.swift:225`），沒有 `--safe-mode` | 低成本 |
| 13 | 同一個潤稿請求送兩份，取先回來的，砍掉長尾延遲 | jarvis-voice `core/hedge.mjs` | 沒有 | 中（成本加倍） |
| 14 | 終端機保護：前景是終端機時，把多行壓成一行，避免換行直接執行 | TRWhisper | 要確認 | 低～中 |
| 15 | smart spacing：讀游標前一個字決定要不要補空格、去句號；選取文字後口述等於編輯指令 | SpeakoFlow、SayIt、aside、push-to-talk-realtime | ScreenContext 已經讀得到前後文，可以重用 | 中 |
| 16 | （TW #22）模型下載：`.incomplete` 暫存檔、hash 驗證、磁碟空間檢查 | OutLoud `ModelStore.swift` | 要確認 | 低～中 |

## 值得整份讀的文件

- velora `docs/research/2026-10-29-cleanup-model-decision.md`：潤稿模型反而讓錯字率變高的實測
- betterwispr `docs/accuracy.md`
- Murmeln `docs/PROMPT-ENGINEERING-LEARNINGS.md`：小模型的 Command Hijacking 和 Intro Trimming 兩種失敗模式，加上 5 步測試流程
- LocalScribe `docs/MODEL_COMPARISON_EVIDENCE.md`：Mac 上用 transcribe.cpp 跑各模型的錯字率和速度
- SpeakoFlow `AGENTS.md`：transcribe.cpp 踩坑筆記
- hyday-talk `CONTEXT.md`：自動學習規格
- oliv 的兩份事後檢討（AirPods 開頭全是 0、VoiceProcessingIO 卡 3.3 秒）

## 授權注意

murmur、Plume 沒有 LICENSE 檔，local-flow 是 All rights reserved，OpenFlow 是 GPL-3.0，FluidVoice 是 GPLv3，SayIt 是 AGPL。這些只能參考想法，不能直接搬程式碼。

## 各組

| 組 | 範圍 | 檔案 |
|---|---|---|
| 1 | FluidVoice、betterwispr、voz、velora | group1.md |
| 2 | 中文競品：hyday-talk、Lamitype、owl、SpeakSlow、jarvis-voice、talky 等 | group2.md |
| 3 | 跨平台、Handy fork：SayIt、SpeakoFlow、earheart、open-dictate 等 | group3.md |
| 4 | Mac Swift 小專案：oliv、murmur、dictate、OutLoud 等 | group4.md |
| 5 | Mac Parakeet、notch：aside、Murmeln、urihell、WhisperKey 等 | group5.md |
| 6 | Win、Linux、自架：LocalScribe、fuck-you-flow、orpheus、VoiceFlow 等 | group6.md |
| 7 | 其他小專案：dictum、TRWhisper、voice-dictate 等 18 個 | group7.md |

注意：group7 說 Speakin「完全沒有潤稿防呆」是錯的，Speakin 已經有 `Text.plausible`。
