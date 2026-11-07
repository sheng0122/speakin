import Foundation

/// 純文字邏輯：字典替換、從使用者修改找出「錯→對」
enum TextFix {
    /// 講者明說「剛剛那句不要、這句刪掉」時，在潤稿前直接把那句和指令一起刪掉（AI 常刪錯邊）。
    /// 那句 = 指令前面最近的停頓（標點、空白）或連接詞（然後、還有…）到指令為止；找不到界線又太長就不動，交給潤稿。
    static let retract = try! NSRegularExpression(pattern: "(算了|欸|呃|啊)?(剛剛|剛才|前面|上)(那|一)?句(話)?(不要|刪掉|不算|拿掉)(了|啦|喔)?(?!或|這種|之類|的)|(算了|欸|呃|啊)?這句(話)?(不要|刪掉|不算|拿掉)(了|啦|喔)?(?!或|這種|之類|的)")
    static let clauseStart = try! NSRegularExpression(pattern: "[，。！？,.!? ]|然後|還有|另外|順便|而且|因為|所以|但是")
    static func dropRetracted(_ text: String) -> String {
        var t = text as NSString
        while let m = retract.firstMatch(in: t as String, range: NSRange(location: 0, length: t.length)) {
            let from = max(0, m.range.location - 60)
            let b = clauseStart.matches(in: t as String, range: NSRange(location: from, length: m.range.location - from))
                .last { $0.range.location + $0.range.length < m.range.location }   // 界線後面要真的有字
            var start: Int
            if let b {
                // 標點留著當句子分隔，連接詞連同那句一起刪
                start = t.substring(with: b.range).rangeOfCharacter(from: .punctuationCharacters.union(.whitespaces)) != nil ? b.range.location + b.range.length : b.range.location
                // 「然後順便」這種連在一起的連接詞一起刪
                while start > 0, let c = clauseStart.firstMatch(in: t as String, range: NSRange(location: max(0, start - 2), length: min(2, start))),
                      c.range.location + c.range.length == start, t.substring(with: c.range).count == 2 { start = c.range.location }
            } else if m.range.location <= 40 { start = 0 }
            else { break }
            t = t.replacingCharacters(in: NSRange(location: start, length: m.range.location + m.range.length - start), with: "") as NSString
        }
        return (t as String).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 所有詞一次掃過去、長的先比：一條一條換的話，「Claude」會把已經對的「Claude Code」再換成「Claude Code Code」（#3）
    static func applyDict(_ s: String, _ dict: [DictEntry]) -> String {
        var to: [String: String] = [:]   // 小寫的寫法 → 正確寫法；同一個寫法先出現的算
        for e in DictEntry.sane(dict) { for w in [e.term] + e.heardAs where !w.isEmpty { to[w.lowercased()] = to[w.lowercased()] ?? e.term } }
        guard !to.isEmpty else { return s }
        let alts = to.keys.sorted { $0.count > $1.count }.map { w in
            let esc = NSRegularExpression.escapedPattern(for: w)
            // 英文詞要整字比對，免得 online 變 onLINE
            return w.unicodeScalars.allSatisfy(\.isASCII) ? "(?<![A-Za-z])\(esc)(?![A-Za-z])" : esc
        }
        guard let re = try? NSRegularExpression(pattern: alts.joined(separator: "|"), options: .caseInsensitive) else { return s }
        let ns = s as NSString, out = NSMutableString()
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            let hit = ns.substring(with: m.range)
            out.append(to[hit.lowercased()] ?? hit)
            at = m.range.location + m.range.length
        }
        out.append(ns.substring(from: at))
        return out as String
    }

    /// 辨識卡住一直重複同一小段（「好的好的好的好的」「我們我們我們我們」）：2～8 個字連續出現 4 次以上
    static let loop = try! NSRegularExpression(pattern: "(.{2,8}?)\\1{3,}")
    static func looping(_ s: String) -> Bool {
        loop.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    /// 重複的只留一次
    static func unloop(_ s: String) -> String {
        loop.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
    }

    static let junk = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)

    /// 比對貼上的文字和使用者改過的文字，回傳每一處「原本 → 改成」。
    /// 兩段差太多（像是清空後打了別的話）就不算。
    static func diffPairs(_ a: String, _ b: String) -> [(String, String)] {
        let x = Array(a.prefix(400)), y = Array(b.prefix(400))
        let n = x.count, m = y.count
        guard n > 0, m > 0 else { return [] }
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = x[i] == y[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        guard Double(L[0][0]) >= 0.6 * Double(n) else { return [] }
        // 先切成「一樣的段」和「改過的段」
        enum Seg { case same(String), diff(String, String) }
        var segs: [Seg] = [], i = 0, j = 0, same = "", del = "", ins = ""
        func cut() {
            if !del.isEmpty || !ins.isEmpty { if !same.isEmpty { segs.append(.same(same)) }; same = ""; segs.append(.diff(del, ins)); del = ""; ins = "" }
        }
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { cut(); same.append(x[i]); i += 1; j += 1 }
            else if j < m, i == n || L[i][j + 1] >= L[i + 1][j] { ins.append(y[j]); j += 1 }
            else { del.append(x[i]); i += 1 }
        }
        cut(); if !same.isEmpty { segs.append(.same(same)) }
        // 英文要整個字一起算：cloud floor → Cloudflare，不是 c→C、oo→a。
        // 中文改單一個字時帶上前後字：電子房 → 電子版，不是 房→版（單字拿去替換太危險）
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        func cjk(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }
        for k in segs.indices {
            guard case .diff(var d, var a) = segs[k] else { continue }
            var before = k > 0 ? { if case .same(let t) = segs[k - 1] { return t } else { return "" } }() : ""
            var after = k + 1 < segs.count ? { if case .same(let t) = segs[k + 1] { return t } else { return "" } }() : ""
            // 改的地方緊貼著英文字（中間沒有空白），就把整個字帶進來
            func solid(_ c: Character?) -> Bool { c.map { !$0.isWhitespace } ?? false }
            if solid(d.first) || solid(a.first) { while let c = before.last, word(c) { d.insert(c, at: d.startIndex); a.insert(c, at: a.startIndex); before.removeLast() } }
            if solid(d.last) || solid(a.last) { while let c = after.first, word(c) { d.append(c); a.append(c); after.removeFirst() } }
            while a.count < 3, let c = before.last, cjk(c), (a + d).contains(where: cjk) { d.insert(c, at: d.startIndex); a.insert(c, at: a.startIndex); before.removeLast() }
            while a.count < 3, let c = after.first, cjk(c), (a + d).contains(where: cjk) { d.append(c); a.append(c); after.removeFirst() }
            segs[k] = .diff(d, a)
            if k > 0, case .same = segs[k - 1] { segs[k - 1] = .same(before) }
            if k + 1 < segs.count, case .same = segs[k + 1] { segs[k + 1] = .same(after) }
        }
        // 中間只剩空的或同一個英文字的一部分，就併成一處
        var out: [(String, String)] = []
        var gap = ""
        for sg in segs {
            switch sg {
            case .same(let t): gap = t
            case .diff(let d, let a):
                if let last = out.last, gap.allSatisfy(word) { out[out.count - 1] = (last.0 + gap + d, last.1 + gap + a) }
                else { out.append((d, a)) }
                gap = "\u{0}"
            }
        }
        return out.map { ($0.0.trimmingCharacters(in: junk), $0.1.trimmingCharacters(in: junk)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty && $0.0.count <= 16 && $0.1.count <= 16 }
    }

    /// 送出前在本機遮掉明顯的個資和金鑰
    static let masks: [(String, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        (#"(sk-|sk_|ghp_|gho_|xox[abp]-|AIza|AKIA|eyJ)[A-Za-z0-9_\-.]{10,}"#, "[金鑰]"),
        (#"[A-Za-z0-9_\-]{32,}"#, "[金鑰]"),
        (#"(?<![A-Za-z0-9])[A-Z][12]\d{8}(?!\d)"#, "[身分證]"),
        (#"(?<!\d)(?:\d[ -]?){13,19}(?<=\d)(?!\d)"#, "[卡號]"),
        (#"(?<!\d)(?:\+?886[ -]?|0)9\d{2}[ -]?\d{3}[ -]?\d{3}(?!\d)"#, "[電話]"),
    ]
    static func mask(_ s: String) -> String {
        masks.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }

    /// 潤稿結果是不是還是「同一段話」：結果裡的字（不算標點）至少 7 成要能依序在原文找到。
    /// 擋掉拒絕訊息、把字典或規則寫進結果、自己多寫內容這類情況。
    /// 講者改口、收回自己剛說的話時會講的字
    static let backtrack = ["剛剛那", "這句", "那句", "算了", "不對", "不是啦", "我是說", "等等", "改成", "不用了", "不要了"]
    static func plausible(_ input: String, _ output: String) -> Bool {
        let keep: (Character) -> Bool = { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        // 一串數字（國字或阿拉伯）當成一個字，「十月二十九」改成「10 月 29」才不會被當成亂改
        let num = { (s: String) in s.replacingOccurrences(of: "[0-9０-９零一二三四五六七八九十百千萬兩.:：]+", with: "#", options: .regularExpression) }
        let x = Array(num(input.lowercased().filter(keep)).prefix(600)), y = Array(num(output.lowercased().filter(keep)).prefix(600))
        guard !y.isEmpty else { return false }
        guard !x.isEmpty else { return false }
        var prev = [Int](repeating: 0, count: y.count + 1)
        for i in 0..<x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            for j in 0..<y.count { cur[j + 1] = x[i] == y[j] ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        // 不能亂加（輸出 7 成以上來自原文），也不能整段漏掉（贅字可以刪，但最多刪 4 成或 8 個字；有改口、收回時放寬到 6 成或 20 字）
        let common = Double(prev[y.count]), fixing = backtrack.contains { input.contains($0) }
        return common >= 0.7 * Double(y.count) && Double(x.count) - common <= (fixing ? max(20, 0.6 * Double(x.count)) : max(8, 0.4 * Double(x.count)))
    }

    /// 長文切成幾塊分開潤稿：一次潤太長，Haiku 會刪句、改寫成重點，甚至開始回答內容。
    /// 超過 100 字就切；湊到 50 字後，在「然後、所以、但是」這類轉折詞或句號前切，一塊最多 100 字。
    /// 2026-11-06 用 402 筆紀錄重測：超過 100 字的，整段送只有 6/25 整理好，切成 50～100 字有 23/25。
    static let turn = try! NSRegularExpression(pattern: "(?<=[^，。、 ])(?=然後|那我|那你|那如果|所以|但是|另外|因為|如果|接下來)|(?<=[。？！])")
    static func chunks(_ text: String, min: Int = 50, max: Int = 100, long: Int = 100) -> [String] {
        let s = Array(text)
        guard s.count > long else { return [text] }
        let ns = text as NSString
        // 轉折位置換成字元位置（NSString 用 UTF-16，中文和英文都是 1，表情符號才會不同）
        let marks = turn.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { String(ns.substring(to: $0.range.location)).count }
        // 改口、收回要跟被改的話在同一塊，潤稿才知道要刪哪句
        func free(_ i: Int) -> Bool { let t = String(s[i..<Swift.min(i + 3, s.count)]); return !backtrack.contains { t.hasPrefix($0) } }
        var out: [String] = [], start = 0
        while s.count - start > max {
            let ok = marks.filter { $0 >= start + 40 && $0 - start <= max && free($0) }
            let soft = (start + 40..<start + max).last { " ，、".contains(s[$0]) && free($0 + 1) }.map { $0 + 1 }
            let cut = ok.first { $0 - start >= min } ?? ok.last ?? soft ?? start + max
            out.append(String(s[start..<cut])); start = cut
        }
        out.append(String(s[start...]))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 分塊潤完接回去：每塊各自成段會在句子中間斷行，所以湊滿 150 字才換段；塊裡本來的分段、清單照留
    static func joinParts(_ parts: [String]) -> String {
        var out = "", prev = ""
        for p in parts {
            let lastPara = out.components(separatedBy: "\n").last ?? ""
            let newPara = !out.isEmpty && (lastPara.count >= 150 || p.contains("\n") || prev.contains("\n"))
            out += (newPara ? "\n\n" : "") + p
            prev = p
        }
        return out
    }

    /// 中文和英文、數字之間補一個空白（「用Claude寫3段」→「用 Claude 寫 3 段」）。模型常漏，用程式補才穩。
    /// 短句不潤稿，不會補標點：句尾是一定是問句的字就補問號。「呢」「要不要」不算（「寫得很差呢」「可以選要不要」）
    static func question(_ s: String) -> String {
        ["嗎", "是不是", "對不對", "好不好", "有沒有", "為什麼"].contains(where: s.hasSuffix) ? s + "？" : s
    }

    static func space(_ s: String) -> String {
        s.replacingOccurrences(of: #"(\p{Han})([A-Za-z0-9])"#, with: "$1 $2", options: .regularExpression)
         .replacingOccurrences(of: #"([A-Za-z0-9%])(\p{Han})"#, with: "$1 $2", options: .regularExpression)
    }

    static func wordCount(_ s: String) -> Int { s.filter { !$0.isWhitespace && !$0.isPunctuation }.count }
}
