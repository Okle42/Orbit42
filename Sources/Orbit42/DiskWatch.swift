import AppKit
import IOKit

/// 11-24 Keng「1T 硬碟為什麼會下線要找出來，斷線偵測要坐在 Orbit42 上」：
/// 盯外接硬碟（/Volumes 底下）。沒有先「退出」就消失＝實體斷線（線鬆、插孔接觸不良、供電不夠），
/// 接回來時量 USB 連線速度，掉到 USB 2.0（≤480Mb/s）也提醒。每件事寫進 ~/Library/Logs/Orbit42/disk-events.jsonl，
/// 並用球體播報（window.karaToast）講出來。
/// 11-23 23:55 實例：HDD1T（ACASIS）80 秒內斷 3 次，接回來從 10Gb/s 掉到 480Mb/s。
@MainActor
final class DiskWatch {
    static let shared = DiskWatch()
    /// 講給使用者聽的出口（OrbitWindow 接到球體播報）
    var say: (String) -> Void = { _ in }

    private struct Info { var name: String; var bsd: String; var speed: Int?; var product: String? }
    private var known: [String: Info] = [:]          // 掛載路徑 → 資訊
    private var lastSpeed: [String: Int] = DiskWatch.loadSpeeds()   // 硬碟名 → 上次量到的速度（判斷「變慢」；存檔，重開也記得）
    private var ejecting: Set<String> = []           // 收到 willUnmount 的路徑（使用者自己退出）
    private var drops: [String: [Date]] = [:]        // 硬碟名 → 斷線時間
    private var goneAt: [String: Date] = [:]
    private var started = false

    static let logURL = ProcessInfo.processInfo.environment["ORBIT_DISK_LOG"].map { URL(fileURLWithPath: $0) }   // 測試用另一份
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit42/disk-events.jsonl")

    func start() {
        guard !started else { return }; started = true
        for u in Self.externalVolumes() { if let i = Self.info(u) { known[u.path] = i } }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] n in
            let p = Self.path(n); MainActor.assumeIsolated { if let p { self?.ejecting.insert(p) } }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            let p = Self.path(n); MainActor.assumeIsolated { if let p { self?.unmounted(p) } }
        }
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            let p = Self.path(n)
            // 剛掛上時 USB 速度可能還沒穩，等 2 秒再量
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { if let p { self?.mounted(p) } } }
        }
        // 11-28 Keng：線本來就只有 USB 2.0，每次啟動都講是誤報 ⇒ 只有「比上次存的速度慢」才講（例如 10Gb/s 掉到 480Mb/s）
        for i in known.values {
            let before = lastSpeed[i.name]
            if Self.slower(i.speed, than: before) {
                note("slow", i, "外接硬碟 \(i.name) 變慢了：現在 \(Self.fmt(i.speed))（上次 \(Self.fmt(before))），線或插孔可能接觸不良", extra: ["before": before ?? 0])
            }
            if let s = i.speed, s > 0 { lastSpeed[i.name] = s }
        }
        Self.saveSpeeds(lastSpeed)
        log(["event": "start", "disks": known.values.map { ["name": $0.name, "bsd": $0.bsd, "speed": $0.speed ?? 0] }])
    }

    private func unmounted(_ path: String) {
        let expected = ejecting.remove(path) != nil
        guard let i = known.removeValue(forKey: path) else { return }
        if expected { log(["event": "eject", "name": i.name, "bsd": i.bsd]); return }
        let now = Date()
        var list = (drops[i.name] ?? []).filter { now.timeIntervalSince($0) < 600 }
        list.append(now); drops[i.name] = list; goneAt[i.name] = now
        let more = list.count > 1 ? "，10 分鐘內第 \(list.count) 次" : ""
        note("drop", i, "外接硬碟 \(i.name) 突然斷線（不是退出）\(more)。檢查線和插孔", extra: ["count10m": list.count])
    }

    private func mounted(_ path: String) {
        guard path.hasPrefix("/Volumes/"), let i = Self.info(URL(fileURLWithPath: path)) else { return }
        known[path] = i
        let before = lastSpeed[i.name]
        if let s = i.speed, s > 0 { lastSpeed[i.name] = s; Self.saveSpeeds(lastSpeed) }
        let off = goneAt.removeValue(forKey: i.name).map { Int(Date().timeIntervalSince($0).rounded()) }
        var msg = off.map { "外接硬碟 \(i.name) 接回來了（離線 \($0) 秒）" } ?? "外接硬碟 \(i.name) 已接上"
        if Self.slower(i.speed, than: before) {
            msg += "，但速度只有 \(Self.fmt(i.speed))" + (before.map { "（之前 \(Self.fmt($0))）" } ?? "") + "，線或插孔接觸不良"
            note("slow", i, msg, extra: ["before": before ?? 0, "offline": off ?? -1])
        } else if off != nil {
            note("back", i, msg, extra: ["offline": off ?? -1])
        } else {
            log(["event": "mount", "name": i.name, "bsd": i.bsd, "speed": i.speed ?? 0])
        }
    }

    private func note(_ event: String, _ i: Info, _ text: String, extra: [String: Any] = [:]) {
        var o: [String: Any] = ["event": event, "name": i.name, "bsd": i.bsd, "speed": i.speed ?? 0, "product": i.product ?? "", "text": text]
        o.merge(extra) { a, _ in a }
        log(o); say(text)
    }

    private func log(_ o: [String: Any]) {
        var o = o; o["time"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: Self.logURL) else { return }
        h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close()
    }

    // MARK: 讀硬碟資訊

    nonisolated private static func path(_ n: Notification) -> String? {
        (n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? n.userInfo?["NSDevicePath"] as? String
    }
    private static func externalVolumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
    }
    /// 要不要講「變慢」：量得到速度、有上次的紀錄、而且比上次慢。第一次看到、量不到、一樣慢都不講
    static func slower(_ now: Int?, than before: Int?) -> Bool {
        guard let now, now > 0, let before, before > 0 else { return false }
        return now < before
    }
    static let speedsURL = ProcessInfo.processInfo.environment["ORBIT_DISK_SPEEDS"].map { URL(fileURLWithPath: $0) }   // 測試用另一份
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit42/disk-speeds.json")
    static func loadSpeeds(_ url: URL = speedsURL) -> [String: Int] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: Int].self, from: d) else { return [:] }
        return m
    }
    static func saveSpeeds(_ m: [String: Int], _ url: URL = speedsURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }
    private static func slow(_ s: Int?) -> Bool { s.map { $0 > 0 && $0 <= 480_000_000 } ?? false }
    static func fmt(_ s: Int?) -> String {
        guard let s, s > 0 else { return "未知" }
        return s >= 1_000_000_000 ? "\(s / 1_000_000_000)Gb/s" : "\(s / 1_000_000)Mb/s"
    }
    /// 名字、BSD 名、USB 連線速度（從 IOMedia 往上找 IOUSBHostDevice 的 UsbLinkSpeed；不是 USB 的就是 nil）
    private static func info(_ u: URL) -> Info? {
        var st = statfs()
        guard statfs(u.path, &st) == 0 else { return nil }
        let from = withUnsafeBytes(of: st.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard from.hasPrefix("/dev/") else { return nil }                  // 網路磁碟、映像以外的才算
        let bsd = String(from.dropFirst(5))
        let name = (try? u.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? u.lastPathComponent
        let (speed, product) = usb(bsd)
        return Info(name: name, bsd: bsd, speed: speed, product: product)
    }
    static func usb(_ bsd: String) -> (Int?, String?) {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return (nil, nil) }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard media != 0 else { return (nil, nil) }
        defer { IOObjectRelease(media) }
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let speed = (IORegistryEntrySearchCFProperty(media, kIOServicePlane, "UsbLinkSpeed" as CFString, nil, opts) as? NSNumber)?.intValue
        let product = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "USB Product Name" as CFString, nil, opts) as? String
        return (speed, product)
    }
    /// 測試：ORBIT_TEST_DISKS=1 印出目前外接硬碟與速度
    static func dump() -> String {
        externalVolumes().compactMap(info).map { "\($0.name) \($0.bsd) \($0.product ?? "-") \(fmt($0.speed))\(slow($0.speed) ? " ⚠慢速" : "")" }.joined(separator: "\n")
    }
}
