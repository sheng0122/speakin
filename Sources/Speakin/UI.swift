import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: 螢幕下方的浮動膠囊（錄音中顯示音量、整理中顯示轉圈）

@MainActor final class Pill {
    private let panel: NSPanel
    private unowned let u: Speakin

    init(_ u: Speakin) {
        self.u = u
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PillView(u: u))
    }

    func update() {
        let show = u.state != .idle || u.message != nil
        // 出現在滑鼠所在的螢幕
        let m = NSEvent.mouseLocation
        if show, !panel.isVisible, let s = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: s.midX - 240, y: s.minY + 24))
            panel.orderFrontRegardless()
        } else if !show { panel.orderOut(nil) }
    }
}

struct PillView: View {
    @ObservedObject var u: Speakin
    var body: some View {
        HStack(spacing: 10) {
            switch u.state {
            case .recording:
                HStack(spacing: 3) {
                    ForEach(u.levels.indices, id: \.self) { i in
                        Capsule().fill(brand).frame(width: 3, height: 3 + CGFloat(u.levels[i]) * 22)
                    }
                }.animation(.linear(duration: 0.08), value: u.levels)
                TimelineView(.periodic(from: .now, by: 1)) { c in
                    let t = Int(c.date.timeIntervalSince(u.started))
                    Text(String(format: "%d:%02d", t / 60, t % 60)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Double(t) > Speakin.maxSeconds - 60 ? brand : .white.opacity(0.7))
                }
            case .processing:
                Spinner()
                Text(u.message ?? "整理中…")
            case .idle:
                Text(u.message ?? "").lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.95)))
        .frame(width: 480, height: 44)
    }
}

/// 黑底上看得到的轉圈：淡白圓圈上一段白色弧線在跑
struct Spinner: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.3).stroke(brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(on ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: on)
        }
        .frame(width: 14, height: 14)
        .onAppear { on = true }
    }
}

// MARK: 主視窗

struct MainView: View {
    @ObservedObject var u = Speakin.shared
    @ObservedObject var store = Store.shared
    private var tabs: [(String, String)] {
        var t = [("首頁", "house"), ("歷史紀錄", "clock"), ("字典", "character.book.closed"), ("設定", "gearshape")]
        #if EXPERIMENTAL
        t.append(("實驗功能", "flask"))
        #endif
        return t
    }

    var body: some View {
        if !store.settings.onboarded {
            // 引導走完前：主視窗先藏起來，改出現浮在桌面上的黑色面板
            Color.clear.frame(width: 1, height: 1).background(WindowAccess { w in
                OnboardingPanel.shared.mainWindow = w; w.orderOut(nil); OnboardingPanel.shared.show()
            })
        } else { main }
    }

    private var main: some View {
        NavigationSplitView {
            VStack(spacing: 2) {
                ForEach(tabs, id: \.0) { t in
                    let on = u.tab == t.0
                    Button { u.tab = t.0 } label: {
                        Label(t.0, systemImage: t.1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? brand : .clear))
                            .foregroundStyle(on ? .white : .primary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                // 左下角：版本＋檢查更新；有新版就換成橘色的下載連結
                VStack(alignment: .leading, spacing: 6) {
                    Text("版本 \(Updater.current)").foregroundStyle(.secondary)
                    if let n = u.update, let app = u.staged {
                        Button("重開完成更新 \(n.version)") { Updater.install(app) }.buttonStyle(.plain).foregroundStyle(brand)
                    } else if let n = u.update {
                        Button("下載新版 \(n.version)") { NSWorkspace.shared.open(n.url) }.buttonStyle(.plain).foregroundStyle(brand)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 14)
            }
            .padding(.horizontal, 10).padding(.top, 8)
            .navigationSplitViewColumnWidth(170)
            .frame(maxHeight: .infinity).background(Color(white: 0.04))
        } detail: {
            Group { switch u.tab {
            case "歷史紀錄": HistoryView()
            case "字典": DictView()
            case "設定": SettingsView()
            #if EXPERIMENTAL
            case "實驗功能": ExperimentalView()
            #endif
            default: HomeView()
            } }.scrollContentBackground(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.07))
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .tint(brand)
    }
}

struct HomeView: View {
    @ObservedObject var u = Speakin.shared
    @ObservedObject var store = Store.shared
    @State private var range = 7
    @ObservedObject var setup = Setup.shared

    var body: some View {
        let shown = store.history.filter { !$0.text.isEmpty && (range == 0 || $0.date > Date().addingTimeInterval(-Double(range) * 86400)) }
        let words = shown.reduce(0) { $0 + TextFix.wordCount($1.text) }
        let talk = shown.reduce(0) { $0 + $1.seconds }
        let zones = Zone.tally(shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("你的口述").font(.system(size: 28, weight: .heavy))
                    Spacer()
                    Picker("期間", selection: $range) {
                        Text("這週").tag(7); Text("這個月").tag(30); Text("全部").tag(0)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if !setup.hasASR { SetupBox() }
                if NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == "Typeless" }) {
                    Label("Typeless 正在執行，會搶走 Fn 鍵。用 Speakin 前先把它關掉。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(brand)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    Stat(title: "講了幾次", value: shown.count.formatted())
                    Stat(title: "轉成多少字", value: words.formatted())
                    Stat(title: "講了多久", value: Self.duration(talk))
                    // 打字速度用每分鐘 40 字估，跟 SayIt 一樣
                    Stat(title: "省下的打字時間", value: Self.duration(max(0, Double(words) / 40 * 60 - talk)), hint: "用打字每分鐘 40 字估算，扣掉講話的時間")
                    Stat(title: "平均每次幾字", value: shown.isEmpty ? "0" : (words / shown.count).formatted())
                    Stat(title: "自動學到的詞", value: "\(store.dict.filter { $0.auto == true }.count)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("在哪裡講話").font(.headline)
                    if zones.isEmpty {
                        Text("還沒有紀錄。點一下任何輸入框，\(store.settings.fnMode == .hold ? "按住 Fn" : "按一下 Fn") 開始說話。").foregroundStyle(.secondary).padding(.vertical, 20)
                    } else {
                        // 用最多的最大塊，第二名占右半，第三、四名分右下
                        GeometryReader { g in
                            let gap: CGFloat = 12, half = (g.size.width - gap) / 2
                            HStack(spacing: gap) {
                                ZoneCard(z: zones[0], total: shown.count, rank: 0).frame(width: zones.count > 1 ? half : g.size.width)
                                if zones.count > 1 {
                                    VStack(spacing: gap) {
                                        ZoneCard(z: zones[1], total: shown.count, rank: 1)
                                        if zones.count > 2 {
                                            HStack(spacing: gap) {
                                                ZoneCard(z: zones[2], total: shown.count, rank: 2)
                                                if zones.count > 3 { ZoneCard(z: zones[3], total: shown.count, rank: 3) }
                                            }
                                        }
                                    }.frame(width: half)
                                }
                            }
                        }.frame(height: 320)
                    }
                }
            }.padding(28)
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) 小時 \(m % 60) 分" : m > 0 ? "\(m) 分" : "\(Int(s)) 秒"
    }
}

/// 依 App 名稱分區；比對不到的算「其他」
struct Zone {
    let name: String, count: Int, apps: [(String, Int)]
    // ponytail: 用 App 名稱關鍵字分區，遇到沒列到的 App 再補
    static let table: [(String, [String])] = [
        ("聊天", ["line", "slack", "messages", "訊息", "discord", "telegram", "whatsapp", "teams", "messenger", "wechat", "微信"]),
        ("文件", ["notion", "pages", "word", "文字編輯", "textedit", "obsidian", "備忘錄", "notes", "craft", "bear"]),
        ("程式", ["orca", "terminal", "終端機", "iterm", "iterm2", "warp", "ghostty", "code", "cursor", "xcode", "zed"]),
        ("郵件", ["mail", "郵件", "outlook", "spark", "gmail"]),
        ("瀏覽器", ["chrome", "safari", "arc", "firefox", "edge", "brave", "dia"]),
    ]
    static func of(_ app: String) -> String {
        // 英文比對整個字，免得 1Password 被當成 Word
        let a = app.lowercased(), words = a.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return table.first { $0.1.contains { k in k.allSatisfy(\.isASCII) ? words.contains(k) : a.contains(k) } }?.0 ?? "其他"
    }
    static func tally(_ h: [HistoryItem]) -> [Zone] {
        Dictionary(grouping: h) { of($0.app) }.map { name, items in
            let apps = Dictionary(grouping: items, by: \.app).filter { !$0.key.isEmpty }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
            return Zone(name: name, count: items.count, apps: apps)
        }.sorted { $0.count > $1.count }
    }
}

struct ZoneCard: View {
    let z: Zone, total: Int, rank: Int
    @State private var open = false
    var body: some View {
        let big = rank == 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(z.name).font(.system(size: big ? 18 : 15, weight: .bold))
                Spacer()
                Text(z.apps.prefix(2).map(\.0).joined(separator: "、")).font(.caption).lineLimit(1)
            }
            Text("\(Int((Double(z.count) / Double(max(total, 1)) * 100).rounded()))%")
                .font(.system(size: big ? 56 : rank == 1 ? 36 : 28, weight: .heavy).monospacedDigit())
            Spacer(minLength: 0)
            Text("\(z.count) 次").font(.callout)
        }
        .padding(big ? 20 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(big ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 16).fill(big ? AnyShapeStyle(brand) : AnyShapeStyle(brand.opacity(rank == 1 ? 0.18 : 0.08))))
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .help("點一下看是哪些 App")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text(z.name).font(.headline)
                ForEach(z.apps, id: \.0) { app, n in
                    HStack { Text(app); Spacer(minLength: 24); Text("\(n) 次").foregroundStyle(.secondary).monospacedDigit() }
                }
            }.padding(16).frame(minWidth: 220)
        }
    }
}

import AVFoundation

struct Stat: View {
    let title: String, value: String
    var hint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
        .help(hint)
    }
}

/// 第一次打開：下載辨識模型、開麥克風、開輔助使用，全部好了才消失
struct SetupBox: View {
    @ObservedObject var setup = Setup.shared
    var body: some View {
        GroupBox("辨識模型還沒準備好") { ModelLoading().frame(maxWidth: .infinity).padding(8) }
    }
}

/// 重播歷史紀錄的錄音：一次只放一筆
@MainActor final class Player: ObservableObject {
    @Published var playing: UUID?
    private var p: AVAudioPlayer?
    func toggle(_ h: HistoryItem) {
        p?.stop()
        if playing == h.id { playing = nil; return }
        let s = SessionLog.segments(h).flatMap { $0 }
        guard !s.isEmpty, let pl = try? AVAudioPlayer(data: Segmenter.wav(s)) else { playing = nil; return }
        p = pl; pl.play(); playing = h.id
        DispatchQueue.main.asyncAfter(deadline: .now() + pl.duration + 0.1) { [weak self] in if self?.p === pl { self?.playing = nil } }
    }
}


struct HistoryView: View {
    @ObservedObject var store = Store.shared
    @State private var query = ""
    @ObservedObject var u = Speakin.shared
    @StateObject private var player = Player()
    @State private var editing: HistoryItem?
    @State private var draft = ""
    @State private var learned: String?
    @State private var clearAll = false
    var body: some View {
        let shown = store.history.reversed().filter { Store.matches($0, query, store.dict) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        // 參考 Typeless：左欄時間、右邊文字；按鈕平常藏起來，滑鼠移上去才出現，一天一張卡片
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("歷史紀錄").font(.system(size: 28, weight: .bold))
                    Spacer()
                    if !store.history.isEmpty { Button("全部清除") { clearAll = true }.buttonStyle(.borderless).foregroundStyle(.secondary) }
                }
                // 搜尋框放在標題下面，不放視窗最上面
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋內容或 App", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                ForEach(days, id: \.key) { day, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.dayName(day)).font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, h in
                                if i > 0 { Divider().padding(.leading, 16) }
                                row(h)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if store.history.isEmpty { Text("還沒有紀錄").foregroundStyle(.secondary) }
            else if !query.isEmpty, !store.history.contains(where: { Store.matches($0, query, store.dict) }) { Text("找不到").foregroundStyle(.secondary) }
        }
        .confirmationDialog("全部清除？", isPresented: $clearAll) {
            Button("全部清除（\(store.history.count) 筆）", role: .destructive) { store.deleteHistory() }
        } message: { Text("文字和錄音都會刪掉，刪了救不回來。字典不會動。") }
        .sheet(item: $editing) { h in
            VStack(alignment: .leading, spacing: 12) {
                Text("修正這筆").font(.title3.bold())
                Text("把聽錯的字改對再儲存，改過的詞會自動加進字典。").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body).frame(width: 480, height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                if let l = learned { Text(l).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button(learned == nil ? "取消" : "關閉") { editing = nil }.keyboardShortcut(.cancelAction)
                    if learned == nil { Button("儲存") { save(h) }.keyboardShortcut(.defaultAction).disabled(draft == h.text) }
                }
            }.padding(24)
        }
    }

    @State private var hovered: UUID?
    @State private var showRaw: Set<UUID> = []

    private func row(_ h: HistoryItem) -> some View {
        let on = hovered == h.id || player.playing == h.id, busy = u.state != .idle
        return HStack(alignment: .center, spacing: 16) {
            Text(h.date.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
                .help("\(h.app.isEmpty ? "" : h.app + "，")講了 \(Int(h.seconds)) 秒")
            VStack(alignment: .leading, spacing: 6) {
                Text(h.text.isEmpty ? "（沒有辨識到字）" : h.text).textSelection(.enabled)
                    .foregroundStyle(h.text.isEmpty ? .secondary : .primary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showRaw.contains(h.id) {
                    Text(h.raw).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let n = h.note { Label(n, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(brand) }
            }
            HStack(spacing: 2) {
                if h.raw != h.text, !h.raw.isEmpty {
                    icon(showRaw.contains(h.id) ? "text.badge.minus" : "text.magnifyingglass", "看辨識原文（潤稿前）") {
                        if showRaw.contains(h.id) { showRaw.remove(h.id) } else { showRaw.insert(h.id) }
                    }
                }
                icon(player.playing == h.id ? "stop.fill" : "play.fill", "重播這次的錄音") { player.toggle(h) }
                icon("arrow.clockwise", "用這次的錄音再辨識、潤稿一次，結果會換掉這筆") { u.redo(h) }.disabled(busy)
                icon("pencil", "把聽錯的字改對，Speakin 會記住，下次就不會再錯") { editing = h; draft = h.text; learned = nil }.disabled(h.text.isEmpty)
                icon("doc.on.doc", "複製") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.text, forType: .string) }.disabled(h.text.isEmpty)
                icon("trash", "刪除這筆（連錄音一起刪）") { store.deleteHistory([h.id]) }
            }
            .opacity(on ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(on ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? h.id : (hovered == h.id ? nil : hovered) }
        .contextMenu {
            Button("複製") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.text, forType: .string) }
            Button("下載錄音檔…") { Self.saveAudio(h) }
            Divider()
            Button("刪除這筆", role: .destructive) { store.deleteHistory([h.id]) }
        }
    }

    private func icon(_ name: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).frame(width: 26, height: 22) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }

    static func dayName(_ d: Date) -> String {
        let c = Calendar.current
        return c.isDateInToday(d) ? "今天" : c.isDateInYesterday(d) ? "昨天" : d.formatted(.dateTime.month().day().weekday())
    }

    static func saveAudio(_ h: HistoryItem) {
        let s = SessionLog.segments(h).flatMap { $0 }
        guard !s.isEmpty else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Speakin " + h.date.formatted(.dateTime.year().month().day().hour().minute()).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "") + ".wav"
        p.allowedContentTypes = [.wav]
        if p.runModal() == .OK, let u = p.url { try? Segmenter.wav(s).write(to: u) }
    }

    private func save(_ h: HistoryItem) {
        // 只比前後不一樣的那段，長文後半段改的字也學得到（diffPairs 只看前 400 字）
        let p = zip(h.text, draft).prefix { $0 == $1 }.count
        let q = zip(h.text.dropFirst(p).reversed(), draft.dropFirst(p).reversed()).prefix { $0 == $1 }.count
        let pad = 20, a = Array(h.text), b = Array(draft)
        let added = store.learn(TextFix.diffPairs(String(a[Swift.max(0, p - pad)..<Swift.min(a.count, a.count - q + pad)]),
                                                  String(b[Swift.max(0, p - pad)..<Swift.min(b.count, b.count - q + pad)])))
        if let i = store.history.firstIndex(where: { $0.id == h.id }) { store.history[i].text = draft }
        guard !added.isEmpty else { editing = nil; return }
        learned = "已加入字典：" + added.map { "\($0.wrong) → \($0.right)" }.joined(separator: "、")
    }
}

struct DictView: View {
    @ObservedObject var store = Store.shared
    @State private var filter = 0
    @State private var searching = false
    @State private var query = ""
    @State private var adding = false
    @State private var newTerm = ""
    @State private var editing: DictEntry?
    @State private var editTerm = ""
    @State private var editHeard = ""
    @State private var hovered: UUID?
    @State private var picked: Set<UUID> = []   // 勾選起來一次刪

    /// 參考 Typeless：平常只有圖示和詞；滑鼠移上去才出現「⋯」選單和勾選框，勾了就能一次刪很多個
    private func chip(_ e: DictEntry) -> some View {
        let on = hovered == e.id || picked.contains(e.id) || !picked.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: e.auto == true ? "sparkle" : "pencil.line")
                .foregroundStyle(e.auto == true ? brand : Color.secondary)
                .help(e.auto == true ? "從你的修改自動學到" : "你自己加的")
            Text(e.term).lineLimit(1)
            Spacer(minLength: 0)
            if on {
                Menu {
                    Button("修改") { edit(e) }
                    Button("刪除", role: .destructive) { store.dict.removeAll { $0.id == e.id } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("修改和刪除")
                Toggle("", isOn: Binding(get: { picked.contains(e.id) }, set: { if $0 { picked.insert(e.id) } else { picked.remove(e.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().help("勾選，可以一次刪很多個")
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovered == e.id || picked.contains(e.id) ? Color.primary.opacity(0.05) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .onTapGesture { if picked.isEmpty { edit(e) } else if picked.contains(e.id) { picked.remove(e.id) } else { picked.insert(e.id) } }
    }

    private func edit(_ e: DictEntry) { editing = e; editTerm = e.term; editHeard = e.heardAs.joined(separator: "、") }

    var body: some View {
        let shown = store.dict.reversed().filter { e in
            (filter == 0 || (filter == 1) == (e.auto == true)) &&
            (query.isEmpty || e.term.localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("字典").font(.system(size: 30, weight: .heavy))
                Spacer()
                Button("匯入…") { importWords() }.controlSize(.large).buttonBorderShape(.capsule)
                    .help("從 .txt 或 .csv 匯入，一行一個詞（Typeless 匯出的字典也可以）")
                Button("新增詞彙") { adding = true }.buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
            }
            HStack(spacing: 10) {
                Picker("篩選", selection: $filter) {
                    Text("全部").tag(0); Text("自動加入").tag(1); Text("手動加入").tag(2)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if !picked.isEmpty {
                    Text("已勾選 \(picked.count) 個").foregroundStyle(.secondary)
                    Button("全選") { picked.formUnion(shown.map(\.id)) }
                    Button("取消") { picked = [] }
                    Button("刪除", role: .destructive) { store.dict.removeAll { picked.contains($0.id) }; picked = [] }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
                if searching {
                    TextField("搜尋詞彙", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                Button { searching.toggle(); if !searching { query = "" } } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass").frame(width: 22, height: 22)
                }.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large).help("搜尋")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(shown) { e in chip(e) }
                }
            }
            .overlay { if shown.isEmpty { Text(query.isEmpty ? "還沒有詞" : "找不到").foregroundStyle(.secondary) } }
            .alert(imported ?? "", isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } })) { Button("好") {} }
        }
        .padding(28)
        .sheet(item: $editing) { e in
            VStack(alignment: .leading, spacing: 14) {
                Text("修改詞彙").font(.title3.bold())
                Text("正確寫法").font(.callout)
                TextField("例：Cloudflare", text: $editTerm).textFieldStyle(.roundedBorder).frame(width: 320)
                Text("常被聽成（用頓號分開，辨識出這些字會自動換成正確寫法）").font(.callout)
                TextField("例：cloud floor、克勞德佛", text: $editHeard).textFieldStyle(.roundedBorder).frame(width: 320)
                HStack {
                    Button("刪除這個詞", role: .destructive) { store.dict.removeAll { $0.id == e.id }; editing = nil }
                    Spacer()
                    Button("取消") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("儲存") { saveEdit(e) }.keyboardShortcut(.defaultAction)
                        .disabled(editTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(24)
        }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 16) {
                Text("新增詞彙").font(.title3.bold())
                TextField("例：Cloudflare", text: $newTerm).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit(add)
                HStack {
                    Spacer()
                    Button("取消") { adding = false; newTerm = "" }.keyboardShortcut(.cancelAction)
                    Button("加入", action: add).keyboardShortcut(.defaultAction).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(24)
        }
    }

    private func saveEdit(_ e: DictEntry) {
        let t = editTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = store.dict.firstIndex(where: { $0.id == e.id }) else { return }
        store.dict[i].term = t
        store.dict[i].heardAs = editHeard.split(whereSeparator: { "、,，\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 != t && ($0.count >= 2 || $0.allSatisfy(\.isASCII) && !$0.isEmpty) }   // 單一個中文字會把每個「的」都換掉
        editing = nil
    }

    @State private var imported: String?
    private func importWords() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .commaSeparatedText]
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        imported = "已匯入 \(store.importWords(text)) 個詞"
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if !store.dict.contains(where: { $0.term.lowercased() == t.lowercased() }) { store.dict.append(DictEntry(term: t)) }
        newTerm = ""; adding = false
    }
}

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var u = Speakin.shared
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var agents: [Agent: Bool]?
    @State private var downloading: Double?   // 本機模型下載進度 0～1；nil = 沒在下載
    @State private var downloadError: String?
    @State private var hasLocal = FileManager.default.fileExists(atPath: LocalPolisher.modelPath)   // 有裝的 coding agent → 有沒有登入；nil = 還在偵測
    /// models 資料夾裡的 .gguf，加上目前設定的（就算檔案被移走也顯示，選單才不會空白）
    private var asrModels: [String] {
        let d = Store.dir.appendingPathComponent("models")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
            .filter { $0.hasSuffix(".gguf") && !$0.hasPrefix("Qwen3.5") }.sorted().map { d.appendingPathComponent($0).path }
        return files.contains(store.settings.asrModel) ? files : files + [store.settings.asrModel]
    }

    /// 選「本機」時：講模型是哪個，沒下載就給下載按鈕
    @ViewBuilder private var localModel: some View {
        Text("模型：Qwen3.5-4B（2.7 GB）").font(.caption).foregroundStyle(.secondary)
        if !hasLocal {
            if let p = downloading {
                ProgressView(value: p) { Text(String(format: "下載中 %.0f%%", p * 100)).font(.caption) }
            } else if let why = LocalPolisher.downloadBlocker {
                Text(why + "。下載好之前只貼辨識結果。").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(downloadError ?? "還沒下載，下載好之前只貼辨識結果。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("下載") {
                        downloading = 0; downloadError = nil
                        Task {
                            do { try await LocalPolisher.download { p in Task { @MainActor in downloading = p } }; hasLocal = true }
                            catch { downloadError = error.localizedDescription }
                            downloading = nil
                        }
                    }
                }
            }
        }
    }

    /// 選的工具不能用時講清楚：現在只會貼辨識結果，不會跳錯誤
    private var polishNote: String? {
        guard let agents else { return nil }
        if store.settings.model == "auto" {
            return Agent.auto() == nil ? "沒找到可以潤稿的工具（Claude Code、Codex、Antigravity），現在只貼辨識結果。" : nil
        }
        guard let a = Agent.of(store.settings.model) else { return nil }
        if agents[a] == nil { return "沒找到 \(a.name)，現在只貼辨識結果。" }
        if agents[a] == false { return "\(a.name) 還沒登入，現在只貼辨識結果。登入後重開這個視窗。" }
        return nil
    }

    var body: some View {
        Form {
            Section("一般") {
                Toggle("開機時自動開啟", isOn: Binding(
                    get: { loginOn },
                    set: { on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { NSLog("開機啟動設定失敗：\(error)") }
                        loginOn = SMAppService.mainApp.status == .enabled
                    }))
                Picker("Fn 鍵", selection: $store.settings.fnMode) {
                    Text("按住講放開結束，或點一下免持").tag(FnMode.both)
                    Text("按一下開始，再按一下結束").tag(FnMode.tap)
                    Text("按住講，放開結束").tag(FnMode.hold)
                }
                .onChange(of: store.settings.fnMode) { _, v in Speakin.shared.hotkey.mode = v }
                Text("⌥⇧V：再貼一次上一句。").font(.caption).foregroundStyle(.secondary)
                Toggle("不在 Dock 顯示", isOn: $store.settings.hideDock)
                    .onChange(of: store.settings.hideDock) { _, v in
                        NSApp.setActivationPolicy(v ? .accessory : .regular)
                        NSApp.activate(ignoringOtherApps: true)   // 切換後視窗會被丟到後面，拉回來
                    }
                Toggle("提示音", isOn: $store.settings.sounds)
                    .help("開始錄音時響一聲")
                Picker("麥克風", selection: $store.settings.mic) {
                    Text("跟系統設定").tag(String?.none)
                    ForEach(SystemAudio.inputs, id: \.uid) { Text($0.name).tag(Optional($0.uid)) }
                }
                .onChange(of: store.settings.mic) { _, _ in Speakin.shared.applyMic() }
                if let uid = store.settings.mic, SystemAudio.device(uid: uid) == nil {
                    Text("選的麥克風沒接上，先用系統預設的。").font(.caption).foregroundStyle(brand)
                }
                MicMeter(mic: store.settings.mic)
                Toggle("用藍牙耳機時改用內建麥克風", isOn: $store.settings.avoidBluetooth)
                    .help("AirPods 當麥克風會切成通話模式，音樂變很糊。只在「跟系統設定」時有用")
                    .onChange(of: store.settings.avoidBluetooth) { _, _ in Speakin.shared.applyMic() }
                Toggle("麥克風常開（句首不漏字）", isOn: $store.settings.micAlwaysOn)
                    .help("按下 Fn 前 0.45 秒的聲音也收得到。代價是右上角橘點一直亮；聲音只留在記憶體，不會存檔")
                    .onChange(of: store.settings.micAlwaysOn) { _, _ in Speakin.shared.applyMic() }
                Toggle("錄音時把其他聲音靜音", isOn: $store.settings.muteOthers)
                    .help("音樂、影片在錄音時先靜音，講完自動恢復")
            }
            Section("潤稿") {
                Toggle("自動潤稿", isOn: $store.settings.polish)
                    .help("關掉就直接貼辨識結果，文字不會離開電腦")
                if store.settings.polish {
                    Picker("潤稿方式", selection: $store.settings.smooth) {
                        Text("保留原話").tag(false)
                        Text("整理通順").tag(true)
                    }
                    Picker("用什麼潤稿", selection: $store.settings.model) {
                        Text("自動").tag("auto")
                        ForEach(Agent.allCases.filter { agents?[$0] != nil }, id: \.self) { a in
                            Text(a.name + (a == .claude ? "（最快）" : "") + (agents?[a] == true ? "" : "（沒登入）")).tag(a == .claude ? "haiku" : a.rawValue)
                        }
                        if store.settings.model == "sonnet" { Text("Claude Code（Sonnet，較慢）").tag("sonnet") }
                        Text("本機（不上網，較慢）").tag("qwen")
                    }
                    if let note = polishNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if store.settings.model == "qwen" { localModel }
                    Toggle("參考畫面上的字", isOn: $store.settings.context)
                        .help("讓辨識和潤稿知道你前面寫了什麼；個資和金鑰會先遮掉")
                }
            }
            .task {
                // 問登入狀態要跑外部程式（1～3 秒），放背景做
                agents = await Task.detached { Agent.detect() }.value
                Agent.ready = agents
            }
            Section("貼上") {
                Toggle("貼上後保留在剪貼簿", isOn: $store.settings.keepClipboard)
                    .help("關著時會把你原本複製的東西還原")
                Toggle("貼上後自動按 Enter 送出", isOn: $store.settings.autoEnter)
                    .help("聊天、AI 對話框講完就直接送出，不用再按 Enter。寫文件時會多一個換行，用不到就關掉")
            }
            Section("紀錄") {
                Picker("歷史紀錄和錄音保留", selection: $store.settings.historyDays) {
                    Text("一直留").tag(Int?.none)
                    Text("90 天").tag(Int?.some(90))
                    Text("30 天").tag(Int?.some(30))
                    Text("7 天").tag(Int?.some(7))
                    Text("1 天").tag(Int?.some(1))
                    Text("不存").tag(Int?.some(0))
                }
                .onChange(of: store.settings.historyDays) { _, _ in store.pruneHistory() }
                Text("講的內容常有公司資料，只留需要的天數。改短會馬上刪掉比較舊的，刪了救不回來。設成「不存」之後的錄音也不存；已經存的要到歷史紀錄自己刪。").font(.caption).foregroundStyle(.secondary)
            }
            if asrModels.count > 1 {
                Section("語音辨識") {
                    Picker("辨識模型", selection: $store.settings.asrModel) {
                        ForEach(asrModels, id: \.self) { Text(Self.asrName($0)).tag($0) }
                    }
                }
            }
            Section("Fn 鍵沒反應") {
                LabeledContent("按 Fn 跳出表情符號") {
                    Button("打開鍵盤設定") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                }
                Text("把「按下 🌐 鍵時」改成「不執行任何動作」。Typeless 開著也會搶 Fn 鍵。").font(.caption).foregroundStyle(.secondary)
            }
            Section("更新") {
                LabeledContent("版本 \(Updater.current)") {
                    if let n = u.update, let app = u.staged { Button("重開完成更新 \(n.version)") { Updater.install(app) } }
                    else if let n = u.update { Button("下載新版 \(n.version)") { NSWorkspace.shared.open(n.url) } }
                    else { Button("檢查更新") { Task { await u.checkUpdate(manual: true) } } }
                }
            }
        }.formStyle(.grouped)
    }

    static func asrName(_ path: String) -> String {
        let f = (path as NSString).lastPathComponent
        if f.hasPrefix("TEA-ASR") { return "標準（建議）" }
        if f.hasPrefix("Breeze") { return "舊版" }
        return (f as NSString).deletingPathExtension
    }
}

/// 設定頁的麥克風音量條：講講看，條子有過那條線才聽得到你（小聲講話也要過線）
struct MicMeter: View {
    let mic: String?
    @StateObject private var m = Meter()

    final class Meter: ObservableObject {
        @Published var level: Float = 0
        private var rec: Recorder?
        func start(_ mic: String?) {
            stop()
            let r = Recorder()
            r.onSamples = { [weak self] s in
                let v = Segmenter.rms(s[...])
                DispatchQueue.main.async { guard let self else { return }; self.level = max(v, self.level * 0.85) }   // 掉得慢一點，看得清楚
            }
            if (try? r.start(mic: mic)) != nil { rec = r }
        }
        func stop() { rec?.stop(); rec = nil; level = 0 }
        /// 音量（RMS）換成 0～1：-60 dB 到 -10 dB，人耳感覺比較線性
        static func pos(_ v: Float) -> CGFloat { CGFloat(min(1, max(0, (20 * log10(max(v, 1e-6)) + 60) / 50))) }
    }

    var body: some View {
        LabeledContent("音量") {
            GeometryReader { g in
                let w = g.size.width, line = w * Meter.pos(0.006)   // 0.006 是判斷「有在講話」的預設門檻
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(m.level >= 0.006 ? brand : Color.secondary).frame(width: w * Meter.pos(m.level))
                    Rectangle().fill(.secondary).frame(width: 1.5, height: 12).offset(x: line)
                }
            }
            .frame(height: 8).frame(maxWidth: 220)
            .help("講講看。橘色、超過那條線，就代表聽得到你")
            .animation(.linear(duration: 0.08), value: m.level)
        }
        .onAppear { if Speakin.shared.state == .idle { m.start(mic) } }
        .onChange(of: mic) { _, v in m.start(v) }
        .onDisappear { m.stop() }
    }
}
