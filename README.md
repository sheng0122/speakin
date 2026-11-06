# Speakin

Mac 上的語音輸入。按 Fn 講話，再按一下，字就貼到游標所在的地方。

- 語音辨識在你的電腦上跑，聲音不會上傳。
- 可以用你電腦上已經登入的 Claude Code、Codex 或 Antigravity，把口語整理成通順的文字（可關）。
- 字典：常被聽錯的詞，加一次就會自動改對。

## 安裝

1. 到 [Releases](https://github.com/sheng0122/speakin/releases/latest) 下載 `Speakin.dmg`。
2. 打開後把 Speakin 拖進「應用程式」。
3. 第一次打開會帶你開麥克風和輔助使用權限、下載辨識模型（約 1.7 GB）。

需要 macOS 14 以上、Apple Silicon。之後有新版會自動下載，按「重開完成更新」就好。

## 自己編譯

`./build.sh`。辨識引擎 `Vendor/TranscribeCpp.xcframework` 沒有放在 repo 裡，要自己另外準備。
