import Foundation
import SQLite3

struct DictEntry: Codable, Identifiable, Hashable, Rowable {
    /// 「常被聽成」本身就是另一個字典詞的（claude 常被聽成 Cloudflare）拿掉，免得把對的詞換錯
    nonisolated static func sane(_ dict: [DictEntry]) -> [DictEntry] {
        let terms = Set(dict.map { $0.term.lowercased() })
        return dict.map { var e = $0; e.heardAs = e.heardAs.filter { !terms.contains($0.lowercased()) }; return e }
    }
    var id = UUID()
    var term: String            // 正確寫法
    var heardAs: [String] = []  // 常被聽成（辨識後直接替換）
    var auto: Bool? = nil       // 從你的修改自動學到的
    var hits: Int? = nil        // 出現在結果裡幾次
    var lastHit: Date? = nil    // 最後一次出現
    var added: Date? = Date()   // 加進字典的時間（舊的詞沒有，當成現在）

    // ponytail: 30 天半衰期、手動乘 2 都是估的起點，字典變大後用 eval 調
    func weight(_ now: Date = Date()) -> Double {
        let days = now.timeIntervalSince(lastHit ?? added ?? now) / 86400
        return (auto == true ? 1 : 2) * Double(1 + (hits ?? 0)) * pow(0.5, days / 30)
    }
    /// 自動學到、30 天沒再出現：不送進提示，但換字規則照用，再出現就醒來
    func dormant(_ now: Date = Date()) -> Bool { auto == true && now.timeIntervalSince(lastHit ?? added ?? now) > 30 * 86400 }
}

struct HistoryItem: Codable, Identifiable, Equatable, Rowable {
    var id = UUID()
    var date = Date()
    var app: String
    var raw: String
    var text: String
    var seconds: Double   // 錄音長度
    var latency: Double   // 按結束到貼上
    var session: String?  // logs 底下這次錄音的資料夾，重播、重新辨識用
    var note: String?     // 出問題時給使用者看的一句話（潤稿沒回應、辨識失敗）
}

/// tap = 按一下開始、再按一下結束；hold = 按住講、放開結束；both = 按住講放開結束，點一下就免持、再點一下結束
enum FnMode: String, Codable { case tap, hold, both }

struct Settings: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case polish, model, asrModel, context, keepClipboard, sounds, muteOthers, mic, fnMode, fnHold, historyDays, micAlwaysOn, avoidBluetooth, onboarded, smooth, autoEnter, hideDock }
    var polish = true
    var model = "auto"
    var asrModel = Store.dir.appendingPathComponent("models/TEA-ASR-1.1-Q6_K.gguf").path
    var context = true   // 把游標附近的文字（遮掉個資後）一起給潤稿參考
    var keepClipboard = false   // 貼上後把結果留在剪貼簿（不還原原本複製的東西）
    var sounds = true   // 開始、結束、出錯、學到新詞時的提示音
    var muteOthers = true   // 錄音時把其他聲音靜音（音樂、影片）
    var mic: String? = nil   // 麥克風 UID，nil = 跟系統設定
    var fnMode = FnMode.both
    var historyDays: Int? = nil   // 歷史和錄音留幾天；nil = 一直留，0 = 不存
    var micAlwaysOn = false   // 麥克風常開：按下前 0.45 秒也收得到，句首不漏字（橘點會一直亮）
    var onboarded = false   // 走完第一次的引導
    var avoidBluetooth = true   // 系統預設是藍牙耳機時改用內建麥克風（AirPods 才不會切成通話音質）
    var autoEnter = false   // 貼上後自動按 Enter 送出
    var hideDock = false    // 不在 Dock 顯示，只留選單列圖示
    var smooth = false   // 潤稿模式：false = 忠於原話，true = 理順句子（比較像 Typeless）

    init() {}
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(polish, forKey: .polish); try c.encode(model, forKey: .model); try c.encode(asrModel, forKey: .asrModel)
        try c.encode(context, forKey: .context); try c.encode(keepClipboard, forKey: .keepClipboard); try c.encode(sounds, forKey: .sounds)
        try c.encode(muteOthers, forKey: .muteOthers); try c.encodeIfPresent(mic, forKey: .mic); try c.encode(fnMode, forKey: .fnMode)
        try c.encodeIfPresent(historyDays, forKey: .historyDays); try c.encode(micAlwaysOn, forKey: .micAlwaysOn)
        try c.encode(avoidBluetooth, forKey: .avoidBluetooth); try c.encode(onboarded, forKey: .onboarded); try c.encode(smooth, forKey: .smooth)
        try c.encode(autoEnter, forKey: .autoEnter); try c.encode(hideDock, forKey: .hideDock)
    }
    /// 舊的 settings.json 少了新欄位時用預設值，不要整份設定作廢
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), x = Settings()
        polish = try c.decodeIfPresent(Bool.self, forKey: .polish) ?? x.polish
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? x.model
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel).flatMap { $0.hasSuffix(".gguf") ? $0 : nil } ?? x.asrModel   // 舊的 whisper .bin 新引擎讀不了
        context = try c.decodeIfPresent(Bool.self, forKey: .context) ?? x.context
        keepClipboard = try c.decodeIfPresent(Bool.self, forKey: .keepClipboard) ?? x.keepClipboard
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? x.sounds
        muteOthers = try c.decodeIfPresent(Bool.self, forKey: .muteOthers) ?? x.muteOthers
        mic = try c.decodeIfPresent(String.self, forKey: .mic)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? x.smooth
        autoEnter = try c.decodeIfPresent(Bool.self, forKey: .autoEnter) ?? x.autoEnter
        hideDock = try c.decodeIfPresent(Bool.self, forKey: .hideDock) ?? x.hideDock
        // 舊設定只有 fnHold：照原本的習慣，不偷換
        fnMode = try c.decodeIfPresent(FnMode.self, forKey: .fnMode) ?? (try c.decodeIfPresent(Bool.self, forKey: .fnHold)).map { $0 ? .hold : .tap } ?? x.fnMode
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays)
        micAlwaysOn = try c.decodeIfPresent(Bool.self, forKey: .micAlwaysOn) ?? x.micAlwaysOn
        avoidBluetooth = try c.decodeIfPresent(Bool.self, forKey: .avoidBluetooth) ?? x.avoidBluetooth
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? true   // 有舊設定檔 = 已經在用了，不再引導
    }
}

// 紀錄和字典在 SQLite（data.sqlite），不限筆數；設定是小 JSON 檔，壞了可以直接打開改
@MainActor final class Store: ObservableObject {
    static let shared = Store()
    nonisolated static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("Speakin"), old = base.appendingPathComponent("Utter")
        // 舊名 Utter 的資料（設定、紀錄、1.7 GB 模型）整包搬過來；舊位置留捷徑，設定檔裡寫死的舊路徑照樣找得到
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path), (try? fm.moveItem(at: old, to: new)) != nil {
            try? fm.createSymbolicLink(at: old, withDestinationURL: new)
        }
        return new
    }()
    let dir = Store.dir

    @Published var dict: [DictEntry] { didSet { db.sync(old: oldValue, new: dict) } }
    @Published var lastLearned: [(wrong: String, right: String)] = []
    @Published var history: [HistoryItem] { didSet { db.sync(old: oldValue, new: history) } }
    private let db: DB
    @Published var settings: Settings { didSet { save("settings", settings) } }

    init() {
        let dir = self.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func load<T: Decodable>(_ name: String) -> T? {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(name + ".json")) else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
        let db = DB(dir.appendingPathComponent("data.sqlite"))
        self.db = db
        // 第一次開：從舊的 JSON 搬進來（原檔留著當備份）
        func open<T: Rowable>(_ name: String, _ fallback: [T]) -> [T] {
            let rows: [T] = db.all()
            guard rows.isEmpty else { return rows }
            let old: [T] = load(name) ?? fallback
            db.sync(old: [], new: old)
            return old
        }
        dict = open("dict", [])   // 新使用者字典是空的，自己加
        history = open("history", [])
        settings = load("settings") ?? Settings()
    }

    private func save<T: Encodable>(_ name: String, _ v: T) {
        let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
        try? e.encode(v).write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
    }

    /// 除錯紀錄：每次錄音一個資料夾（每段錄音＋log.txt），只存在這台電腦，7 天後自動刪
    nonisolated static let logDir = dir.appendingPathComponent("logs")

    /// 設成「不存」就連錄音資料夾一起刪；有設天數就順便清掉過期的
    func addHistory(_ h: HistoryItem) {
        if settings.historyDays == 0 {
            if let s = h.session { try? FileManager.default.removeItem(at: Store.logDir.appendingPathComponent(s)) }
            return
        }
        history.append(h)
        pruneHistory()
    }

    /// 刪紀錄連錄音資料夾一起刪；ids 給 nil 就是全部清掉
    func deleteHistory(_ ids: Set<UUID>? = nil) {
        let gone = history.filter { ids?.contains($0.id) ?? true }
        for h in gone { if let s = h.session { try? FileManager.default.removeItem(at: Store.logDir.appendingPathComponent(s)) } }
        history.removeAll { ids?.contains($0.id) ?? true }
    }

    func pruneHistory() {
        guard let days = settings.historyDays else { return }
        let cut = Date().addingTimeInterval(-Double(days) * 86400)
        if history.contains(where: { $0.date < cut }) { history.removeAll { $0.date < cut } }
        SessionLog.prune(olderThan: cut)
    }

    /// 一行一個詞（CSV 取第一欄），已經有的跳過，回傳新加了幾個
    @discardableResult func importWords(_ text: String) -> Int {
        let new = Self.newWords(text, have: dict.map(\.term))
        if !new.isEmpty { dict += new.map { DictEntry(term: $0) } }
        return new.count
    }

    nonisolated static func newWords(_ text: String, have: [String]) -> [String] {
        var seen = Set(have.map { $0.lowercased() })
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let w = (line.split(separator: ",").first.map(String.init) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\u{FEFF}"))
            return !w.isEmpty && w.count <= 40 && seen.insert(w.lowercased()).inserted ? w : nil
        }
    }

    /// 學到的直接進字典，回傳這次新加的，給通知和「復原」用
    func learn(_ pairs: [(String, String)]) -> [(wrong: String, right: String)] {
        var added: [(wrong: String, right: String)] = []
        for (w, r) in pairs where r.count >= 2 && w.lowercased() != r.lowercased() && Self.looksLikeFix(w, r) {
            if let i = dict.firstIndex(where: { $0.term == r }) {
                if dict[i].heardAs.contains(w) { continue }
                dict[i].heardAs.append(w)
            } else { dict.append(DictEntry(term: r, heardAs: [w], auto: true)) }
            added.append((w, r))
        }
        if !added.isEmpty { lastLearned = added }
        return added
    }

    /// 純中文的改動多半是改寫句子，不是聽錯字：要長度一樣、只差一半以內的字才算（電子房→電子版）
    nonisolated static func looksLikeFix(_ w: String, _ r: String) -> Bool {
        guard !(w + r).contains(where: \.isASCII) else { return true }
        guard w.count == r.count else { return false }
        return zip(w, r).filter { $0 != $1 }.count <= max(1, r.count / 2)
    }

    func undoLearned() {
        for (w, r) in lastLearned {
            guard let i = dict.firstIndex(where: { $0.term == r }) else { continue }
            dict[i].heardAs.removeAll { $0 == w }
            if dict[i].auto == true, dict[i].heardAs.isEmpty { dict.remove(at: i) }
        }
        lastLearned = []
    }

    /// 給 Breeze 和潤稿模型看的專有名詞清單
    var terms: String { asrTerms }

    /// 辨識提示：權重最高的 20 個（提示太長辨識會照抄詞）
    var asrTerms: String { Self.asrTerms(dict) }
    nonisolated static func asrTerms(_ dict: [DictEntry]) -> String {
        dict.filter { !$0.dormant() }.sorted { $0.weight() > $1.weight() }.prefix(20).map(\.term).joined(separator: "、")
    }

    /// 潤稿提示：這段話裡真的出現的詞，加上最常用的 5 個；字典再大，模型一次也只看到幾個
    func polishTerms(for text: String) -> String { Self.polishTerms(dict, for: text) }
    nonisolated static func polishTerms(_ dict: [DictEntry], for text: String) -> String {
        let dict = DictEntry.sane(dict)
        let live = dict.filter { !$0.dormant() }.sorted { $0.weight() > $1.weight() }
        let hit = dict.filter { e in ([e.term] + e.heardAs).contains { text.localizedCaseInsensitiveContains($0) } }
        var seen = Set<String>()
        // 連「常被聽成」一起給，模型才認得出沒被字典替換抓到的近似寫法
        return (hit + live.prefix(5)).filter { seen.insert($0.term).inserted }
            .map { $0.heardAs.isEmpty ? $0.term : "\($0.term)（常被聽成 \($0.heardAs.joined(separator: "/"))）" }.joined(separator: "、")
    }

    /// 搜尋紀錄：打字典裡的正確寫法，也找得到當時被聽成別的字的那幾筆
    nonisolated static func matches(_ h: HistoryItem, _ q: String, _ dict: [DictEntry]) -> Bool {
        if q.isEmpty { return true }
        let alt = dict.first { $0.term.localizedCaseInsensitiveCompare(q) == .orderedSame }?.heardAs ?? []
        return ([q] + alt).contains { h.text.localizedCaseInsensitiveContains($0) || h.raw.localizedCaseInsensitiveContains($0) } || h.app.localizedCaseInsensitiveContains(q)
    }

    /// 結果裡出現的詞記一次使用，權重往上、休眠的醒來
    func markHits(_ text: String) {
        var d = dict, changed = false
        for i in d.indices where text.localizedCaseInsensitiveContains(d[i].term) {
            d[i].hits = (d[i].hits ?? 0) + 1; d[i].lastHit = Date(); changed = true
        }
        if changed { dict = d }
    }
}

@MainActor final class SessionLog {
    private var dir: URL?
    private var t0 = Date()

    func start(_ note: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        let d = Store.logDir.appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d; t0 = Date()
        line(note)
    }

    func line(_ s: String) {
        guard let d = dir else { return }
        let u = d.appendingPathComponent("log.txt"), l = Data((String(format: "[%6.2f] ", Date().timeIntervalSince(t0)) + s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(l); try? h.close() } else { try? l.write(to: u) }
    }

    func audio(_ name: String, _ s: [Float]) {
        if let d = dir { try? Segmenter.wav(s).write(to: d.appendingPathComponent(name)) }
    }

    /// 錄音當下的畫面另存一份，之後才能重播比較「給畫面」有沒有幫助；跟錄音一樣只留在本機
    func text(_ name: String, _ s: String) {
        if let d = dir { try? s.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    var path: String { dir?.path ?? "" }
    var name: String? { dir?.lastPathComponent }

    /// 這筆紀錄的錄音段落；舊紀錄沒存資料夾名，用開始時間對（資料夾名就是開始時間）
    nonisolated static func segments(_ h: HistoryItem) -> [[Float]] {
        let fm = FileManager.default
        var name = h.session
        if name == nil {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
            let start = h.date.addingTimeInterval(-h.seconds - h.latency)
            name = ((try? fm.contentsOfDirectory(atPath: Store.logDir.path)) ?? [])
                .first { f.date(from: $0).map { abs($0.timeIntervalSince(start)) < 3 } ?? false }
        }
        guard let n = name else { return [] }
        let d = Store.logDir.appendingPathComponent(n)
        return ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix("seg") && $0.hasSuffix(".wav") }.sorted()
            .compactMap { fm.contents(atPath: d.appendingPathComponent($0).path).flatMap(Segmenter.samples) }
    }

    /// 刪掉比 cut 早開始的錄音資料夾（資料夾名就是開始時間）
    nonisolated static func prune(olderThan cut: Date, in root: URL = Store.logDir) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        for n in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            if let d = f.date(from: n), d < cut { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
        }
    }

    /// 錄音資料夾超過 2 GB 就從最舊的刪到 1.5 GB（大約一兩個月的錄音）
    nonisolated static func prune(limit: Int = 2 << 30, to target: Int = 3 << 29, in root: URL = Store.logDir) {
        let fm = FileManager.default, keys: [URLResourceKey] = [.creationDateKey, .totalFileAllocatedSizeKey]
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []).map { d -> (URL, Date, Int) in
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys)) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0) }
            return (d, (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, size)
        }.sorted { $0.1 < $1.1 }
        var total = dirs.reduce(0) { $0 + $1.2 }
        guard total > limit else { return }
        for (d, _, size) in dirs where total > target { try? fm.removeItem(at: d); total -= size }
    }
}

/// 存進資料庫的東西：一種一張表，整筆用 JSON 存（加欄位不用改表），另外拉出日期和字數給統計用
protocol Rowable: Codable, Identifiable, Equatable where ID == UUID {
    static var table: String { get }
    var sortKey: Double { get }
    var words: Int { get }
}
extension HistoryItem { static let table = "history"; var sortKey: Double { date.timeIntervalSince1970 }; var words: Int { TextFix.wordCount(text) } }
extension DictEntry { static let table = "dict"; var sortKey: Double { 0 }; var words: Int { 0 } }

final class DB {
    private var db: OpaquePointer?

    init(_ url: URL) {
        sqlite3_open(url.path, &db)
        for t in [HistoryItem.table, DictEntry.table] {
            exec("CREATE TABLE IF NOT EXISTS \(t) (id TEXT PRIMARY KEY, n INTEGER, sort REAL, words INTEGER, json BLOB)")
        }
        exec("CREATE INDEX IF NOT EXISTS history_sort ON history(sort)")
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func all<T: Rowable>() -> [T] {
        var st: OpaquePointer?, out: [T] = []
        sqlite3_prepare_v2(db, "SELECT json FROM \(T.table) ORDER BY sort, n", -1, &st, nil)
        while sqlite3_step(st) == SQLITE_ROW {
            let d = Data(bytes: sqlite3_column_blob(st, 0), count: Int(sqlite3_column_bytes(st, 0)))
            if let h = try? JSONDecoder().decode(T.self, from: d) { out.append(h) }
        }
        sqlite3_finalize(st)
        return out
    }

    /// 只寫有變的那幾筆：新增或改過的寫入，不見的刪掉；n 記陣列順序，讀回來順序不變
    func sync<T: Rowable>(old: [T], new: [T]) {
        let before = Dictionary(old.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { $1 })
        let now = Set(new.map(\.id))
        let changed = new.enumerated().filter { i, x in before[x.id].map { $0.0 != i || $0.1 != x } ?? true }
        let gone = old.filter { !now.contains($0.id) }
        guard !changed.isEmpty || !gone.isEmpty else { return }
        let T_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT：叫 SQLite 自己複製一份
        exec("BEGIN")
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO \(T.table) VALUES (?,?,?,?,?)", -1, &st, nil)
        for (i, x) in changed {
            let j = (try? JSONEncoder().encode(x)) ?? Data()
            sqlite3_bind_text(st, 1, x.id.uuidString, -1, T_)
            sqlite3_bind_int(st, 2, Int32(i))
            sqlite3_bind_double(st, 3, x.sortKey)
            sqlite3_bind_int(st, 4, Int32(x.words))
            _ = j.withUnsafeBytes { sqlite3_bind_blob(st, 5, $0.baseAddress, Int32(j.count), T_) }
            sqlite3_step(st); sqlite3_reset(st)
        }
        sqlite3_finalize(st)
        sqlite3_prepare_v2(db, "DELETE FROM \(T.table) WHERE id = ?", -1, &st, nil)
        for x in gone { sqlite3_bind_text(st, 1, x.id.uuidString, -1, T_); sqlite3_step(st); sqlite3_reset(st) }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
}
