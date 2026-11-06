import AppKit
import SwiftUI
import CTranscribe

@main
struct SpeakinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // 預覽第一次的載入畫面（假下載，不連網、不動設定）：Speakin --preview-boot mobile|pixel
        // 預覽完整的第一次引導（假下載、權限按了直接下一頁、不動設定）：Speakin --preview-onboarding
        if CommandLine.arguments.contains("--preview-onboarding") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Setup.fake = true; Setup.shared.hasASR = false
                OnboardingPanel.shared.show()
                app.run()
            }
            exit(0)
        }
        // 預覽開 App 跳出的字典建議（假資料）：Speakin --preview-suggest
        #if EXPERIMENTAL
        if CommandLine.arguments.contains("--preview-suggest") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared; app.setActivationPolicy(.regular)
                let fake = [("cloud", "Claude", "錄音超過二十秒會多開兩個 cloud 程式"), ("論文", "潤稿", "潤稿被聽成論文這種比較常見的錯字"),
                            ("remi", "README", "我覺得你的 remi 寫的也很差呢"), ("mc", "MCP", "你再重新回來看一下我們的這個 mc 這個工具"),
                            ("type less", "Typeless", "跟 type less 比起來我們快多少"), ("瑞克", "Rust", "改成瑞克記憶體會更小嗎"), ("黑酷", "Haiku", "裡面大約是黑酷本身在想")]
                    .map { Suggest.Item(wrong: $0.0, right: $0.1, example: $0.2) }
                let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.title = ""
                w.contentViewController = NSHostingController(rootView: SuggestPopup(items: fake) { exit(0) })
                w.center(); w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run()
            }
            exit(0)
        }
        #endif
        // 預覽主視窗＋錄音膠囊（假音量，不錄音、不動設定）：Speakin --preview-main
        if CommandLine.arguments.contains("--preview-main") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                w.title = "Speakin"
                w.contentView = NSHostingView(rootView: MainView())
                w.center(); w.makeKeyAndOrderFront(nil)
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in exit(0) }
                let u = Speakin.shared
                if let i = CommandLine.arguments.firstIndex(of: "--preview-main"), i + 1 < CommandLine.arguments.count { u.tab = CommandLine.arguments[i + 1] }   // --preview-main 歷史紀錄
                u.state = .recording
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated { u.levels = u.levels.dropFirst() + [Float.random(in: 0...1)] }
                }
                app.activate(ignoringOtherApps: true)
                app.run()
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--preview-boot") { BootPreview.run(CommandLine.arguments.dropFirst(i + 1).first ?? "mobile") }
        // 看辨識模型支不支援塞字詞：Speakin --asrcaps a.gguf b.gguf
        if let i = CommandLine.arguments.firstIndex(of: "--asrcaps") {
            _ = transcribe_init_backends_default()
            for f in CommandLine.arguments.dropFirst(i + 1) {
                var m: OpaquePointer?
                guard transcribe_model_load_file(f, nil, &m) == TRANSCRIBE_OK else { print("\(f)：載入失敗"); continue }
                print((f as NSString).lastPathComponent, "字詞表", transcribe_model_supports(m, TRANSCRIBE_FEATURE_VOCABULARY), "前文提示", transcribe_model_supports(m, TRANSCRIBE_FEATURE_CONTEXT_PROMPT))
                transcribe_model_free(m)
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
        if CommandLine.arguments.contains("--retract") { while let l = readLine() { print(TextFix.dropRetracted(l)) }; exit(0) }   // eval 用
        if CommandLine.arguments.contains("--learnprobe") {
            // 先切到一個空白輸入框；貼上後在外面改字、按 Enter，看多久學到
            let hk = Hotkey(); _ = hk.start(); sleep(2)
            // 只准貼進 TextEdit，免得測試句貼到聊天 App
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else { print("前景不是 TextEdit，不測"); exit(1) }
            if let el = Learner.focused() {
                var r: AnyObject?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
                print("輸入框：\(r as? String ?? "?")，內容 \(Learner.value(el)?.count ?? -1) 字，前景 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            } else { print("找不到輸入框，前景 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")") }
            let t0 = Date()
            Learner.watch(pasted: "我們用 cloud floor 部署", onBlind: { print("讀不到輸入框的字"); exit(1) }) { print(String(format: "學到 %@，貼上後 %.1f 秒", "\($0)", Date().timeIntervalSince(t0))); exit(0) }
            Paster.paste("我們用 cloud floor 部署")
            RunLoop.main.run(until: Date() + 20); print("沒學到"); exit(1)
        }
        if CommandLine.arguments.contains("--axwindow") {   // 試讀前景視窗全部的字；只印統計和英文詞，不印內容
            sleep(1)
            // Speakin --axwindow 檔案 Orca：指定讀哪個 App，不指定就讀前景
            let a = CommandLine.arguments, named = a.count > a.firstIndex(of: "--axwindow")! + 2 ? a.last : nil
            let pid = named.flatMap { n in NSWorkspace.shared.runningApplications.first { $0.localizedName == n }?.processIdentifier }
            let t = Date(), text = named == nil ? ScreenContext.window() : ScreenContext.window(pid: pid)
            if let i = CommandLine.arguments.firstIndex(of: "--axwindow"), i + 1 < CommandLine.arguments.count { try? text.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8) }
            let words = Set(text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) }.map(String.init).filter { $0.count >= 3 && $0.first!.isLetter })
            print(String(format: "App：%@｜%.2f 秒｜%d 字｜英文詞 %d 個", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", Date().timeIntervalSince(t), text.count, words.count))
            print(words.sorted().prefix(40).joined(separator: " "))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snap-boot"), i + 1 < CommandLine.arguments.count {   // 兩種載入畫面，下載中＋完成各一張
            MainActor.assumeIsolated {
                for (name, done) in [("loading", false), ("done", true)] {
                    Setup.shared.hasASR = done; Setup.shared.progress = done ? nil : 0.42
                    for style in ["mini", "pill"] {
                        let sz = BootPreview.size(style)
                        let r = ImageRenderer(content: BootScreen(next: {}, style: style).frame(width: sz.width, height: sz.height).background(style == "pill" ? Color.gray.opacity(0.3) : .clear))
                        r.scale = 2
                        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                            try? b.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("boot-\(style)-\(name).png"))
                        }
                    }
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snap-onboarding"), i + 1 < CommandLine.arguments.count {   // 每一頁存成 PNG，檢查畫面用
            MainActor.assumeIsolated {
                for st in Onboarding.Step.allCases {
                    let r = ImageRenderer(content: Onboarding(step: st).padding(20).background(Color(white: 0.75)))
                    r.scale = 2
                    if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? b.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("onb-\(st.rawValue).png"))
                    }
                }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--axprobe") { sleep(3); print("讀到 \(ScreenContext.aroundCursor().count) 字"); exit(0) }
    }

    var body: some Scene {
        Window("Speakin", id: "main") { MainView() }
        MenuBarExtra { MenuContent() } label: { MenuIcon() }
    }
}

/// 錄音中換成紅點圖示，不用看螢幕下方也知道在錄
struct MenuIcon: View {
    @ObservedObject var u = Speakin.shared
    var body: some View { Image(systemName: u.state == .recording ? "record.circle.fill" : u.state == .processing ? "ellipsis.circle" : "waveform") }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var u = Speakin.shared
    @ObservedObject var store = Store.shared
    private func show(_ tab: String) { u.tab = tab; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    var body: some View {
        Text(u.hotkeyReady ? (store.settings.fnMode == .hold ? "按住 Fn 說話" : "按一下 Fn 開始說話") : "等待輔助使用權限…")
        if u.state == .recording {
            TimelineView(.periodic(from: .now, by: 1)) { c in
                let t = Int(c.date.timeIntervalSince(u.started)); Text(String(format: "錄音中 %d:%02d", t / 60, t % 60))
            }
        }
        Divider()
        // 選單關掉、焦點回到原本的 App 之後才貼
        Button("貼上上一次的結果（⌥⇧V）") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { u.pasteLast() } }
            .disabled(u.lastText.isEmpty)
        Menu("最近 5 筆（點一下複製）") {
            ForEach(store.history.filter { !$0.text.isEmpty }.suffix(5).reversed()) { h in
                Button(String(h.text.prefix(30)) + (h.text.count > 30 ? "…" : "")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.text, forType: .string)
                }
            }
        }.disabled(!store.history.contains { !$0.text.isEmpty })
        Button("復原剛學的字") { store.undoLearned() }.disabled(store.lastLearned.isEmpty)
        Divider()
        Button("首頁") { show("首頁") }
        Button("歷史紀錄") { show("歷史紀錄") }
        Button("字典") { show("字典") }
        Button("設定…") { show("設定") }.keyboardShortcut(",")
        Picker("麥克風", selection: $store.settings.mic) {
            Text("跟系統設定").tag(String?.none)
            ForEach(SystemAudio.inputs, id: \.uid) { Text($0.name).tag(Optional($0.uid)) }
        }
        Divider()
        if let n = u.update, let app = u.staged { Button("重開完成更新 \(n.version)") { Updater.install(app) } }
        else if let n = u.update { Button("有新版 \(n.version)，下載") { NSWorkspace.shared.open(n.url) } }
        if Updater.url != nil { Button("檢查更新") { Task { await u.checkUpdate(manual: true) } } }
        Text("版本 \(Updater.current)")
        Button("結束 Speakin") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)   // claude 掛掉時寫入管線不要把整個 App 拖死
        if Store.shared.settings.hideDock { NSApp.setActivationPolicy(.accessory) }
        #if EXPERIMENTAL
        if CommandLine.arguments.count == 1 { Suggest.onLaunch() }   // 一般開 App 才檢查，測試用的參數不跑
        #endif
        let args = CommandLine.arguments
        // 可以給好幾個 --file，照順序跑，用來測連續錄音
        let files = args.indices.filter { args[$0] == "--file" && $0 + 1 < args.count }.map { args[$0 + 1] }
        if let i = args.firstIndex(of: "--polish"), i + 1 < args.count {   // Speakin --polish codex：偵測各家登入，再用指定的那家潤 stdin 每一行
            Task { @MainActor in
                for a in Agent.allCases { print(a.name, a.path ?? "沒裝", a.path == nil ? "" : a.loggedIn() ? "已登入" : "沒登入") }
                let p = Polisher(); p.smooth = args.contains("--smooth")
                p.ruleOverride = args.firstIndex(of: "--rule").flatMap { try? String(contentsOfFile: args[$0 + 1], encoding: .utf8) }
                // --screen 檔案：當成畫面內容一起送，量「給畫面」有沒有幫助
                let screen = args.firstIndex(of: "--screen").flatMap { try? String(contentsOfFile: args[$0 + 1], encoding: .utf8) }.map { String($0.suffix(2000)) } ?? ""
                if args[i + 1] == "qwen" { Speakin.shared.local.prepare() } else { p.prepare(model: args[i + 1], fresh: true) }
                while let l = readLine() {
                    let t = Date()
                    let out = args[i + 1] == "qwen" ? await Speakin.shared.local.polish(l, app: "", context: "", terms: "")
                                                    : await p.polish(l, app: "", screen: screen, terms: args.contains("--dict") ? Store.shared.polishTerms(for: l) : "", model: args[i + 1])
                    print(String(format: "%.2f 秒｜%@", Date().timeIntervalSince(t), out.map(TextFix.space) ?? "nil"))
                }
                p.kill(); Speakin.shared.local.stop(); exit(0)
            }
            return
        }
        if args.contains("--download-local") {   // 用 App 的下載功能抓本機潤稿模型
            Task { @MainActor in
                // 測進度條：Speakin --download-local test 抓 50 MB 測試檔（大小不對會報下載不完整，正常）
                let test = args.last == "test"
                if !test, let why = LocalPolisher.downloadBlocker { print(why); exit(1) }
                nonisolated(unsafe) var last = -1
                do { try await LocalPolisher.download(from: test ? URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")! : LocalPolisher.modelURL) { p in let n = Int(p * 10); if n != last { last = n; print("\(n * 10)%") } }; print("完成") }
                catch { print("失敗：\(error.localizedDescription)"); exit(1) }
                exit(0)
            }
            return
        }
        if args.contains("--asr") {   // Speakin --asr a.wav b.wav …
            var files = Array(args.drop { $0 != "--asr" }.dropFirst()), model: String?
            if let i = files.firstIndex(of: "--model"), i + 1 < files.count { model = files[i + 1]; files.removeSubrange(i...i + 1) }
            Task { @MainActor in await Speakin.shared.asrFiles(files, model: model); Speakin.shared.shutdown(); exit(0) }
            return
        }
        if !files.isEmpty {
            Task { @MainActor in
                for f in files { await Speakin.shared.runFile(f) }
                Speakin.shared.shutdown(); exit(0)
            }
            return
        }
        MainActor.assumeIsolated { Speakin.shared.setup() }
    }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Speakin.shared.shutdown() }
    }
}

/// `Speakin.app/Contents/MacOS/Speakin --selftest`
enum SelfTest {
    static func run() {
        let dict = [DictEntry(term: "Notion", heardAs: ["諾訊"]), DictEntry(term: "LINE")]
        do {
            check(Updater.isNewer("0.10", than: "0.9") && !Updater.isNewer("0.2", than: "0.2") && Updater.isNewer("1.0", than: "0.9.9"), "版本號比大小")
            func mode(_ j: String) -> FnMode? { try? JSONDecoder().decode(Settings.self, from: Data(j.utf8)).fnMode }
            check(mode("{\"fnHold\":true}") == .hold && mode("{\"fnHold\":false}") == .tap && mode("{}") == .both, "舊設定的 Fn 習慣照舊，新裝的預設兩種都可以")
            var st = Settings(); st.historyDays = 0; st.fnMode = .hold; st.autoEnter = true; st.hideDock = true
            let back = try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(st))
            check(back?.historyDays == 0 && back?.fnMode == .hold && back?.autoEnter == true && back?.hideDock == true, "新設定存檔再讀回來不變")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("speakin-prune-\(UUID())")
            for n in ["2020-01-01_000000", "2999-01-01_000000", "not-a-date"] { try? FileManager.default.createDirectory(at: root.appendingPathComponent(n), withIntermediateDirectories: true) }
            SessionLog.prune(olderThan: Date(), in: root)
            check(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() == ["2999-01-01_000000", "not-a-date"], "過期的錄音資料夾刪掉，其他不動")
        }
        do {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("speakin-selftest-\(UUID()).sqlite")
            let a = HistoryItem(app: "LINE", raw: "x", text: "你好", seconds: 1, latency: 1)
            let b = HistoryItem(app: "Notion", raw: "y", text: "再見", seconds: 2, latency: 1)
            var c = b; c.text = "改過"
            DB(f).sync(old: [], new: [a, b])
            DB(f).sync(old: [a, b], new: [c])
            let got: [HistoryItem] = DB(f).all()
            check(got.map(\.text) == ["改過"] && got.first?.id == b.id, "紀錄存進資料庫、改一筆、刪一筆，重開還在")
            let d1 = DictEntry(term: "甲"), d2 = DictEntry(term: "乙")
            DB(f).sync(old: [], new: [d2, d1])
            check((DB(f).all() as [DictEntry]).map(\.term) == ["乙", "甲"], "字典存進資料庫，順序不變")
            try? FileManager.default.removeItem(at: f)
        }
        do {
            let old = Date().addingTimeInterval(-40 * 86400)
            let sleepy = DictEntry(term: "舊詞", auto: true, added: old), keep = DictEntry(term: "手動", added: old)
            check(sleepy.dormant() && !keep.dormant() && keep.weight() > sleepy.weight(), "自動學的詞 30 天沒用就休眠，手動的不會")
            var many = (0..<60).map { (i: Int) in DictEntry(term: "詞\(i)", hits: i) }
            many.append(DictEntry(term: "Zeabur"))
            let asr = Store.asrTerms(many).components(separatedBy: "、"), pol = Store.polishTerms(many, for: "我們部署到 zeabur 上").components(separatedBy: "、")
            check(asr.count == 20 && asr.first == "詞59", "辨識提示只送權重最高的 20 個")
            check(pol.count == 6 && pol.first == "Zeabur", "潤稿只送這段出現的詞加最常用的 5 個")
            let oc = [DictEntry(term: "OpenCode", heardAs: ["歐噴扣", "open code"])]
            check(Store.polishTerms(oc, for: "我用歐噴扣").hasPrefix("OpenCode（常被聽成 歐噴扣/open code）"), "潤稿提示帶常被聽成")
            let h = HistoryItem(app: "Slack", raw: "我用歐噴扣寫", text: "我用歐噴扣寫", seconds: 1, latency: 0, session: nil, note: nil)
            check(Store.matches(h, "opencode", oc) && !Store.matches(h, "Notion", oc), "搜尋正確寫法找得到聽錯的紀錄")
        }
        check(!SystemAudio.inputs.isEmpty && SystemAudio.defaultInput != nil, "找得到麥克風")
        do {
            let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("speakin-prune-\(UUID())")
            for i in 0..<4 {
                let d = root.appendingPathComponent("s\(i)")
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                try? Data(count: 300_000).write(to: d.appendingPathComponent("seg00.wav"))
                Thread.sleep(forTimeInterval: 0.02)
            }
            SessionLog.prune(limit: 1_000_000, to: 700_000, in: root)
            let left = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            try? fm.removeItem(at: root)
            check(left == ["s2", "s3"], "錄音超過上限從最舊的刪")
        }
        check(Store.newWords("\u{FEFF}Zeabur\n\"Notion\",備註\nline\n\nZeabur\n", have: ["LINE"]) == ["Zeabur", "Notion"], "字典匯入：一行一個、跳過重複和已有的")
        check(TextFix.applyDict("我們公司用諾訊 用 line 聯絡 online", dict) == "我們公司用Notion 用 LINE 聯絡 online", "字典替換")
        check(TextFix.diffPairs("我們公司用諾訊。", "我們公司用Notion。").map { "\($0.0)>\($0.1)" } == ["諾訊>Notion"], "找出修改")
        check(TextFix.diffPairs("明天開會", "好的收到").isEmpty, "整段換掉不學")
        func pairs(_ a: String, _ b: String) -> [String] { TextFix.diffPairs(a, b).map { "\($0.0)>\($0.1)" } }
        check(pairs("我們用 cloud floor 部署", "我們用 Cloudflare 部署") == ["cloud floor>Cloudflare"], "英文整個字一起學")
        check(pairs("要做電子房的部分", "要做電子版的部分") == ["電子房>電子版"], "中文單字帶上前後字")
        check(Store.looksLikeFix("電子房", "電子版") && Store.looksLikeFix("理由", "Leo") && !Store.looksLikeFix("這些字詞是", "是哪些場次"), "改寫句子不學")
        check(ASR.clean("我們\u{E305}記得\u{E116}好像\n要調整\u{E26E}吧") == "我們記得好像 要調整吧", "清掉辨識怪字元")
        check(ASR.isEcho("Notion、LINE、Claude Code", prompt: "Notion、LINE、Claude Code、Cloudflare 我們沒有要做")
              && !ASR.isEcho("LINE", prompt: "Notion、LINE、Claude Code")
              && !ASR.isEcho("我用 Claude Code 部署到 Cloudflare", prompt: "Notion、LINE、Claude Code、Cloudflare")
              && ASR.isEcho("要不要打開每日對照", prompt: "Notion 要不要打開每日對照（SHADOW）")
              && !ASR.isEcho("要不要打開", prompt: "Notion 要不要打開每日對照")
              && ASR.isEcho("cloudflare、typeless、claude 做的比較好因爲我不會手", prompt: "Cloudflare、Typeless、claude 怎麼樣做的比較好因爲我不會手")
              && !ASR.isEcho("Cloudflare 跟 Typeless 我明天再看", prompt: "Cloudflare、Typeless、claude 怎麼樣做的比較好"), "擋提示照抄")
        check(Polisher.smoothRule != Polisher.rule && Polisher.smoothRule.contains("連接字"), "理順句子模式")
        check(["LINE", "Orca", "Google Chrome", "文字編輯", "1Password", "Visual Studio Code"].map(Zone.of) == ["聊天", "程式", "瀏覽器", "文件", "其他", "程式"], "App 分區")
        check(pairs("用 view js 寫，部署到 cloud floor", "用 Vue.js 寫，部署到 Cloudflare") == ["view js>Vue.js", "cloud floor>Cloudflare"], "一次改兩處")

        var s = Segmenter(), segs: [[Float]] = []
        let tone = (0..<96000).map { Float(sin(Double($0) * 0.1) * 0.1) }
        let audio = tone + [Float](repeating: 0, count: 16000) + Array(tone.prefix(32000))
        for i in stride(from: 0, to: audio.count, by: 1600) { if let x = s.push(Array(audio[i..<min(i + 1600, audio.count)])) { segs.append(x) } }
        let rest = s.flush()
        check(segs.count == 1 && segs[0].count == 100080 && rest.count == audio.count - 100080, "停頓切段")
        check(Segmenter.hasSpeech(tone) && !Segmenter.hasSpeech([Float](repeating: 0, count: 16000)), "靜音不送")
        check(Segmenter.wav([0, 0.5]).count == 48, "WAV 檔頭")
        let old = try? JSONDecoder().decode(Settings.self, from: Data(#"{"polish":false,"model":"qwen"}"#.utf8))
        check(old?.polish == false && old?.model == "qwen" && old?.keepClipboard == false && old?.context == true, "舊設定檔相容")
        // 小聲講話：背景 0.0035、講話 0.008（實際錄音量到的大小）
        let hum = (0..<16000).map { Float(sin(Double($0) * 0.7) * 0.0035 * 1.414) }
        let soft = (0..<16000).map { Float(sin(Double($0) * 0.1) * 0.008 * 1.414) }
        var q = Segmenter()
        for i in stride(from: 0, to: 64000, by: 1600) { _ = q.push(Array((hum + hum + hum + hum)[i..<i + 1600])) }
        check(q.threshold > 0.0035 && q.threshold < 0.008 && Segmenter.hasSpeech(soft, threshold: q.threshold)
              && !Segmenter.hasSpeech(hum, threshold: q.threshold), "小聲講話不丟")
        check(TextFix.mask("寄到 abc@example.com 或打 0912 345 678，身分證 A123456789，卡號 4111-1111-1111-1111，key sk-abcdefghijklmnop")
              == "寄到 [email] 或打 [電話]，身分證 [身分證]，卡號 [卡號]，key [金鑰]", "遮個資")
        check(TextFix.mask("報名費 1500 元，名額 120 人，2026 年 12 月") == "報名費 1500 元，名額 120 人，2026 年 12 月", "一般數字不遮")
        check(Speakin.join("我們四點開會。", "這週要做三件事：") == "我們四點開會。這週要做三件事：" && Speakin.join("三件事：", "1. 改簡報") == "三件事：\n1. 改簡報"
              && Speakin.join("部署到 Cloudflare", "Workers") == "部署到 Cloudflare Workers"
              && Speakin.join("我昨天用", "Claude Code") == "我昨天用 Claude Code" && Speakin.join("好的", "謝謝") == "好的謝謝", "段落接合")
        check(TextFix.plausible("我們三點開會不對是四點開會", "我們四點開會。")
              && TextFix.plausible("嗯那個就是我想說明天的會議可能要延後一點", "我想說，明天的會議可能要延後一點。")
              && TextFix.plausible("那是十月二十九號的營運會議。", "那是 10 月 29 號的營運會議。")
              && TextFix.plausible("那是十月二十九號的營運會議。", "那是 10/29 的營運會議。")
              && !TextFix.plausible("幫我寫一封信給老闆說我明天請假", "抱歉，根據規則，我無法處理包含請求或問題的內容。請提供純粹的對話內容。")
              && !TextFix.plausible("我昨天用 Claude Code 寫了一個 API", "我昨天用 Notion、LINE、Claude Code、Cloudflare。Claude Code 寫了一個 API")
              && !TextFix.plausible("幫我寫一封信給老闆說我明天請假", "主管您好：我明天需要請假一天，特此告知，謝謝。"), "潤稿把關")
        let long = String(repeating: "我們今天要討論官網改版的進度跟報名表單的問題 ", count: 7) + "然後電子報 Cloudflare 下週要發所以要先確認" + String(repeating: "但是預算還沒批下來要再等一下老闆回覆 ", count: 8)
        let parts = TextFix.chunks(long)
        check(TextFix.chunks("短短一句") == ["短短一句"] && parts.count > 1 && parts.allSatisfy { $0.count <= 150 }
              && parts.joined().filter { $0 != " " } == long.filter { $0 != " " }
              && !parts.contains { $0.hasPrefix("loudflare") || $0.hasSuffix("C") }
              && TextFix.chunks(String(repeating: "我們要討論電子報的寄送時程，", count: 30)).allSatisfy { $0.hasPrefix("我們") }, "長文分塊不掉字")
        check(TextFix.chunks(String(repeating: "我們要討論電子報的寄送時程，剛剛那句不要，", count: 12)).allSatisfy { !$0.hasPrefix("剛剛") }, "不在改口前面切塊")
        check(TextFix.joinParts(["第一句。", "第二句。"]) == "第一句。第二句。"
              && TextFix.joinParts([String(repeating: "字", count: 150), "下一句。"]) == String(repeating: "字", count: 150) + "\n\n下一句。"
              && TextFix.joinParts(["我想問：", "1. A\n2. B", "好。"]) == "我想問：\n\n1. A\n2. B\n\n好。", "分塊接回去")
        // 0x100000 = ⌘ 有按；0x10 = 右邊、0x08 = 左邊
        check(RecordKey.rightCommand.isDown(CGEventFlags(rawValue: 0x100010)) && !RecordKey.rightCommand.isDown(CGEventFlags(rawValue: 0x100008))
              && RecordKey.fn.isDown(.maskSecondaryFn) && !RecordKey.rightOption.isDown(CGEventFlags(rawValue: 0x80020)), "錄音鍵分得出左右")
        check(TextFix.question("你懂我說的嗎") == "你懂我說的嗎？" && TextFix.question("剛剛的蘋果風呢") == "剛剛的蘋果風呢"
              && TextFix.question("好了。") == "好了。", "短句補問號")
        check(TextFix.applyDict("用 cloudflare 跟 cloud code", [DictEntry(term: "claude", heardAs: ["Cloudflare"]), DictEntry(term: "Cloudflare", heardAs: []), DictEntry(term: "Claude Code", heardAs: ["cloud code"])])
              == "用 Cloudflare 跟 Claude Code"
              && !Store.polishTerms([DictEntry(term: "claude", heardAs: ["Cloudflare"]), DictEntry(term: "Cloudflare", heardAs: [])], for: "cloudflare").contains("常被聽成"), "常被聽成是另一個字典詞時不換")
        check(TextFix.plausible("下班幫我買牛奶跟吐司喔吐司不用了家裡還有", "下班幫我買牛奶。")
              && !TextFix.plausible("下班幫我買牛奶跟吐司家裡還有一些蛋", "下班幫我買牛奶。"), "收回的話可以刪、一般的話不能刪")
        check(TextFix.space("Cloudflare 原始嘛aid one d1那邊有20%的人用Claude Code，第3點") == "Cloudflare 原始嘛 aid one d1 那邊有 20% 的人用 Claude Code，第 3 點"
              && TextFix.space("9:20 到 9:40，好。") == "9:20 到 9:40，好。", "中英之間補空白")
        let cases = [
            ("這週我會先把簡報做完然後下週請你幫我看一下文案剛剛那句不要我們週五開會討論就好", "這週我會先把簡報做完我們週五開會討論就好"),
            ("明天我先去銀行辦事然後下午幫我訂高鐵票剛剛那句不要中午我們一起吃飯", "明天我先去銀行辦事中午我們一起吃飯"),
            ("你先把合約寄給客戶然後順便抄送給法務這句刪掉寄完跟我說一聲", "你先把合約寄給客戶寄完跟我說一聲"),
            ("老師好我想請假一天因為家裡有事算了這句刪掉我想請假一天下週一回來上課", "老師好我想請假一天我想請假一天下週一回來上課"),
            ("報告明天交 順便附上數據 剛剛那句不要 記得約客戶", "報告明天交 記得約客戶"),
            ("幫我寫信給王總這句刪掉", ""),
            ("他說剛剛那句話很重要", "他說剛剛那句話很重要"),
            ("講者會說欸剛剛那句不要這種話的時候要能處理", "講者會說欸剛剛那句不要這種話的時候要能處理"),
        ]
        let bad = cases.filter { TextFix.dropRetracted($0.0) != $0.1 }
        bad.forEach { print("   ", TextFix.dropRetracted($0.0)) }
        check(bad.isEmpty, "「剛剛那句不要」刪對那一句")
        check(Polisher.message("把它做到", app: "Orca", context: "", terms: "").contains("<情境>程式</情境>")
              && !Polisher.message("把它做到", app: "Orca", context: "", terms: "").contains("Orca"), "不傳 App 名字")
        print("全部通過")
    }

    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "OK  \(name)" : "FAIL \(name)")
        if !ok { exit(1) }
    }
}

