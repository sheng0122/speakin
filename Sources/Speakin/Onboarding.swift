import SwiftUI
import AVFoundation

/// 第一次用的準備狀態：模型下載（一打開就在背景開始）、兩個權限。引導畫面和首頁的「開始前」共用。
@MainActor final class Setup: ObservableObject {
    static let shared = Setup()
    @Published var hasASR = ModelFile.hasASR
    @Published var progress: Double?   // 下載中 0～1
    @Published var error: String?
    @Published var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var stalled = false     // 30 秒沒進度
    private var lastMove = Date()

    init() {
        // 權限在系統設定裡開，開完不會通知 App，只能定時看
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ok = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if ok != self.micOK { self.micOK = ok }
                if self.progress != nil, Date().timeIntervalSince(self.lastMove) > 30, !self.stalled { self.stalled = true }
            }
        }
    }

    var blocker: String? { hasASR || Setup.fake ? nil : ModelFile.freeSpaceBlocker(ModelFile.asrSize) }

    func download() {
        guard !hasASR, progress == nil, blocker == nil else { return }
        progress = 0; error = nil; stalled = false; lastMove = Date()
        if Setup.fake { fakeDownload(); return }
        Task {
            do {
                try await ModelFile.download(ModelFile.asrURL, size: ModelFile.asrSize, to: ModelFile.asrPath) { p in
                    Task { @MainActor in
                        if p > (self.progress ?? 0) + 0.001 { self.lastMove = Date(); self.stalled = false }
                        self.progress = p
                    }
                }
                Store.shared.settings.asrModel = ModelFile.asrPath
                hasASR = true
            } catch { self.error = error.localizedDescription }
            progress = nil
        }
    }

    /// 預覽載入畫面用：不連網，30 秒假裝下載完，不寫任何檔案
    static var fake = false
    private func fakeDownload() {
        Task {
            for i in 1...300 { try? await Task.sleep(for: .milliseconds(100)); progress = min(1, Double(i) / 300 * 1.0) }
            try? await Task.sleep(for: .seconds(1.5))   // 停在「初始化中」一下
            hasASR = true; progress = nil
        }
    }

    func askMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    }

    func askAX() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// 第一次打開的引導：浮在桌面上的黑色面板，跟錄音膠囊同一個樣子。
/// 先是一條膠囊下載模型，下載好自動長大成卡片，一頁做一件事；走完才打開主視窗。
@MainActor final class OnboardingPanel {
    static let shared = OnboardingPanel()
    private var panel: NSPanel?
    weak var mainWindow: NSWindow?

    /// 無邊框的視窗預設不能打字，試講那頁要能點輸入框
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func show() {
        guard panel == nil else { return }
        let size = Onboarding.Step.model.size
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating; p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: Onboarding(resize: { [weak self] in self?.resize($0) }, finish: { [weak self] in self?.finish() }))
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    /// 以中心點為準長大／縮小
    private func resize(_ s: NSSize) {
        guard let p = panel, p.frame.size != s else { return }
        let r = NSRect(x: p.frame.midX - s.width / 2, y: p.frame.midY - s.height / 2, width: s.width, height: s.height)
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.35; c.timingFunction = .init(name: .easeInEaseOut); p.animator().setFrame(r, display: true) }
    }

    private func finish() {
        if Setup.fake { exit(0) }   // 預覽：不動設定
        Store.shared.settings.onboarded = true
        panel?.orderOut(nil); panel = nil
        mainWindow?.center(); mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 拿到 SwiftUI 視窗本身：引導還沒走完時先把主視窗藏起來
struct WindowAccess: NSViewRepresentable {
    let got: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { got(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// 引導的每一頁。黑底、白字、App 的橘色，跟錄音膠囊同一套
struct Onboarding: View {
    var resize: (NSSize) -> Void = { _ in }
    var finish: () -> Void = {}
    @ObservedObject var setup = Setup.shared
    @ObservedObject var u = Speakin.shared
    @ObservedObject var store = Store.shared
    enum Step: Int, CaseIterable {
        case model, welcome, mic, ax, fnkey, practice, done
        var size: NSSize { self == .model ? NSSize(width: 300, height: 48) : self == .practice ? NSSize(width: 420, height: 360) : NSSize(width: 360, height: self == .done ? 260 : 220) }
    }
    @State private var step: Step
    init(step: Step = .model, resize: @escaping (NSSize) -> Void = { _ in }, finish: @escaping () -> Void = {}) {
        _step = State(initialValue: step); self.resize = resize; self.finish = finish
    }
    @State private var said = ""
    @State private var heard = ""      // 辨識出來的原話，跟潤完的對照
    @State private var startCount = 0
    @State private var trial = 0       // 體驗到第幾個模式
    @State private var keepSmooth = false
    @State private var oldSmooth: Bool?

    /// 試講的三種模式：照唸這句，看 Speakin 怎麼整理
    static let trials: [(name: String, say: String, smooth: Bool)] = [
        ("去贅字", "呃，我覺得那個，明天的會，嗯，改到下午比較好", false),
        ("列點", "明天要做三件事，回信、改簡報，還有訂餐廳", false),
        ("理順", "然後就是那個報告，我覺得就是要再改一下，對，數字的部分", true),
    ]

    var body: some View {
        Group {
            if step == .model {
                PillBoot { go(.welcome) }
            } else {
                card
            }
        }
        .frame(width: step.size.width, height: step.size.height)
        .onChange(of: setup.hasASR) { _, ok in   // 下載好自動往下，不用按
            if ok, step == .model { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { go(.welcome) } }
        }
        .onChange(of: setup.micOK) { _, ok in if ok, step == .mic { go(.ax) } }
        .onChange(of: u.hotkeyReady) { _, ok in if ok, step == .ax { go(.fnkey) } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            if step == .fnkey, rivals.isEmpty { go(.practice) }   // 搶 Fn 的 App 關掉了就往下
        }
        .onChange(of: store.history.count) { _, n in
            guard step == .practice, n > startCount, let h = store.history.last, !h.text.isEmpty else { return }
            said = h.text; heard = h.raw
            // 前兩個看完結果自動換下一個；理順那個要給時間勾「以後都用」
            let now = trial
            if !Self.trials[now].smooth { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if trial == now, step == .practice { nextTrial() } } }
        }
    }

    private func go(_ s: Step) {
        // 已經好的步驟直接跳過
        var s = s
        if s == .mic, setup.micOK, !Setup.fake { s = .ax }
        if s == .ax, u.hotkeyReady, !Setup.fake { s = .fnkey }
        if s == .fnkey, rivals.isEmpty, !Setup.fake { s = .practice }
        if s == .practice { startTrial(0) }
        if s != .practice { endSmoothTrial() }
        resize(s.size)
        withAnimation(.easeInOut(duration: 0.3)) { step = s }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {   // 上面的小點：走到哪亮到哪
                ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? brand : .white.opacity(0.18)).frame(width: s == step ? 18 : 6, height: 6)
                }
            }.padding(.top, 18)
            Spacer(minLength: 0)
            Group {
                switch step {
                case .model, .welcome: welcome
                case .mic: mic
                case .ax: ax
                case .fnkey: fnkey
                case .practice: practice
                case .done: done
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    private func page(_ title: String, _ body: String, @ViewBuilder _ extra: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 20, weight: .semibold))
            if !body.isEmpty {
                Text(body).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            extra()
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 7).background(Capsule().fill(brand))
        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).padding(.top, 4)
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
    }

    private var welcome: some View {
        page("用講的，取代打字", "按 Fn 開始講，再按一次結束") {
            primary("開始設定") { go(.mic) }
        }
    }

    /// 也會搶 Fn 鍵的語音輸入 App
    private var rivals: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { ["Typeless", "Wispr Flow", "Superwhisper", "Aqua Voice"].contains($0.localizedName ?? "") }
    }

    private var fnkey: some View {
        let names = rivals.compactMap(\.localizedName)
        return page("關掉 " + (names.isEmpty ? "Typeless" : names.joined(separator: "、")), "") {
            primary("關掉") { if Setup.fake { go(.practice) } else { rivals.forEach { $0.terminate() } } }
        }
    }

    private var mic: some View {
        page("開啟麥克風", "") {
            primary("開啟") { Setup.fake ? go(.ax) : setup.askMic() }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { hint("到系統設定的「麥克風」打開 Speakin") }
        }
    }

    private var ax: some View {
        page("開啟輔助使用", "") {
            primary("開啟") { Setup.fake ? go(.fnkey) : setup.askAX() }
        }
    }

    private func startTrial(_ i: Int) {
        trial = i; said = ""; heard = ""; startCount = store.history.count
        // 理順那一個暫時打開理順模式，離開時還原（除非勾了「以後都用」）
        if Self.trials[i].smooth { if oldSmooth == nil { oldSmooth = store.settings.smooth }; store.settings.smooth = true } else { endSmoothTrial() }
    }

    private func endSmoothTrial() {
        guard let old = oldSmooth else { return }
        store.settings.smooth = keepSmooth || old; oldSmooth = nil
    }

    private func nextTrial() { trial + 1 < Self.trials.count ? startTrial(trial + 1) : go(.done) }

    private var practice: some View {
        let t = Self.trials[trial]
        return VStack(spacing: 14) {
            HStack(spacing: 8) {   // 三種模式，做過的打勾
                ForEach(Self.trials.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        if i < trial { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        Text(Self.trials[i].name)
                    }
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(i == trial ? brand : .white.opacity(i < trial ? 0.15 : 0.06)))
                    .foregroundStyle(.white.opacity(i <= trial ? 1 : 0.4))
                }
            }
            if !setup.hasASR {
                PillBoot(next: {}).frame(height: 48)
            } else {
                VStack(spacing: 6) {
                    Text("按 Fn，照著唸").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Text("「\(t.say)」").font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                PracticeBox(text: said).id(trial)
                if !heard.isEmpty {
                    Text("你說的：" + heard).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if Agent.auto() == nil, !Setup.fake { hint("還沒設定潤稿（登入 Claude Code 或下載本機模型），只會貼原話") }
            HStack(spacing: 16) {
                if t.smooth, !said.isEmpty { Toggle("以後都用理順", isOn: $keepSmooth).toggleStyle(.checkbox) }
                Spacer()
                Button("跳出表情符號？") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                    .help("把「按下 🌐 鍵時」改成「不執行任何動作」")
                Button(said.isEmpty ? "略過" : (trial + 1 < Self.trials.count ? "下一個" : "完成"), action: nextTrial)
                    .foregroundStyle(said.isEmpty ? .white.opacity(0.45) : brand)
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var done: some View {
        page("準備好了", "") {
            VStack(alignment: .leading, spacing: 8) {
                Tip("fn", "開始／結束")
                Tip("esc", "取消")
            }
            primary("開始使用", finish)
        }
    }
}

struct Tip: View {
    let key: String, text: String
    init(_ k: String, _ t: String) { key = k; text = t }
    var body: some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12))).frame(width: 56, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// 練習用的輸入框：Speakin 貼進來的字會出現在這裡
struct PracticeBox: View {
    let text: String
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $draft)
            .font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? brand : .white.opacity(0.15), lineWidth: focused ? 1.5 : 1))
            .focused($focused)
            .onAppear { focused = true }
    }
}

/// 歡迎頁的動畫：Fn 鍵帽被按下、上面的聲波跟著跳（跟 App 圖示同一個造型）
struct FnKeyAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.animation(paused: still)) { c in
            let time = still ? 0.6 : c.date.timeIntervalSinceReferenceDate
            let press = (sin(time * 2.2) + 1) / 2   // 0～1，鍵帽一上一下
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.75)).frame(width: 110, height: 110).offset(y: 8)
                RoundedRectangle(cornerRadius: 22).fill(.white).frame(width: 110, height: 106)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .offset(y: press * 5)
                Text("fn").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(white: 0.1)).offset(x: 16, y: 12 + press * 5)
                HStack(spacing: 7) {
                    ForEach(0..<4) { i in
                        Capsule().fill(Color(red: 0.91, green: 0.33, blue: 0.17))
                            .frame(width: 9, height: 12 + 30 * CGFloat(press) * CGFloat(abs(sin(time * 5 + Double(i) * 1.3))))
                    }
                }.frame(width: 110, height: 106).offset(y: 10 + press * 5)
            }
            .frame(width: 110, height: 118)
        }
        .accessibilityLabel("按下 Fn 鍵開始說話的示意動畫")
    }
}

/// 模型載入動畫：聲波從左到右一格一格亮起來，亮的會跳；下面寫進度、大小、還要多久
struct ModelLoading: View {
    @ObservedObject var setup = Setup.shared
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var since: (Date, Double)?   // 開始量速度的時間和進度，算剩幾分鐘用
    private let bars = 28
    private let orange = Color(red: 0.91, green: 0.33, blue: 0.17)

    var body: some View {
        let p = setup.hasASR ? 1 : (setup.progress ?? 0)
        VStack(spacing: 14) {
            TimelineView(.animation(paused: still)) { c in
                let t = still ? 0 : c.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<bars, id: \.self) { i in
                        let lit = Double(i) < p * Double(bars)
                        let wave = abs(sin(t * 3 + Double(i) * 0.45))
                        Capsule().fill(lit ? orange : Color.secondary.opacity(0.2))
                            .frame(width: 7, height: lit ? 12 + (setup.hasASR ? 18 : 38) * wave : 8)
                    }
                }.frame(height: 56)
            }
            .animation(.easeOut(duration: 0.4), value: p)
            Text(status(p)).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(setup.error != nil ? .red : .secondary)
            if setup.error != nil { Button("重試") { setup.download() }.controlSize(.small) }
        }
        .onAppear { setup.download() }
        .onChange(of: setup.progress) { _, v in if let v, since == nil, v > 0 { since = (Date(), v) } }
    }

    private func status(_ p: Double) -> String {
        if setup.hasASR { return "✓ 辨識模型準備好了" }
        if let e = setup.error { return "下載失敗：\(e)" }
        if let why = setup.blocker { return why }
        if p >= 0.999 { return "初始化中…" }
        let gb = { (x: Double) in String(format: "%.2f", x * Double(ModelFile.asrSize) / 1e9) }
        var s = String(format: "下載中 %.0f%%　", p * 100) + gb(p) + " / " + gb(1) + " GB"
        if setup.stalled { s += "\n網路好像卡住了，等一下會繼續" }
        else if let (t0, p0) = since, Date().timeIntervalSince(t0) > 5, p > p0 {
            let left = Date().timeIntervalSince(t0) / (p - p0) * (1 - p)
            s += left < 60 ? "\n剩不到 1 分鐘" : "\n大約還要 \(Int(left / 60) + 1) 分鐘"
        }
        return s
    }
}
