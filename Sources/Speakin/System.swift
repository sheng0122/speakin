import AppKit
import ApplicationServices

/// 全域快捷鍵：Fn（或設定裡選的右邊修飾鍵）開始/結束（三種模式見 FnMode）；⌥⇧V = 再貼一次上一句；錄音中 Esc = 取消。
/// 在硬體事件層攔截並吃掉 Fn，系統才不會拿去切換輸入法。
/// 按鍵在專用執行緒處理，主執行緒（畫面、讀輸入框）卡住也不會拖慢；拖太久系統會放行 Fn 去切輸入法。
final class Hotkey {
    var onTap: (() -> Void)?   // 在主執行緒呼叫
    var onEsc: (() -> Void)?   // 在主執行緒呼叫
    var onHold: ((HoldEvent) -> Void)?   // 按住、兩種都可以時用，在主執行緒呼叫
    var onPasteLast: (() -> Void)?   // ⌥⇧V：再貼一次上一句，在主執行緒呼叫
    enum HoldEvent { case down, up, abort }
    private var _mode = FnMode.both
    var mode: FnMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    private var _key = RecordKey.fn
    var key: RecordKey {
        get { lock.withLock { _key } }
        set { lock.withLock { _key = newValue } }
    }
    private let lock = NSLock()
    private var _recording = false
    /// 錄音中才吃掉 Esc；主執行緒寫、按鍵執行緒讀
    var recording: Bool {
        get { lock.withLock { _recording } }
        set { lock.withLock { _recording = newValue } }
    }
    private var tap: CFMachPort?
    private var fnDown: Date?
    private var otherKey = false
    private var stopPress = false   // 兩種都可以：按下時已經在錄，這一下是「結束」

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: hotkeyCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let th = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "speakin.hotkey"
        th.qualityOfService = .userInteractive
        th.start()
        return true
    }

    // 除錯用：Application Support/Speakin/keylog 存在才記錄，只記 Fn、系統鍵，不記一般打字
    private static let logURL = Store.dir.appendingPathComponent("keylog.txt")
    private static let logOn = FileManager.default.fileExists(atPath: Store.dir.appendingPathComponent("keylog").path)
    fileprivate func debugLog(_ type: CGEventType, _ e: CGEvent, _ start: UInt64, swallowed: Bool) {
        guard Self.logOn else { return }
        let kc = e.getIntegerValueField(.keyboardEventKeycode)
        let isKey = type == .keyDown || type == .keyUp
        if isKey && kc != 63 && kc != 179 { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var extra = ""
        if type.rawValue == 14, let ns = NSEvent(cgEvent: e) { extra = " subtype=\(ns.subtype.rawValue) data1=\(String(ns.data1, radix: 16))" }
        let line = "type=\(type.rawValue) kc=\(kc) flags=\(String(e.flags.rawValue, radix: 16)) 吃掉=\(swallowed) 處理us=\((now - start) / 1000) 事件已存在ms=\(Int64(now) / 1_000_000 - Int64(e.timestamp) / 1_000_000)\(extra)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: Self.logURL) }
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let r = route(type, e)
        debugLog(type, e, t0, swallowed: r == nil)
        return r
    }

    private func route(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .keyDown where e.getIntegerValueField(.keyboardEventKeycode) == 179,
             .keyUp where e.getIntegerValueField(.keyboardEventKeycode) == 179:
            return nil   // Fn 放開後系統補送的「地球鍵」，切輸入法靠的是它
        case .keyDown:
            otherKey = true
            let kc = e.getIntegerValueField(.keyboardEventKeycode), enter = [36, 76].contains(kc), now = Date()
            DispatchQueue.main.async { Learner.lastKey = now; if enter { Learner.lastEnter = now } }
            if kc == 53, recording {
                DispatchQueue.main.async { self.onEsc?() }
                return nil
            }
            let mods = e.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if kc == 9, mods == [.maskAlternate, .maskShift] {   // ⌥⇧V
                DispatchQueue.main.async { self.onPasteLast?() }
                return nil
            }
        case .keyUp where e.getIntegerValueField(.keyboardEventKeycode) == 9 && e.flags.contains([.maskAlternate, .maskShift]):
            return nil
        case .flagsChanged where e.getIntegerValueField(.keyboardEventKeycode) == key.keyCode:
            let k = key, down = k.isDown(e.flags)
            let m = mode
            if down {
                fnDown = Date(); otherKey = false; stopPress = recording
                if m != .tap, !stopPress { DispatchQueue.main.async { self.onHold?(.down) } }
            } else if let d = fnDown {
                fnDown = nil
                let short = Date().timeIntervalSince(d) < 0.3
                switch m {
                case .tap:
                    if !otherKey, Date().timeIntervalSince(d) < 0.5 { DispatchQueue.main.async { self.onTap?() } }
                case .hold:
                    // ponytail: Fn＋其他鍵（例如 Fn＋Delete）也會先開始錄音，放開時才取消；要更乾淨就延遲 0.3 秒才開始
                    let ev: HoldEvent = !otherKey && !short ? .up : .abort
                    DispatchQueue.main.async { self.onHold?(ev) }
                case .both:
                    if stopPress { if !otherKey { DispatchQueue.main.async { self.onTap?() } } }
                    else if otherKey { DispatchQueue.main.async { self.onHold?(.abort) } }
                    else if !short { DispatchQueue.main.async { self.onHold?(.up) } }
                    // 短按：繼續錄（免持），再點一下 Fn 結束
                }
            }
            return k == .fn ? nil : pass   // 吃掉 Fn 的按下和放開；右邊的修飾鍵放行，⌘C 這種組合才不會壞
        default: break
        }
        return pass
    }
}

private func hotkeyCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    Unmanaged<Hotkey>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
}

/// 貼上：放進剪貼簿 → 模擬 Cmd+V → 0.6 秒後把原本的剪貼簿還回去
enum Paster {
    /// keep = true：結果留在剪貼簿，不還原原本複製的東西
    /// enter = true：貼完再按一下 Enter 送出
    static func paste(_ text: String, keep: Bool = false, enter: Bool = false) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // 標成暫時的，Raycast、Paste 這類剪貼簿紀錄就不會存這筆
        if !keep { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        let mine = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // 等 App 把字貼進去再按 Enter，太快會先送出空白
        if enter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }   // 36 = Return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !keep, pb.changeCount == mine, !saved.isEmpty else { return }
            pb.clearContents(); pb.writeObjects(saved)
        }
    }
}

/// 潤稿參考用：游標所在輸入框，游標前 300 字＋後 100 字，遮掉個資後才回傳
enum ScreenContext {
    static func aroundCursor() -> String {
        guard let el = Learner.focused(), let v = Learner.value(el), !v.isEmpty else { return "" }
        let ns = v as NSString
        var loc = ns.length
        var r: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let rv = r {
            var cf = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &cf) { loc = min(max(0, cf.location), ns.length) }
        }
        let before = String(ns.substring(to: loc).suffix(300)), after = String(ns.substring(from: loc).prefix(100))
        return TextFix.mask(after.isEmpty ? before : before + "【游標】" + after)
    }
}

extension ScreenContext {
    /// 前景視窗裡所有看得到的字（對話、標題…），走輔助使用；最多看 5000 個元素或 1 秒
    static func window(pid: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) -> String {
        guard let pid else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var w: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w else { return "" }
        var out: [String] = [], stack = [win as! AXUIElement], seen = 0
        let start = Date()
        while let e = stack.popLast(), seen < 5000, Date().timeIntervalSince(start) < 1 {
            seen += 1
            var sub: AnyObject?
            AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sub)
            if sub as? String == kAXSecureTextFieldSubrole as String { continue }
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var v: AnyObject?
                if AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
            }
            var kids: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] { stack.append(contentsOf: k.reversed()) }
        }
        return TextFix.mask(out.joined(separator: "\n"))
    }
}

/// 學習：貼上後 15 秒再看一次輸入框，使用者改了哪些字就記成「建議加入字典」
enum Learner {
    private static var opened = Set<pid_t>()
    static var lastKey = Date.distantPast, lastEnter = Date.distantPast

    /// 先問前景 App 游標在哪個輸入框，問不到再問系統。
    /// Electron 做的 App（Orca、Slack、Notion…）不回答系統的問法，也要先送 AXManualAccessibility 才會開放文字。
    static func focused() -> AXUIElement? {
        var el: AnyObject?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            if opened.insert(pid).inserted { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
            AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &el)
        }
        if el == nil { AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &el) }
        guard let e = el else { return nil }
        let ax = e as! AXUIElement
        var role: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &role)
        return role as? String == kAXSecureTextFieldSubrole as String ? nil : ax   // 密碼欄不讀
    }

    static func value(_ e: AXUIElement) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 要在貼上「之前」呼叫。貼上後每 0.5 秒看一次輸入框，遇到這幾種情況就結算你改了什麼：
    /// 按 Enter 後 0.5 秒沒再按鍵（排除注音選字的 Enter）、改完停手 3 秒、換到別的輸入框、5 秒內完全沒動、滿 15 秒。
    /// 聊天 App 按 Enter 送出後輸入框會清空，所以用清空前最後一次看到的內容來比。
    /// 讀不到字（終端機把字畫成圖、輸入框永遠是空的）時呼叫 onBlind，請使用者改到歷史紀錄修正。
    static func watch(pasted: String, onBlind: @escaping () -> Void, onPairs: @escaping ([(String, String)]) -> Void) {
        guard let el = focused(), let pre = value(el) else { return onBlind() }
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { wait in
            // 有些 App 貼上比較慢，最多等 3 秒看到貼上的字
            tries += 1
            guard let post = value(el), post != pre else { if tries >= 12 { wait.invalidate(); onBlind() }; return }
            wait.invalidate()
            let p = zip(pre, post).prefix { $0 == $1 }.count
            let s = zip(pre.dropFirst(p).reversed(), post.dropFirst(p).reversed()).prefix { $0 == $1 }.count
            let head = String(post.prefix(p)), tail = String(post.suffix(s))
            let inserted = String(post.dropFirst(p).dropLast(s))
            let t0 = Date()
            var latest = post, changed = t0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                let now = Date()
                if let v = value(el), !v.isEmpty, v != latest, v.count >= p + s, v.hasPrefix(head), v.hasSuffix(tail) {
                    latest = v; changed = now
                }
                let sent = lastEnter > t0 && lastKey <= lastEnter && now.timeIntervalSince(lastEnter) >= 0.5
                let moved = focused().map { !CFEqual($0, el) } ?? true
                let idle = latest != post && now.timeIntervalSince(changed) >= 3
                let untouched = latest == post && lastKey < t0 && now.timeIntervalSince(t0) >= 5
                guard sent || moved || idle || untouched || now.timeIntervalSince(t0) >= 15 else { return }
                t.invalidate()
                guard latest != post else { return }
                let pairs = TextFix.diffPairs(inserted, String(latest.dropFirst(p).dropLast(s)))
                if !pairs.isEmpty { onPairs(pairs) }
            }
        }
    }
}
