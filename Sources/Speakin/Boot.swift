import AppKit
import SwiftUI

/// 第一次打開、等辨識模型下載的載入畫面。兩種風格還在比：mobile（手遊開場）、pixel（像素小遊戲）
/// 選風格：defaults write <bundle id> bootStyle pixel
struct BootScreen: View {
    let next: () -> Void
    var style = UserDefaults.standard.string(forKey: "bootStyle") ?? "clean"
    var body: some View {
        switch style {
        case "pixel": PixelBoot(next: next)
        case "mobile": MobileBoot(next: next)
        case "wave": WaveBoot(next: next)
        case "mini": MiniBoot(next: next)
        case "pill": PillBoot(next: next)
        default: CleanBoot(next: next)
        }
    }
}

/// 兩種畫面共用：進度、狀態文字、剩餘時間、小技巧
@MainActor final class BootState: ObservableObject {
    let setup = Setup.shared
    @Published var slow = false
    @Published var tip = 0
    private var since: (Date, Double)?
    static let tips = [
        "按一下 Fn 開始說話，講完再按一下",
        "也可以按住 Fn 講，放開就結束",
        "按 ⇧ Fn：這次直接貼原話，不潤稿",
        "講到一半想重來？按 esc 取消",
        "⌥⇧V：再貼一次上一句",
        "辨識在你的電腦上跑，聲音不會上傳",
    ]
    var done: Bool { setup.hasASR }
    var p: Double { done ? 1 : (setup.progress ?? 0) }
    var initializing: Bool { !done && p >= 0.999 }
    var problem: String? { setup.error.map { "下載失敗：\($0)" } ?? (done ? nil : setup.blocker) }

    func start() {
        setup.download()
        Task { try? await Task.sleep(for: .seconds(20)); slow = true }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeInOut(duration: 0.5)) { tip = (tip + 1) % Self.tips.count }
            }
        }
    }

    /// 0.71 / 1.69 GB
    var sizeText: String {
        let gb = { (x: Double) in String(format: "%.2f", x * Double(ModelFile.asrSize) / 1e9) }
        return gb(p) + " / " + gb(1) + " GB"
    }

    /// 大約還要 3 分鐘；量不出來就空字串
    var eta: String {
        if setup.stalled { return "網路好像卡住了，等一下會繼續" }
        if since == nil, p > 0 { since = (Date(), p) }
        guard let (t0, p0) = since, Date().timeIntervalSince(t0) > 5, p > p0, !initializing else { return "" }
        let left = Date().timeIntervalSince(t0) / (p - p0) * (1 - p)
        return left < 60 ? "剩不到 1 分鐘" : "大約還要 \(Int(left / 60) + 1) 分鐘"
    }
}

// MARK: - 手遊開場風：滿版主視覺、星空、光束、大標題，最下面一條細長進度條，完成後「點一下任何地方開始」

struct MobileBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()
    @Environment(\.accessibilityReduceMotion) private var still
    private let orange = Color(red: 1.0, green: 0.45, blue: 0.20)
    private let pink = Color(red: 0.96, green: 0.28, blue: 0.58)
    private let gold = Color(red: 1.0, green: 0.82, blue: 0.40)

    var body: some View {
        TimelineView(.animation(paused: still)) { c in
            let t = still ? 0 : c.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.04, blue: 0.14), Color(red: 0.20, green: 0.05, blue: 0.28), Color(red: 0.45, green: 0.10, blue: 0.25)], startPoint: .top, endPoint: .bottom)
                stars(t)
                Color.clear.overlay(rays(t).offset(y: -70))   // 光束比畫面大，放 overlay 才不會把下面的進度條擠出去
                VStack(spacing: 18) {
                    emblem(t)
                    Text("SPEAKIN")
                        .font(.system(size: 56, weight: .black, design: .rounded)).tracking(10)
                        .foregroundStyle(LinearGradient(colors: [.white, gold], startPoint: .top, endPoint: .bottom))
                        .shadow(color: orange.opacity(0.8), radius: 18)
                    Text("用講的，取代打字").font(.system(size: 15, weight: .semibold)).tracking(6).foregroundStyle(.white.opacity(0.75))
                }.offset(y: -60)
                VStack { Spacer(); bottom(t) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if b.done { next() } }
        }
        .background(Button("", action: next).keyboardShortcut(.defaultAction).disabled(!b.done).opacity(0))
        .onAppear { b.start() }
    }

    /// 往上飄、會閃的星星（位置固定亂數，每次打開都一樣）
    private func stars(_ t: Double) -> some View {
        Canvas { ctx, size in
            for i in 0..<90 {
                let seed = Double(i) * 12.9898
                let x = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude * size.width
                let y0 = (sin(seed * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1).magnitude
                let speed = 0.004 + 0.012 * y0
                let y = (1 - (y0 + t * speed).truncatingRemainder(dividingBy: 1)) * size.height
                let r = 0.6 + 1.6 * y0
                let a = 0.25 + 0.6 * abs(sin(t * (0.8 + y0) + seed))
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(a)))
            }
        }
    }

    /// 主視覺後面慢慢轉的光束
    private func rays(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                Rectangle()
                    .fill(LinearGradient(colors: [orange.opacity(0.22), .clear], startPoint: .bottom, endPoint: .top))
                    .frame(width: 34, height: 360).offset(y: -180)
                    .rotationEffect(.degrees(Double(i) * 30 + t * 6))
            }
        }
        .frame(width: 760, height: 760)   // 先撐開，遮罩才不會只剩一條
        .blur(radius: 6)
        .mask(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 20, endRadius: 320))
    }

    /// 跳動的聲波徽章（跟 App 圖示同一個造型）
    private func emblem(_ t: Double) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { i in
                let h = b.done ? [40, 70, 100, 70, 40][i] : 30 + 70 * abs(sin(t * 3.2 + Double(i) * 0.9))
                Capsule().fill(LinearGradient(colors: [gold, orange, pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: CGFloat(h))
            }
        }
        .frame(height: 110)
        .shadow(color: orange.opacity(0.9), radius: 20)
        .animation(.spring(duration: 0.5), value: b.done)
    }

    private func bottom(_ t: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if b.done {
                Text("點一下任何地方開始")
                    .font(.system(size: 20, weight: .bold)).tracking(4).foregroundStyle(.white)
                    .opacity(0.45 + 0.55 * abs(sin(t * 2.2)))
                    .shadow(color: gold.opacity(0.8), radius: 10)
                    .frame(maxWidth: .infinity).padding(.bottom, 14)
            } else {
                HStack(spacing: 8) {
                    Text("提示").font(.caption.weight(.heavy)).foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(gold))
                    Text(BootState.tips[b.tip]).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).id(b.tip).transition(.opacity)
                }
            }
            HStack {
                Text(b.problem ?? (b.done ? "資源載入完成" : b.initializing ? "初始化中…" : "正在下載資源…　\(b.sizeText)　\(b.eta)"))
                    .foregroundStyle(b.problem == nil ? .white.opacity(0.75) : .red)
                Spacer()
                Text(String(format: "%.0f%%", b.p * 100)).foregroundStyle(.white).bold()
            }.font(.system(size: 12, design: .rounded)).monospacedDigit()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(LinearGradient(colors: [orange, pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, g.size.width * b.p))
                        .overlay(   // 掃過去的亮光
                            LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 60).offset(x: (t * 120).truncatingRemainder(dividingBy: max(60, g.size.width * b.p + 60)) - 60)
                                .mask(Capsule()), alignment: .leading)
                        .clipShape(Capsule())
                        .shadow(color: pink.opacity(0.8), radius: 6)
                }
            }.frame(height: 6)
            HStack {
                if !b.done, b.slow || b.problem != nil {
                    Button("先去開權限，下載會在背景繼續", action: next).buttonStyle(.plain).underline()
                }
                if setup.error != nil { Button("重試") { setup.download() }.buttonStyle(.plain).underline() }
                Spacer()
                Text("Speakin " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v" + $0 } ?? ""))
            }.font(.caption2).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 32).padding(.bottom, 18)
    }
}

// MARK: - 像素小遊戲風：像素字、一格一格的進度條、麥克風小人在上面跑，跑到底「STAGE CLEAR」

struct PixelBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()
    @Environment(\.accessibilityReduceMotion) private var still
    private let bg = Color(red: 0.08, green: 0.07, blue: 0.20)
    private let orange = Color(red: 1.0, green: 0.50, blue: 0.20)
    private let green = Color(red: 0.40, green: 0.95, blue: 0.45)
    private let yellow = Color(red: 1.0, green: 0.88, blue: 0.30)
    private let blocks = 20

    private func px(_ size: CGFloat) -> Font { .custom("Silom", size: size) }

    var body: some View {
        TimelineView(.animation(paused: still)) { c in
            let t = still ? 0 : c.date.timeIntervalSinceReferenceDate
            ZStack {
                bg
                stars(t)
                VStack(spacing: 26) {
                    if b.done {
                        Text("STAGE CLEAR!").font(px(44)).foregroundStyle(yellow)
                            .shadow(color: orange, radius: 0, x: 4, y: 4)
                            .scaleEffect(1 + 0.04 * sin(t * 6))
                    } else {
                        Text("LOADING" + String(repeating: ".", count: Int(t * 2) % 4))
                            .font(px(40)).foregroundStyle(.white).shadow(color: orange, radius: 0, x: 4, y: 4)
                            .frame(width: 360, alignment: .leading)
                    }
                    bar(t)
                    HStack {
                        Text(b.problem ?? (b.done ? "辨識模型準備好了" : b.initializing ? "初始化中…" : "下載辨識模型　\(b.sizeText)"))
                            .foregroundStyle(b.problem == nil ? .white.opacity(0.8) : .red)
                        Spacer()
                        Text(String(format: "%3.0f%%", b.p * 100)).font(px(16)).foregroundStyle(green)
                    }.font(.system(size: 13, design: .monospaced)).frame(width: 460)
                    if !b.eta.isEmpty { Text(b.eta).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }
                    if b.done {
                        Text("▶ PRESS ENTER").font(px(22)).foregroundStyle(.white).opacity(Int(t * 2.5) % 2 == 0 ? 1 : 0.15)
                    } else {
                        dialog(t)
                    }
                    if !b.done, b.slow || b.problem != nil {
                        Button("先去開權限，下載會在背景繼續", action: next).buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.5)).underline()
                    }
                    if setup.error != nil { Button("重試") { setup.download() }.buttonStyle(.plain).font(px(14)).foregroundStyle(yellow) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if b.done { next() } }
        }
        .background(Button("", action: next).keyboardShortcut(.defaultAction).disabled(!b.done).opacity(0))
        .onAppear { b.start() }
    }

    /// 方塊星星，一閃一閃
    private func stars(_ t: Double) -> some View {
        Canvas { ctx, size in
            for i in 0..<50 {
                let seed = Double(i) * 7.31
                let x = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude * size.width
                let y = (sin(seed * 2.3) * 12543.123).truncatingRemainder(dividingBy: 1).magnitude * size.height
                guard Int(t * 2 + seed) % 3 != 0 else { continue }
                let s: CGFloat = i % 5 == 0 ? 4 : 2
                ctx.fill(Path(CGRect(x: (x / 4).rounded() * 4, y: (y / 4).rounded() * 4, width: s, height: s)), with: .color(.white.opacity(0.7)))
            }
        }
    }

    /// 一格一格的進度條，小人站在最前面那格上面跑
    private func bar(_ t: Double) -> some View {
        let lit = Int(b.p * Double(blocks))
        let cell: CGFloat = 20, gap: CGFloat = 3
        let width = CGFloat(blocks) * (cell + gap) - gap
        return VStack(alignment: .leading, spacing: 4) {
            Sprite(frame: b.done ? 2 : Int(t * 8) % 2, scale: 4)
                .offset(x: min(width - 40, max(0, CGFloat(lit) * (cell + gap) - 20)), y: b.done ? -6 * abs(sin(t * 6)) : (Int(t * 8) % 2 == 0 ? 0 : -3))
                .animation(.linear(duration: 0.3), value: lit)
            HStack(spacing: gap) {
                ForEach(0..<blocks, id: \.self) { i in
                    Rectangle().fill(i < lit ? (i == lit - 1 && !b.done && Int(t * 4) % 2 == 0 ? yellow : green) : Color.white.opacity(0.08)).frame(width: cell, height: cell)
                }
            }
            .padding(6)
            .overlay(Rectangle().stroke(.white, lineWidth: 4))
        }
        .frame(width: width + 12)
    }

    /// RPG 對話框，小技巧一個字一個字打出來
    private func dialog(_ t: Double) -> some View {
        let tip = BootState.tips[b.tip]
        let shown = String(tip.prefix(Int((t.truncatingRemainder(dividingBy: 4)) * 18)))
        return VStack(alignment: .leading, spacing: 6) {
            Text("TIP").font(px(14)).foregroundStyle(yellow)
            Text(shown + (Int(t * 3) % 2 == 0 ? "▌" : " ")).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        }
        .frame(width: 440, height: 64, alignment: .topLeading).padding(12)
        .background(Rectangle().fill(Color.black.opacity(0.6)))
        .overlay(Rectangle().stroke(.white, lineWidth: 3).padding(3))
        .overlay(Rectangle().stroke(.white.opacity(0.4), lineWidth: 2))
    }
}

/// 像素麥克風小人：0、1 跑步兩格，2 舉手歡呼
struct Sprite: View {
    let frame: Int
    let scale: CGFloat
    private static let head = [
        "...OOOO...",
        "..OWWWWO..",
        "..OWKWKO..",
        "..OWWWWO..",
        "..OWRRWO..",
        "...OOOO...",
        "....OO....",
    ]
    private static let frames = [
        ["..OOOOOO..", "....OO....", "...O..O...", "..O....O..", ".O......O."],
        ["...OOOO...", "....OO....", "....OO....", "...O.O....", "...O..O..."],
        ["O..OOOO..O", ".O..OO..O.", "....OO....", "...O..O...", "...O..O..."],
    ]
    var body: some View {
        let rows = Self.head + Self.frames[frame]
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    let color: Color? = switch ch {
                    case "O": Color(red: 1.0, green: 0.50, blue: 0.20)
                    case "W": .white
                    case "K": .black
                    case "R": Color(red: 0.95, green: 0.30, blue: 0.40)
                    default: nil
                    }
                    if let color { ctx.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)), with: .color(color)) }
                }
            }
        }
        .frame(width: 10 * scale, height: CGFloat(rows.count) * scale)
    }
}

/// Speakin --preview-boot mobile|pixel：開一個視窗看載入畫面，假下載 30 秒跑完，不連網、不動設定
enum BootPreview {
    static func size(_ style: String) -> NSSize {
        switch style {
        case "mini": NSSize(width: 320, height: 96)
        case "pill": NSSize(width: 300, height: 48)
        case "clean", "wave": NSSize(width: 480, height: 360)
        default: NSSize(width: 720, height: 520)
        }
    }

    @MainActor static func run(_ style: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Setup.fake = true
        Setup.shared.hasASR = false
        let size = BootPreview.size(style)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style == "pill" ? [.borderless] : style == "mini" ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable], backing: .buffered, defer: false)
        if style == "mini" { w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isMovableByWindowBackground = true }
        if style == "clean" { w.setFrameOrigin(NSPoint(x: w.frame.minX - 440, y: w.frame.minY)) }   // 放左邊，跟 E、F 一起比
        if style == "pill" { w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true; w.level = .floating; w.isMovableByWindowBackground = true }
        w.title = "載入畫面預覽：\(style)"
        w.contentView = NSHostingView(rootView: BootScreen(next: { NSApp.terminate(nil) }, style: style).frame(width: size.width, height: size.height))
        w.center()
        if style == "pill" { w.setFrameOrigin(NSPoint(x: w.frame.minX, y: w.frame.minY - 140)) }   // 同時開兩個預覽時不疊在一起
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in exit(0) }
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }
}

// MARK: - 跟 Speakin 其他頁同一個風格：白底、App 圖示的橘色、安靜

let brand = Color(red: 0.91, green: 0.33, blue: 0.17)

/// 兩版共用的狀態小字：0.71 / 1.69 GB・大約 3 分鐘
@MainActor private func quietStatus(_ b: BootState) -> String {
    if let e = b.problem { return e }
    if b.done { return "辨識模型準備好了" }
    if b.initializing { return "初始化中…" }
    return [b.sizeText, b.eta].filter { !$0.isEmpty }.joined(separator: "・")
}

/// 下面的按鈕：完成才出現；網路慢可以先去開權限
@MainActor @ViewBuilder private func quietActions(_ b: BootState, _ setup: Setup, _ next: @escaping () -> Void) -> some View {
    if b.done {
        Button("開始設定", action: next).buttonStyle(.borderedProminent).tint(brand).controlSize(.large).keyboardShortcut(.defaultAction)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    } else if setup.error != nil {
        Button("重試") { setup.download() }.controlSize(.small)
    } else if b.slow || b.problem != nil {
        Button("先去開權限，下載會在背景繼續", action: next).buttonStyle(.link).font(.caption)
    }
}

/// C. 蘋果風：Fn 鍵圖示＋細進度條＋一行小字
struct CleanBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()

    var body: some View {
        VStack(spacing: 22) {
            FnKeyAnimation().scaleEffect(0.8)
            VStack(spacing: 6) {
                Text(b.done ? "準備好了" : "正在準備 Speakin").font(.system(size: 20, weight: .semibold))
                Text(b.done ? "接下來開兩個權限，就能開始說話" : "第一次要下載辨識模型，之後就不用了").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(brand).frame(width: max(4, g.size.width * b.p))
                    }
                }
                .frame(width: 260, height: 4)
                .animation(.easeOut(duration: 0.3), value: b.p)
                Text(b.done ? " " : quietStatus(b)).font(.system(size: 11)).monospacedDigit().foregroundStyle(b.problem == nil ? Color.secondary : .red)
            }
            quietActions(b, setup, next).frame(height: 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.4), value: b.done)
        .onAppear { b.start() }
    }
}

/// D. 聲波長出來：細線照進度從左到右長成聲波，長好的會輕輕呼吸
struct WaveBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()
    @Environment(\.accessibilityReduceMotion) private var still
    private let n = 36

    var body: some View {
        VStack(spacing: 20) {
            TimelineView(.animation(paused: still)) { c in
                let t = still ? 0 : c.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<n, id: \.self) { i in
                        let x = Double(i) / Double(n - 1)
                        let shape = 0.25 + 0.75 * pow(sin(x * .pi), 1.5) * (0.6 + 0.4 * abs(sin(x * 9.0)))   // 中間高、兩邊低的聲波
                        let grown = min(1, max(0, (b.p * Double(n) - Double(i))))   // 這根長到幾成
                        let breathe = 1 + 0.12 * sin(t * 2.4 + Double(i) * 0.35)
                        Capsule().fill(grown > 0 ? brand : Color.secondary.opacity(0.18))
                            .frame(width: 4, height: 4 + 76 * shape * grown * (grown >= 1 ? breathe : 1))
                    }
                }.frame(height: 90)
            }
            .animation(.easeOut(duration: 0.4), value: b.p)
            Text(b.done ? "準備好了" : String(format: "%.0f%%", b.p * 100))
                .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(quietStatus(b)).font(.system(size: 11)).monospacedDigit().foregroundStyle(b.problem == nil ? Color.secondary : .red)
            quietActions(b, setup, next).frame(height: 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.4), value: b.done)
        .onAppear { b.start() }
    }
}

/// 聲波細線：照進度從左到右長出來，長好的會輕輕呼吸。lit/dim 是長好、還沒長的顏色
struct GrowingWave: View {
    let p: Double
    var bars = 28
    var height: CGFloat = 36
    var barWidth: CGFloat = 3
    var gap: CGFloat = 3
    var lit: Color = brand
    var dim: Color = Color.secondary.opacity(0.2)
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(paused: still)) { c in
            let t = still ? 0 : c.date.timeIntervalSinceReferenceDate
            HStack(spacing: gap) {
                ForEach(0..<bars, id: \.self) { i in
                    let x = Double(i) / Double(bars - 1)
                    let shape = 0.25 + 0.75 * pow(sin(x * .pi), 1.5) * (0.6 + 0.4 * abs(sin(x * 9.0)))
                    let grown = min(1, max(0, p * Double(bars) - Double(i)))
                    let breathe = 1 + 0.15 * sin(t * 2.4 + Double(i) * 0.35)
                    Capsule().fill(grown > 0 ? lit : dim)
                        .frame(width: barWidth, height: barWidth + (height - barWidth) * shape * grown * (grown >= 1 ? breathe : 1))
                }
            }.frame(height: height * 1.15)
        }
        .animation(.easeOut(duration: 0.4), value: p)
    }
}

/// E. 迷你視窗：窄窄一條白色小視窗，聲波＋右邊小小的百分比
struct MiniBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()

    var body: some View {
        HStack(spacing: 14) {
            GrowingWave(p: b.p, bars: 36, height: 34)
            Group {
                if b.done {
                    Button("開始", action: next).buttonStyle(.borderedProminent).tint(brand).controlSize(.small).keyboardShortcut(.defaultAction)
                } else if setup.error != nil {
                    Button("重試") { setup.download() }.controlSize(.small)
                } else {
                    Text(b.initializing ? "…" : String(format: "%.0f%%", b.p * 100))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            }.frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .help(quietStatus(b))   // 滑鼠停著看得到 0.71 / 1.69 GB・大約 3 分鐘
        .animation(.easeInOut(duration: 0.3), value: b.done)
        .onAppear { b.start() }
    }
}

/// F. 膠囊：跟錄音時的黑色膠囊同一個樣子，聲波從白長成橘
struct PillBoot: View {
    let next: () -> Void
    @ObservedObject var setup = Setup.shared
    @StateObject private var b = BootState()

    var body: some View {
        HStack(spacing: 12) {
            GrowingWave(p: b.p, bars: 26, height: 18, barWidth: 3, gap: 3, lit: brand, dim: .white.opacity(0.25))
            if b.done {
                Label("好了", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(brand).frame(width: 40, alignment: .trailing)
            } else if setup.error != nil {
                Button("重試") { setup.download() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
            } else {
                Text(b.initializing ? "…" : String(format: "%.0f%%", b.p * 100))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7)).frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.95)))
        .help(quietStatus(b))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: b.done)
        .onAppear { b.start() }
    }
}
