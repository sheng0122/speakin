import AVFoundation
import CoreAudio
import IOKit

/// 系統輸出的靜音開關（錄音時把其他聲音關掉）；有些輸出裝置不支援靜音，那就什麼都不做
enum SystemAudio {
    private static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static var output: AudioObjectID {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size), a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }
    /// 所有麥克風（UID, 名字）
    static var inputs: [(uid: String, name: String)] {
        var a = addr(kAudioHardwarePropertyDevices), size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var sa = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput), n = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &n) == noErr, n > 0 else { return nil }
            func str(_ sel: AudioObjectPropertySelector) -> String? {
                var p = addr(sel), v: Unmanaged<CFString>?, sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &p, 0, nil, &sz, &v) == noErr, let v else { return nil }
                return v.takeRetainedValue() as String
            }
            guard let uid = str(kAudioDevicePropertyDeviceUID), let name = str(kAudioObjectPropertyName) else { return nil }
            return (uid, name)
        }
    }

    static var defaultInput: AudioDeviceID? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size), a = addr(kAudioHardwarePropertyDefaultInputDevice)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType), v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v
    }
    static func isBluetooth(_ id: AudioDeviceID) -> Bool { [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(id)) }
    /// 內建麥克風；螢幕蓋著（接外接螢幕）時內建麥克風收不到聲音，當作沒有
    static var builtInInput: AudioDeviceID? {
        if lidClosed { return nil }
        return inputs.lazy.compactMap { device(uid: $0.uid) }.first { transport($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }

    /// 這次要用哪支麥克風：指定的（沒接就跟系統）；跟系統時遇到藍牙耳機改用內建的
    static func pick(mic: String?, avoidBluetooth: Bool) -> AudioDeviceID? {
        if let id = mic.flatMap(device(uid:)) { return id }
        guard let d = defaultInput else { return nil }
        return avoidBluetooth && isBluetooth(d) ? builtInInput ?? d : d
    }

    static func name(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName), v: Unmanaged<CFString>?, sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr, let v else { return "?" }
        return v.takeRetainedValue() as String
    }

    static func device(uid: String) -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice), id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cf = uid as CFString
        let ok = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return ok == noErr && id != 0 ? id : nil
    }

    private static var mutedDevice: AudioObjectID?   // 我們靜音的是哪個輸出；錄音中換了輸出裝置，還原時才不會還原錯的那個
    static var muted: Bool {
        get {
            var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size), a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
            return AudioObjectGetPropertyData(output, &a, 0, nil, &size, &v) == noErr && v == 1
        }
        set {
            let dev = newValue ? output : mutedDevice ?? output
            mutedDevice = newValue ? dev : nil
            var v = UInt32(newValue ? 1 : 0), a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        }
    }
}

/// 麥克風 → 16 kHz 單聲道 Float
final class Recorder {
    private var engine = AVAudioEngine()
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var mono: AVAudioFormat?
    var onSamples: (([Float]) -> Void)?   // 在音訊執行緒呼叫
    var onChange: (() -> Void)?           // 裝置變了（AirPods 連上、換麥克風、睡醒），系統會自己把 engine 停掉；在主執行緒呼叫
    /// 看 engine 真的有沒有在跑：被系統停掉時自己記的旗標還是 true，就再也不會重開（#1）
    var running: Bool { engine.isRunning }
    private(set) var deviceName = ""   // 這次開的是哪支麥克風，寫進紀錄

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVAudioEngine) === self.engine else { return }
            self.onChange?()
        }
    }

    /// mic：麥克風 UID；沒選或那支被拔掉就用系統預設
    func start(mic: String? = nil, avoidBluetooth: Bool = false) throws {
        stop()
        // 每次換一個新的 engine：綁過某支麥克風的 engine 會一直綁著，改回「跟系統設定」時換不回來
        engine = AVAudioEngine()
        let input = engine.inputNode
        let want = SystemAudio.pick(mic: mic, avoidBluetooth: avoidBluetooth), def = SystemAudio.defaultInput
        deviceName = (want ?? def).map(SystemAudio.name) ?? "?"
        // 就是系統預設那支就不要指定：直接綁藍牙麥克風（AirPods）會開不起來或一直沒聲音，
        // 跟著系統預設走才正常（2026-11-07 實測：綁定 3 秒收到 0 秒，不綁 2.9 秒）。只有要用別支時才綁
        if var id = want, id != def, let au = input.audioUnit {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFmt = input.outputFormat(forBus: 0)
        // 裝置切換到一半時格式會是 0 Hz／0 聲道，拿去裝 tap 會直接當掉；先回報失敗，看門狗等一下會再試
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw Err("麥克風還沒準備好") }
        // 只拿第一個聲道再轉：多聲道錄音介面（6 聲道這種）直接丟給 converter 可能整段變成 0
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate, channels: 1, interleaved: false)
        converter = mono.flatMap { AVAudioConverter(from: $0, to: outFmt) }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in self?.convert(buf) }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ multi: AVAudioPCMBuffer) {
        guard let conv = converter, let mono, let src = multi.floatChannelData?[0],
              let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: multi.frameLength), let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = multi.frameLength
        dst.update(from: src, count: Int(multi.frameLength))
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard let p = out.floatChannelData?[0] else { return }
        onSamples?(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
    }
}

/// 邊講邊切：累積滿 5 秒後，遇到 0.5 秒停頓就切一段；25 秒都沒停頓就硬切。
struct Segmenter {
    static let rate = 16000, frame = 480   // 30 ms 一格
    var minLen = 5 * rate, maxLen = 25 * rate, gap = rate / 2
    private(set) var buf: [Float] = []
    private var levels: [Float] = []   // 最近 60 秒每格的音量，用來估背景音
    /// 有聲音的門檻 = 背景音 × 1.6，夾在 0.004～0.01。背景音 = 最安靜的那 1 成格子。
    /// 2026-11-02 實測：老闆的麥克風背景約 0.0034、講話約 0.006～0.017，原本固定 0.01 會把小聲的話當成沒人講。
    var threshold: Float {
        guard levels.count >= 30 else { return 0.006 }
        return min(0.01, max(0.004, levels.sorted()[levels.count / 10] * 1.6))
    }
    private var scanned = 0, silent = 0

    static func rms(_ s: ArraySlice<Float>) -> Float {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
    }

    mutating func push(_ s: [Float]) -> [Float]? {
        buf += s
        var cut: Int?
        let th = threshold
        while cut == nil, scanned + Self.frame <= buf.count {
            let level = Self.rms(buf[scanned..<scanned + Self.frame])
            levels.append(level)
            let loud = level >= th
            silent = loud ? 0 : silent + Self.frame
            scanned += Self.frame
            if scanned >= minLen && silent >= gap { cut = scanned - silent / 2 }
            else if scanned >= maxLen { cut = quietest() }
        }
        guard let c = cut else { return nil }
        let seg = Array(buf[..<c])
        buf.removeFirst(c); scanned -= c; silent = min(silent, scanned)
        if levels.count > 2000 { levels.removeFirst(levels.count - 2000) }
        return seg
    }

    /// 一直沒停頓要硬切時，在最後 3 秒裡找最安靜的 0.2 秒，從中間切，比較不會把一個字切成兩半
    private func quietest() -> Int {
        let n = 7, look = min(100, scanned / Self.frame, levels.count)   // 7 格 ≈ 0.2 秒，100 格 = 3 秒
        guard look >= n else { return scanned }
        let recent = Array(levels.suffix(look))
        let best = (0...(look - n)).min { recent[$0..<$0 + n].reduce(0, +) < recent[$1..<$1 + n].reduce(0, +) } ?? 0
        return scanned - (look - best - n / 2) * Self.frame
    }

    mutating func flush() -> [Float] {
        defer { buf = []; scanned = 0; silent = 0 }
        return buf
    }

    /// 至少 0.3 秒有聲音才送辨識，避免模型對著空白亂編字
    static func hasSpeech(_ s: [Float], threshold: Float = 0.006) -> Bool { loudSeconds(s, threshold: threshold) >= 0.3 }

    /// 這段裡音量超過門檻的總秒數
    static func loudSeconds(_ s: [Float], threshold: Float = 0.006) -> Double {
        var loud = 0, i = 0
        while i + frame <= s.count { if rms(s[i..<i + frame]) >= threshold { loud += frame }; i += frame }
        return Double(loud) / Double(rate)
    }

    static func samples(_ wav: Data) -> [Float]? {
        guard let r = wav.range(of: Data("data".utf8)) else { return nil }
        return wav[(r.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
    }

    static func wav(_ s: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        let pcm = s.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
