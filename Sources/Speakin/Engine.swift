import AppKit
import AVFoundation

/// 主流程：Fn → 錄音（邊講邊切段送 Breeze）→ Fn → 字典替換 → Haiku 潤稿 → 貼上 → 15 秒後學習
@MainActor final class Speakin: ObservableObject {
    static let shared = Speakin()
    enum State { case idle, recording, processing }

    @Published var state = State.idle { didSet { pill.update(); hotkey.recording = state == .recording } }
    @Published var levels = [Float](repeating: 0, count: 14)
    @Published var staged: URL?   // 新版已下載、驗證好，等使用者按重開
    @Published var message: String? { didSet { pill.update() } }
    @Published var hotkeyReady = false
    @Published var lastText = ""   // 上一次貼出去的結果，⌥⇧V 再貼一次；歷史設成不存也記得
    @Published var tab: String? = "首頁"
    @Published var update: Updater.Release?   // 有比較新的版本可以下載   // 主視窗目前在哪一頁，選單列也能切

    let store = Store.shared
    let asr = ASR()
    let polisher = Polisher()
    private var helpers: [Polisher] = []   // 錄音超過 20 秒（約 100 字，會分塊）才開，長文分塊同時潤稿，用完就關
    let local = LocalPolisher()
    private let rec = Recorder()
    let hotkey = Hotkey()
    private lazy var pill = Pill(self)
    private var seg = Segmenter()
    private var gen = 0                                   // 第幾次錄音；取消或重錄後，舊的工作自動放棄
    private var pieces: [Task<String, Never>] = []        // 每段辨識結果
    private var failedParts = 0, totalParts = 0              // 幾塊潤稿不可信、總共幾塊
    private var polishFailed: Bool { failedParts > 0 }
    private var segCount = 0
    private let log = SessionLog()
    private var runSettings = Settings()
    private(set) var started = Date()
    private var app = ""
    private var context = ""
    private var screen = ""   // 前景視窗最底下 2000 字，只給雲端潤稿；本機小模型給長文會亂抄
    private var asrError: String?
    private var iMuted = false            // 是 Speakin 把系統靜音的，結束時只還原自己關的
    private var silentSamples = 0         // 連續幾乎沒訊號的取樣數，麥克風壞掉或被拔掉時自動停
    private var lastTap = Date.distantPast
    private var ring: [Float] = []        // 麥克風常開時，按下前最近 0.45 秒的聲音
    private var ending = false            // 放開後多收 0.25 秒尾音中
    static let maxSeconds: Double = 600   // 單次錄音上限 10 分鐘，最後 1 分鐘膠囊的秒數變橘色

    func setup() {
        Task.detached { let r = Agent.detect(); await MainActor.run { Agent.ready = r } }
        SessionLog.prune(); store.pruneHistory()
        local.killOrphans()
        hotkey.onTap = { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        hotkey.onHold = { [weak self] ev in MainActor.assumeIsolated {
            guard let self else { return }
            switch (ev, self.state) {
            case (.down, .idle): self.begin()
            case (.down, .processing): self.message = "還在整理上一段"
            case (.up, .recording): self.finish()
            case (.abort, .recording): self.cancel(quiet: true)   // 按太短或按到組合鍵
            default: break
            }
        } }
        hotkey.mode = store.settings.fnMode
        hotkey.key = store.settings.recordKey
        hotkey.onEsc = { [weak self] in MainActor.assumeIsolated { _ = self?.cancel() } }
        hotkey.onPasteLast = { [weak self] in MainActor.assumeIsolated { self?.pasteLast() } }
        lastText = store.history.last(where: { !$0.text.isEmpty })?.text ?? ""
        rec.onSamples = { [weak self] s in DispatchQueue.main.async { self?.feed(s) } }
        rec.onChange = { [weak self] in MainActor.assumeIsolated { self?.micChanged() } }
        applyMic()
        // 啟動 10 秒後查一次新版，之後每 6 小時
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in Task { await self?.checkUpdate() } }
        // 第一次用：權限交給引導畫面一頁一頁問，不要一打開就連跳兩個系統視窗
        let ask = store.settings.onboarded
        if ask { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)   // 對方 App 卡住時最多等 0.3 秒
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): ask] as CFDictionary)
        // 輔助使用權限可能晚點才開，開了就接上快捷鍵
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if AXIsProcessTrusted(), self.hotkey.start() { self.hotkeyReady = true; t.invalidate() }
            }
        }.fire()
    }

    /// 麥克風常開設定變了、或換麥克風時呼叫：開著就一直收音（只留最近 0.45 秒），關了就只在錄音時開
    func applyMic() {
        guard state == .idle else { return }
        if rec.running { rec.stop() }
        ring = []
        if store.settings.micAlwaysOn { try? rec.start(mic: store.settings.mic, avoidBluetooth: store.settings.avoidBluetooth) }
    }

    /// 系統因為裝置變動把麥克風停了：沒在錄就照設定重開，錄到一半就接著錄（已切好的段落不動）
    private func micChanged() {
        guard !rec.running else { return }
        switch state {
        case .idle: applyMic()
        case .recording:
            log.line("麥克風裝置變了，重開接著錄")
            do { try rec.start(mic: runSettings.mic, avoidBluetooth: runSettings.avoidBluetooth) } catch {
                log.line("麥克風重開失敗：\(error.localizedDescription)"); cancel(quiet: true); fail("麥克風斷了")
            }
        case .processing: break
        }
    }

    private func stopMic() { if !store.settings.micAlwaysOn { rec.stop() } }

    func checkUpdate(manual: Bool = false) async {
        if Updater.url == nil { if manual { flash("這個版本沒有設定更新來源") }; return }
        update = await Updater.newer()
        guard let n = update else { if manual { flash("已經是最新版") }; return }
        if staged == nil { staged = await Updater.stage(n) }
        flash(staged != nil ? "Speakin \(n.version) 準備好了，到選單列按「重開完成更新」" : "Speakin 有新版 \(n.version)，點選單列圖示下載")
    }

    func pasteLast() {
        guard !lastText.isEmpty else { return flash("還沒有可以貼的結果") }
        Paster.paste(lastText, keep: store.settings.keepClipboard)
    }

    func toggle() {
        guard Date().timeIntervalSince(lastTap) > 0.3 else { return }   // 連按兩下只算一次
        lastTap = Date()
        switch state {
        case .idle: begin()
        case .recording: finish()
        case .processing: message = "還在整理上一段"
        }
    }

    private func muteOthers() {
        guard runSettings.muteOthers, !SystemAudio.muted else { return }
        let my = gen
        // 等提示音播完再靜音，不然提示音也被靜掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.gen == my, self.state == .recording else { return }
            SystemAudio.muted = true; self.iMuted = true
        }
    }

    private func unmute() { if iMuted { SystemAudio.muted = false; iMuted = false } }

    enum Sound: String { case start = "Tink" }   // 只有開始響，結束、整理中、出錯都安靜
    private func play(_ x: Sound) { if store.settings.sounds { NSSound(named: x.rawValue)?.play() } }
    private func fail(_ m: String) { flash(m) }

    func notify(_ m: String) { flash(m) }

    private func flash(_ m: String) {
        message = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.message == m { self?.message = nil }
        }
    }

    private func begin() {
        app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        runSettings = store.settings
        if runSettings.model == "auto" {
            if let m = Agent.auto() { runSettings.model = m } else { runSettings.polish = false }
        }
        context = runSettings.context ? ScreenContext.aroundCursor() : ""
        screen = ""
        if runSettings.context {   // 讀整個視窗最久 1 秒，背景讀，錄音不用等；講完才潤稿，那時早就讀好了
            let my = gen + 1
            Task.detached { let s = String(ScreenContext.window().suffix(2000)); await MainActor.run { if my == self.gen { self.screen = s; self.log.text("screen.txt", s) } } }
        }
        asrError = nil
        do { try asr.ensureRunning(model: runSettings.asrModel) } catch { return fail(error.localizedDescription) }
        reset()
        log.start("開始｜App：\(app)｜潤稿：\(runSettings.polish ? runSettings.model : "關")｜畫面前文：\(context)")
        if rec.running, !ring.isEmpty {   // 麥克風常開：把按下前那一小段接上，句首不會被吃掉
            log.line(String(format: "接上按下前 %.2f 秒", Double(ring.count) / 16000))
            if let piece = seg.push(ring) { enqueue(piece) }
        }
        ring = []
        if !rec.running {
            do { try rec.start(mic: runSettings.mic, avoidBluetooth: runSettings.avoidBluetooth) } catch { log.line("麥克風打不開：\(error.localizedDescription)"); return fail("麥克風打不開") }
        }
        started = Date()
        message = nil
        play(.start)
        silentSamples = 0
        state = .recording
        muteOthers()
    }

    private func reset() {
        gen += 1
        seg = Segmenter(); pieces = []; failedParts = 0; totalParts = 0; segCount = 0; ending = false
        if runSettings.polish { preparePolish(runSettings.model) }
    }

    private func feed(_ s: [Float]) {
        guard state == .recording else {
            if state == .idle, rec.running { ring += s; if ring.count > 7200 { ring.removeFirst(ring.count - 7200) } }
            return
        }
        let level = Segmenter.rms(s[...])
        levels.removeFirst(); levels.append(Float(MicMeter.Meter.pos(level)))   // 用 dB 換算，正常講話就跳得明顯
        silentSamples = level < 0.0003 ? silentSamples + s.count : 0
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 1, silentSamples > 5 * 16000 { log.line("麥克風 5 秒沒有任何訊號，自動停止"); cancel(); return fail("麥克風沒收到聲音") }
        if elapsed >= Self.maxSeconds { log.line("到 10 分鐘上限，自動結束"); return finish() }
        startHelpers()
        if let piece = seg.push(s) { enqueue(piece) }
    }

    /// 每切出一段：馬上辨識（帶字典和上一段結尾當提示），照順序排隊。
    /// 潤稿等講完整段一次做：分段潤會在每段結尾亂加句號（「只要用一組。就可以」）。
    /// last = 按結束時剩下的那段。句尾常常講得很小聲（辦公室裡更是），不看音量一律辨識，只跳過不到 0.3 秒的；
    /// 2026-11-03 實測：被音量丟掉的 96 段裡 21 段其實有字（「就好了」「樣本」），沒字的段辨識出來是空的或「嗯」。
    private func enqueue(_ piece: [Float], last: Bool = false) {
        startHelpers()
        let n = segCount, th = seg.threshold, loud = Segmenter.loudSeconds(piece, threshold: th)
        segCount += 1
        let keep = last ? piece.count >= Segmenter.rate * 3 / 10 : loud >= 0.3
        log.audio(String(format: "seg%02d.wav", n), piece)
        log.line(String(format: "段%d：%.1f 秒，有聲音 %.1f 秒，平均音量 %.4f，門檻 %.4f", n, Double(piece.count) / 16000, loud, Segmenter.rms(piece[...]), th)
                 + (keep ? "" : " → 當成沒人講話，丟掉"))
        guard keep else { return }
        // 第一段沒有上一段可接，用游標前的字當提示，辨識才知道前面在講什麼
        let my = gen, terms = store.asrTerms, prevRaw = pieces.last, screen = context.components(separatedBy: "【游標】")[0]
            .replacingOccurrences(of: #"\[(email|金鑰|身分證|卡號|電話)\]"#, with: "", options: .regularExpression)
        let raw = Task { () -> String in
            let before = await prevRaw?.value ?? screen
            guard my == self.gen else { return "" }
            let prompt = terms + " " + String(before.suffix(40)), t = Date()
            do {
                var text = try await self.asr.transcribe(piece, prompt: prompt)
                if last, text.allSatisfy({ "嗯啊呃喔。，、 ".contains($0) }) { text = "" }   // 句尾沒講話時辨識會吐「嗯」
                self.log.line(String(format: "段%d 辨識 %.2f 秒｜提示：%@｜結果：%@", n, Date().timeIntervalSince(t), prompt, text)
                              + (self.asr.stripped > 0 ? "｜清掉怪字元 \(self.asr.stripped) 個" : ""))
                return text
            } catch {
                self.log.line("段\(n) 辨識失敗：\(error.localizedDescription)")
                self.asrError = error.localizedDescription; return ""
            }
        }
        pieces.append(raw)
    }

    /// 錄音過 20 秒，長文很可能要分塊，先多暖機 2 個 claude（暖機要幾秒，等按結束才開會來不及）
    private func startHelpers() {
        guard helpers.isEmpty, runSettings.polish, runSettings.model != "qwen", Date().timeIntervalSince(started) > 20 else { return }
        helpers = (0..<2).map { _ in let p = Polisher(); p.smooth = runSettings.smooth; p.prepare(model: runSettings.model, fresh: true); return p }
    }

    /// 段與段接起來：清單換行、英文之間補空白，其他直接接
    nonisolated static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.first?.isNumber == true && b.dropFirst().first == "." || a.last == "\n" { return a + (a.last == "\n" ? "" : "\n") + b }
        // 英文接英文、中文接英文都補空白（「用 Claude Code」）；中文接中文直接接
        if let x = a.last, let y = b.first, x.isLetter, y.isLetter, x.isASCII || y.isASCII { return a + " " + b }
        return a + b
    }

    @discardableResult func cancel(quiet: Bool = false) -> Bool {
        guard state == .recording else { return false }
        stopMic(); unmute(); ending = false
        log.audio(String(format: "seg%02d.wav", segCount), seg.flush())
        let seconds = Date().timeIntervalSince(started)
        gen += 1; pieces = []; helpers.forEach { $0.kill() }; helpers = []; state = .idle; log.line("取消")
        // 取消的也留一筆，按錯了可以到歷史紀錄重新辨識救回來
        if seconds >= 2 { store.addHistory(HistoryItem(app: app, raw: "", text: "", seconds: seconds, latency: 0, session: log.name, note: "已取消")) }
        if !quiet { flash("已取消") }
        return true
    }

    /// 等所有段落做完，回傳（辨識原文, 要貼的文字）
    private func collect() async -> (raw: String, text: String) {
        var raws: [String] = []
        for p in pieces { raws.append(await p.value) }
        let raw = raws.filter { !$0.isEmpty }.reduce("", Self.join)
        let fixed = TextFix.dropRetracted(TextFix.applyDict(raw, store.dict))
        defer { helpers.forEach { $0.kill() }; helpers = [] }
        guard runSettings.polish, !fixed.isEmpty else { return (raw, TextFix.space(fixed)) }
        // 不到 10 個字跳過潤稿：251 筆紀錄裡這種長度 93% 只改了標點，卻要多等約 1 秒
        // 口述的 email（「a at b 點 tw」）就算很短也要潤稿，才會寫回 a@b.tw
        let spokenEmail = fixed.range(of: "(?i)(\\bat\\b|小老鼠)", options: .regularExpression) != nil
        if !spokenEmail, fixed.filter({ $0.isLetter || $0.isNumber }).count < 10 { log.line("短句，不潤稿"); return (raw, TextFix.question(TextFix.space(fixed))) }
        let parts = runSettings.model == "qwen" ? [fixed] : TextFix.chunks(fixed)
        totalParts = parts.count
        let workers = [polisher] + helpers
        // 每個程式照順序處理分到的塊（同一個程式一次只能問一題），不同程式同時跑
        let done = await withTaskGroup(of: [(Int, String)].self) { g in
            for (w, p) in workers.enumerated() {
                let mine = parts.indices.filter { $0 % workers.count == w }
                guard !mine.isEmpty else { continue }
                g.addTask { @MainActor in
                    var r: [(Int, String)] = []
                    for i in mine { r.append((i, await self.polishPart(parts[i], n: i, of: parts.count, with: p))) }
                    return r
                }
            }
            return await g.reduce(into: [Int: String]()) { acc, r in for (i, t) in r { acc[i] = t } }
        }
        return (raw, TextFix.space(TextFix.joinParts(parts.indices.map { done[$0] ?? parts[$0] })))
    }

    /// 模型回來的字：拿掉【游標】和抄回來的標籤（#5）
    nonisolated static func tidy(_ s: String) -> String {
        Polisher.stripTags(s.replacingOccurrences(of: "【游標】", with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 潤一塊；沒回應或不可信就用這塊的原文，不拖累其他塊
    private func polishPart(_ text: String, n: Int, of total: Int, with p: Polisher) async -> String {
        let t = Date(), m = runSettings.model
        // 前一塊逾時被關掉的幫手，重開要等十幾秒，不如直接用原文
        if n > 0, m != "qwen", !p.alive { log.line("潤稿 第\(n + 1)/\(total)塊｜程式已關，用原文"); failedParts += 1; return text }
        var out = await (m == "qwen" ? local.polish(text, app: app, context: context, terms: store.polishTerms(for: text))
                                     : p.polish(text, app: app, context: n == 0 ? context : "", screen: screen, terms: store.polishTerms(for: text), model: m)).map(Self.tidy)
        var ok = out.map { TextFix.plausible(text, $0) } ?? false
        // 有回但改太多（摘要、漏句）再問一次，常常第二次就對
        if out != nil, !ok, m != "qwen", let again = await p.polish(text, app: app, context: "", terms: store.polishTerms(for: text), model: m).map(Self.tidy), TextFix.plausible(text, again) {
            log.line("潤稿 第\(n + 1)/\(total)塊 第一次不可信，重問一次可信")
            out = again; ok = true
        }
        log.line(String(format: "潤稿%@ %.2f 秒｜畫面 \(screen.count) 字｜可信：%@\n    送：%@\n    回：%@", total > 1 ? " 第\(n + 1)/\(total)塊" : "",
                        Date().timeIntervalSince(t), out == nil ? "沒回應" : ok ? "是" : "否", text, out ?? "nil"))
        guard ok, let good = out else { failedParts += 1; return text }
        return good
    }

    /// 放開後再收 0.25 秒：最後一個字常常還沒講完就放開了
    private func finish() {
        guard !ending else { return }
        ending = true
        let my = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.gen == my, self.state == .recording else { return }
            self.ending = false
            self.finishNow()
        }
    }

    private func finishNow() {
        stopMic()
        unmute()
        let seconds = Date().timeIntervalSince(started)
        enqueue(seg.flush(), last: true)
        state = .processing
        let t0 = Date(), app = self.app, my = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let self, self.gen == my, self.state == .processing { self.message = "比平常久，再等一下…" }
        }
        Task {
            let (raw, text) = await collect()
            message = nil
            guard !text.isEmpty else {
                log.line("結束｜沒有任何字：\(asrError ?? "每段都是空的")"); state = .idle
                if asrError != nil { store.addHistory(HistoryItem(app: app, raw: "", text: "", seconds: seconds, latency: 0, session: log.name, note: "辨識失敗")) }
                return fail(asrError == nil ? "沒聽到聲音" : "辨識失敗，再講一次")
            }
            // 潤稿失敗就安靜貼原文，歷史紀錄會標出來，不跳訊息打斷
            log.line(String(format: "結束｜錄音 %.1f 秒，按結束後等 %.2f 秒\n    原文：%@\n    貼上：%@", seconds, Date().timeIntervalSince(t0), raw, text))
            // 找不到輸入框時 Cmd+V 可能沒地方貼，結果留在剪貼簿才不會掉
            let noTarget = Learner.focused() == nil
            if !noTarget {
                Learner.watch(pasted: text, onBlind: { [weak self] in
                    guard let self else { return }
                    self.log.line("學字｜讀不到這個輸入框的字（\(app)），要改錯字請到歷史紀錄按「修正」")
                }) { [weak self] pairs in
                    guard let self else { return }
                    let added = self.store.learn(pairs)
                    guard !added.isEmpty else { return }
                    self.log.line("學字｜" + added.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、"))
                    self.flash("已加入字典：" + added.map(\.right).joined(separator: "、"))
                }
            }
            Paster.paste(text, keep: store.settings.keepClipboard || noTarget, enter: store.settings.autoEnter && !noTarget)
            lastText = text
            if noTarget { flash("已複製，按 ⌘V 貼上") }
            store.addHistory(HistoryItem(app: app, raw: raw, text: text, seconds: seconds, latency: Date().timeIntervalSince(t0), session: log.name, note: note))
            store.markHits(text)
            state = .idle
        }
    }

    /// 出問題時存進紀錄的那句話
    private var note: String? {
        failedParts == 0 ? nil : failedParts == totalParts ? "潤稿沒回應，這筆是辨識原文" : "有 \(failedParts) 段沒潤到，那幾段是原文"
    }

    /// 歷史紀錄「重新辨識」：用存下來的錄音跑一次辨識＋潤稿，結果蓋掉這筆（不貼上）
    func redo(_ h: HistoryItem) {
        let segs = SessionLog.segments(h)
        guard state == .idle, !segs.isEmpty else { return }
        runSettings = store.settings; app = h.app; context = ""; asrError = nil
        do { try asr.ensureRunning(model: runSettings.asrModel) } catch { return flash(error.localizedDescription) }
        reset()
        started = Date().addingTimeInterval(-h.seconds)   // 長錄音一樣開幫手分塊潤稿
        log.start("重新辨識｜\(h.session ?? "舊紀錄")")
        state = .processing
        let t0 = Date()
        for s in segs { enqueue(s) }
        Task {
            let (raw, text) = await collect()
            message = nil
            state = .idle
            guard !text.isEmpty else { return fail("還是沒辨識到字") }
            if let i = store.history.firstIndex(where: { $0.id == h.id }) {
                store.history[i].raw = raw; store.history[i].text = text; store.history[i].note = note
                store.history[i].session = log.name; store.history[i].latency = Date().timeIntervalSince(t0)
            }
            flash("重新辨識好了")
        }
    }

    func shutdown() { unmute(); asr.stop(); polisher.kill(); helpers.forEach { $0.kill() }; local.stop() }

    private func preparePolish(_ model: String) {
        polisher.smooth = runSettings.smooth
        if model == "qwen" { local.prepare() } else { polisher.prepare(model: model, fresh: true) }
    }


    /// `Speakin --file a.wav`：用音檔照實際講話速度跑完整流程（不貼上），印出要等多久。
    /// 不管音量，直接辨識每個 WAV，印出「檔名<TAB>結果」（調音量門檻用）
    /// 比模型用：Speakin --asr [--model x.gguf] a.wav …，每行印「檔名、秒數、結果」
    func asrFiles(_ paths: [String], model: String? = nil) async {
        do { try asr.ensureRunning(model: model ?? store.settings.asrModel) } catch { return print(error.localizedDescription) }
        for p in paths {
            guard let d = FileManager.default.contents(atPath: p), let s = Segmenter.samples(d) else { print("\(p)\t讀不到"); continue }
            let t0 = Date()
            let t: String
            do { t = try await asr.transcribe(s, prompt: store.asrTerms) } catch { t = "失敗：\(error.localizedDescription)" }
            print(String(format: "%@\t%.2f\t%@", p, Date().timeIntervalSince(t0), t))
        }
    }

    func runFile(_ path: String) async {
        guard let d = FileManager.default.contents(atPath: path), d.range(of: Data("data".utf8)) != nil else { return print("讀不到 WAV") }
        let samples = Segmenter.samples(d) ?? []
        runSettings = store.settings
        do { try asr.ensureRunning(model: runSettings.asrModel) } catch { return print(error.localizedDescription) }
        app = "TextEdit"; context = ""
        reset()
        started = Date()
        log.start("音檔：\(path)")
        for i in stride(from: 0, to: samples.count, by: 1600) {
            if let p = seg.push(Array(samples[i..<min(i + 1600, samples.count)])) { enqueue(p) }
            try? await Task.sleep(nanoseconds: 100_000_000)   // 0.1 秒 = 1600 個取樣，跟真的講話一樣快
        }
        let t0 = Date()
        enqueue(seg.flush(), last: true)
        let (raw, text) = await collect()
        print(String(format: "錄音 %.1f 秒，切成 %d 段｜按結束後等 %.2f 秒", Double(samples.count) / 16000, pieces.count, Date().timeIntervalSince(t0)))
        print("辨識：\(raw)\n結果：\(text)")
        if polishFailed { print("潤稿失敗 \(failedParts)/\(totalParts) 塊，那幾塊貼的是原文") }
        print("紀錄：\(log.path)")
        if let e = asrError { print("錯誤：\(e)") }
    }
}
