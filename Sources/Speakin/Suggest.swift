import SwiftUI

/// 字典頁的「智慧建議」：每 7 天在背景找一次聽錯的詞，安靜放在這裡，不跳視窗。
/// 每次檢查把整區換掉：沒理的詞這週沒再聽錯就自己消失，按「略過」的以後都不出現
@MainActor final class Suggestions: ObservableObject {
    static let shared = Suggestions()
    private static let itemsKey = "suggestItems", lastRunKey = "suggestLastRun"
    // 開 App 時重新對一次句子：過期的句子拿掉，對不到句子的建議也拿掉
    @Published var items: [Suggest.Item] = Suggest.attach((UserDefaults.standard.data(forKey: itemsKey)).flatMap { try? JSONDecoder().decode([Suggest.Item].self, from: $0) } ?? [], Store.shared.history) {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.itemsKey) }
    }
    @Published var busy = false

    /// 開 App 時呼叫：距離上次檢查滿 7 天才跑（剛好對上「看最近 7 天」，紀錄不重疊），等 30 秒不跟開機搶資源
    func onLaunch() {
        // 紀錄會送給 Claude：只在本來就用 Claude 潤稿的人身上跑（關掉潤稿、選本機或 Codex 的人，文字本來不會給 Claude）
        let st = Store.shared.settings
        guard st.polish, ["auto", "haiku", "sonnet"].contains(st.model), Agent.claude.path != nil else { return }
        guard Store.shared.history.contains(where: { Date().timeIntervalSince($0.date) < 7 * 86400 }) else { return }   // 沒紀錄就不跑，也不記時間
        if let d = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date, Date().timeIntervalSince(d) < 7 * 86400 { return }
        Task { try? await Task.sleep(for: .seconds(30)); await run() }
    }

    func run() async {
        guard !busy else { return }
        busy = true
        let r = await Suggest.find(Store.shared.history, dict: Store.shared.dict)
        busy = false
        guard let r else { return }   // 失敗不記時間，下次開 App 再試
        UserDefaults.standard.set(Date(), forKey: Self.lastRunKey)
        items = Suggest.attach(r.filter { !Suggest.skipped.contains($0.id) }, Store.shared.history)
    }

    func add(_ s: Suggest.Item) { Suggest.add(s, to: Store.shared); items.removeAll { $0.id == s.id } }
    func skip(_ s: Suggest.Item) { Suggest.skip(s); items.removeAll { $0.id == s.id } }
}

/// 字典頁裡的建議清單；沒有建議時整塊不出現
struct SuggestBox: View {
    @ObservedObject var s = Suggestions.shared
    @State private var open: Set<String> = []   // 展開看全部句子的詞

    /// 句子裡的錯字標成橘色
    private func mark(_ t: String, _ w: String) -> AttributedString {
        var a = AttributedString(t)
        if let r = a.range(of: w, options: .caseInsensitive) { a[r].foregroundColor = brand }
        return a
    }
    var body: some View {
        if !s.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button("全部加入") { s.items.forEach(s.add) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                VStack(spacing: 0) {
                        ForEach(s.items) { x in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    Text(x.right).font(.system(size: 14, weight: .semibold))
                                    Text("常被聽成「\(x.wrong)」，\(x.hits.count) 句").font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Button("略過") { s.skip(x) }.buttonStyle(.borderless).foregroundStyle(.secondary).help("以後不會再建議這個詞")
                                    Button("加入") { s.add(x) }.buttonStyle(.borderedProminent)
                                }
                                let all = open.contains(x.id)
                                ForEach(all ? x.hits : Array(x.hits.prefix(3)), id: \.self) { h in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(h.date, format: .dateTime.month(.defaultDigits).day().hour().minute()).monospacedDigit().foregroundStyle(.tertiary)
                                        Text(mark(h.text, x.wrong)).foregroundStyle(.secondary).lineLimit(1)
                                    }.font(.system(size: 12))
                                }
                                if x.hits.count > 3 {
                                    Button(all ? "收起來" : "看全部 \(x.hits.count) 句") { if all { open.remove(x.id) } else { open.insert(x.id) } }
                                        .buttonStyle(.borderless).font(.system(size: 12))
                                }
                            }.padding(.horizontal, 14).padding(.vertical, 10)
                            if x.id != s.items.last?.id { Divider().padding(.leading, 14) }
                        }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }
}

/// 字典頁分頁旁的「智慧建議」：有建議時帶橘色數字；按下去切到建議，再按一次回字典
struct SuggestPill: View {
    @ObservedObject var s = Suggestions.shared
    var on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("智慧建議")
                if !s.items.isEmpty {
                    Text("\(s.items.count)").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(on ? Color.white.opacity(0.25) : brand)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(on ? brand : Color.primary.opacity(0.08)))
            .foregroundStyle(on ? .white : .primary).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

enum Suggest {
    private static let skipKey = "suggestSkipped"
    static var skipped: Set<String> { Set(UserDefaults.standard.stringArray(forKey: skipKey) ?? []) }
    static func skip(_ s: Item) { UserDefaults.standard.set(Array(skipped.union([s.id])), forKey: skipKey) }

    /// 紀錄裡含有錯字的一句：哪天講的、前後一小段
    struct Hit: Codable, Hashable { let date: Date, text: String }

    struct Item: Identifiable, Codable { var id: String { wrong + "→" + right }; let wrong: String, right: String; var example = ""
        var hits: [Hit] = []
        enum CodingKeys: CodingKey { case wrong, right, example, hits }
        init(wrong: String, right: String, example: String = "") { self.wrong = wrong; self.right = right; self.example = example }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            wrong = try c.decode(String.self, forKey: .wrong); right = try c.decode(String.self, forKey: .right)
            example = (try? c.decode(String.self, forKey: .example)) ?? ""
            hits = (try? c.decode([Hit].self, forKey: .hits)) ?? []
        }
    }

    static let rule = """
    你在幫一個語音輸入 App 整理字典。下面是使用者最近的語音紀錄，每筆有「辨識」（語音辨識原文）和「結果」（潤稿後貼出去的文字）。
    找出被語音辨識聽錯、而且結果裡也沒改對的詞，多半是專有名詞、英文技術詞、產品名、人名（例：report→repo、海苦→Haiku）。
    規則：
    - 只列你很有把握的：前後文清楚指向正確的詞。沒把握就不要列。
    - 一般用詞的小錯、語氣詞、標點不要列。
    - <已有> 裡已經有的對應不要再列。
    - wrong 要一字不差照紀錄裡的寫法，right 是正確寫法。
    - 同一個錯只列一次，example 放一小段出現的句子（30 字內）。
    只輸出 JSON 陣列，不要其他文字：[{"wrong":"…","right":"…","example":"…"}]
    """

    /// 最近 7 天、新的優先，最多約 3 萬字，免得太慢
    static func prompt(_ h: [HistoryItem], dict: [DictEntry], now: Date = Date()) -> String {
        var body = "", n = 0
        for x in h.sorted(by: { $0.date > $1.date }) where now.timeIntervalSince(x.date) < 7 * 86400 && !x.raw.isEmpty {
            let line = "辨識：\(x.raw)\n結果：\(x.text)\n\n"
            if n + line.count > 30000 { break }
            body += line; n += line.count
        }
        let have = dict.flatMap { e in e.heardAs.map { "\($0)→\(e.term)" } + [e.term] }.joined(separator: "、")
        return "<已有>\(have)</已有>\n<紀錄>\n\(body)</紀錄>"
    }

    /// 去最近 7 天的辨識原文找含有錯字的句子，取前後各 20 字；新的在前
    static func attach(_ items: [Item], _ h: [HistoryItem], now: Date = Date()) -> [Item] {
        let recent = h.filter { now.timeIntervalSince($0.date) < 7 * 86400 }.sorted { $0.date > $1.date }
        return items.compactMap { i in
            var x = i
            x.hits = recent.compactMap { r in
                // 英文要整個字對上：「speaking」裡的「speakin」不算
                let pat = (i.wrong.first?.isASCII == true ? "(?<![A-Za-z])" : "") + NSRegularExpression.escapedPattern(for: i.wrong) + (i.wrong.last?.isASCII == true ? "(?![A-Za-z])" : "")
                guard let rg = r.raw.range(of: pat, options: [.regularExpression, .caseInsensitive]) else { return nil }
                let a = r.raw.index(rg.lowerBound, offsetBy: -20, limitedBy: r.raw.startIndex) ?? r.raw.startIndex
                let b = r.raw.index(rg.upperBound, offsetBy: 20, limitedBy: r.raw.endIndex) ?? r.raw.endIndex
                return Hit(date: r.date, text: (a > r.raw.startIndex ? "…" : "") + r.raw[a..<b] + (b < r.raw.endIndex ? "…" : ""))
            }
            return x.hits.isEmpty ? nil : x
        }
    }

    static func parse(_ s: String, dict: [DictEntry]) -> [Item]? {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b,
              let items = try? JSONDecoder().decode([Item].self, from: Data(s[a...b].utf8)) else { return nil }
        var seen = Set<String>()
        return items.filter { i in
            !i.wrong.isEmpty && !i.right.isEmpty && i.wrong.lowercased() != i.right.lowercased()
                && !dict.contains { $0.term == i.right && $0.heardAs.contains(i.wrong) }
                && seen.insert(i.id).inserted
        }
    }

    static func find(_ h: [HistoryItem], dict: [DictEntry]) async -> [Item]? {
        guard let bin = Agent.claude.path else { return nil }
        let input = prompt(h, dict: dict)
        let out: String? = await Task.detached {
            let p = Process(), inP = Pipe(), outP = Pipe()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-p", "--model", "sonnet", "--system-prompt", rule, "--output-format", "text",
                           "--strict-mcp-config", "--tools", "", "--setting-sources", "", "--no-session-persistence"]
            p.environment = Agent.env()
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.standardInput = inP; p.standardOutput = outP; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let kill = DispatchWorkItem { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: kill)
            try? inP.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try? inP.fileHandleForWriting.close()
            let d = outP.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); kill.cancel()
            return String(data: d, encoding: .utf8)
        }.value
        return out.flatMap { parse($0, dict: dict) }
    }

    /// 你按了加入才算數，所以當成手動加的詞（auto = nil，不會 30 天後休眠）
    /// 「常被聽成」會直接換字：純中文的錯字（論文→潤稿）本身常是真的詞，只加正確詞，不設換字
    @MainActor static func add(_ s: Item, to store: Store) {
        let swap = s.wrong.contains(where: \.isASCII)
        if let i = store.dict.firstIndex(where: { $0.term == s.right }) {
            if swap, !store.dict[i].heardAs.contains(s.wrong) { store.dict[i].heardAs.append(s.wrong) }
        } else { store.dict.append(DictEntry(term: s.right, heardAs: swap ? [s.wrong] : [])) }
    }
}
