import AppKit

/// 檢查新版：讀 Info.plist 的 SpeakinUpdateURL（latest.json：{"version":"0.3","url":"…/Speakin.dmg"}）。
/// 有新版就在背景下載 DMG、取出 Speakin.app、驗證是我們的 Developer ID 簽的，再請使用者按「重開完成更新」。
// ponytail: 自己換檔，不用 Sparkle；沒有差量更新、沒有 EdDSA 簽章（靠 Apple 簽章驗證），要做再接 Sparkle
enum Updater {
    struct Release: Decodable, Equatable { let version: String; let url: URL }
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "開發版"
    static let url = (Bundle.main.infoDictionary?["SpeakinUpdateURL"] as? String).flatMap(URL.init(string:))

    static func newer() async -> Release? {
        guard let url, let (d, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: d) else { return nil }
        return isNewer(rel.version, than: current) ? rel : nil
    }

    /// 0.10 比 0.9 新：一段一段比數字
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 下載並取出新版，簽章不對就回 nil
    static func stage(_ r: Release) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakinUpdate-\(r.version)")
        let app = dir.appendingPathComponent("Speakin.app"), mnt = dir.appendingPathComponent("mnt")
        if verified(app) { return app }
        try? FileManager.default.removeItem(at: dir)
        guard (try? FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)) != nil,
              let (dmg, resp) = try? await URLSession.shared.download(from: r.url), (resp as? HTTPURLResponse)?.statusCode == 200,
              sh("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mnt.path, dmg.path) else { return nil }
        let ok = sh("/usr/bin/ditto", mnt.appendingPathComponent("Speakin.app").path, app.path)
        _ = sh("/usr/bin/hdiutil", "detach", "-force", mnt.path)
        try? FileManager.default.removeItem(at: dmg)
        return ok && verified(app) ? app : nil
    }

    /// 一定要是 Apple 發的、我們團隊（R39P3Y27B7）的 Developer ID 簽的，才准換上去
    static func verified(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.path) &&
        sh("/usr/bin/codesign", "--verify", "--deep", "--strict",
           "-R=anchor apple generic and certificate leaf[subject.OU] = \"R39P3Y27B7\"", app.path)
    }

    /// 等自己結束 → 新版先複製到旁邊 → 成功才刪舊版換上 → 重新打開；複製失敗就打開舊版
    static func install(_ app: URL) {
        let dest = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
            rm -rf "$DEST.new"
            if /usr/bin/ditto "$NEW" "$DEST.new"; then rm -rf "$DEST" && mv "$DEST.new" "$DEST"; fi
            open "$DEST"
            """]
        p.environment = ["PID": "\(getpid())", "DEST": dest, "NEW": app.path]
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func sh(_ cmd: String, _ args: String...) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
}
