import Foundation

// 保全：資料來自 wifiwatch（~/.claude/scripts/wifiwatch.sh 採集、wifiwatch.py 分析）

public enum GuardLevel: String, Sendable, Codable, Comparable {
    case normal, notice, alert

    public var title: String {
        switch self {
        case .normal: "正常"
        case .notice: "注意"
        case .alert: "警示"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { self == .normal ? 0 : self == .notice ? 1 : 2 }
}

/// 要保全注意的一台裝置
public struct GuardDevice: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case new          // 紀錄裡有 NEW、名冊裡還沒命名
        case unnamed      // 名冊裡沒命名
        case unconfirmed  // 名字以 ★ 開頭（wifiwatch 標的「不在你清單上」，你還沒確認）
        case named        // 已命名（只出現在 onlineDevices 清單）
    }
    public var mac: String
    public var ip: String?
    public var vendor: String?
    public var label: String?
    public var kind: Kind
    public var online: Bool          // 最近一次掃描有看到
    public var firstSeen: Date?
    public var hostname: String?
    /// 只看到 IPv6、MAC 又是隨機的（本機管理位元）：多半是家裡手機／平板的隱私位址（10-20 審查：真實名冊裡 3 台都是這種，
    /// 原本會讓保全一直亮紅燈）。陌生人連上 Wi-Fi 會拿 DHCP 的 IPv4，所以這種只算「注意」不算「警示」
    public var privacyOnly: Bool { ip == nil && WifiWatch.isLocallyAdministered(mac) }
    public init(mac: String, ip: String? = nil, vendor: String? = nil, label: String? = nil, kind: Kind, online: Bool, firstSeen: Date? = nil) {
        self.mac = mac; self.ip = ip; self.vendor = vendor; self.label = label; self.kind = kind; self.online = online; self.firstSeen = firstSeen
    }
}

/// 保全看到的 Wi-Fi 狀態。不含「現在幾點」以外會一直變的東西，內容沒變就不重新發布。
public struct GuardStatus: Sendable, Equatable {
    public var hasData = false        // 名冊檔存在、讀得懂
    public var lastScan: Date?        // 上次掃描（名冊裡最新的 last_seen：每次掃描會把在線裝置都蓋成同一個時間）
    public var knownCount = 0         // 名冊裝置數
    public var onlineCount = 0        // 上次掃描在線的
    public var flagged: [GuardDevice] = []   // 未命名／新裝置／★未確認（在線的排前面）
    public var onlineDevices: [GuardDevice] = []   // 上次掃描在線的全部裝置（10-24 Kang：要看在線的是哪些）；依 IP 排
    public var stale = false          // 超過 24 小時沒掃描
    public var level: GuardLevel = .notice
    public var summary = ""           // 一句話（給櫃台螢幕）
    // push 守門（10-22，PushGuard）：最近 24 小時
    public var pushChecked = 0
    public var pushBlocked = 0
    public var pushRecent: [PushEvent] = []    // 新的在前，最多 5 筆
    public init() {}

    /// 把 push 守門的紀錄併進來：擋過金鑰 ⇒ 警示；擋過別的 ⇒ 至少注意
    public mutating func merge(pushes evs: [PushEvent]) {
        pushChecked = evs.count
        pushBlocked = evs.filter { $0.verdict == .block }.count
        pushRecent = Array(evs.prefix(5))
        if evs.contains(where: { $0.secret }) { level = .alert }
        else if pushBlocked > 0, level < .notice { level = .notice }
        if pushChecked > 0 {
            let p = "24 小時內檢查 \(pushChecked) 次 push" + (pushBlocked > 0 ? "，擋下 \(pushBlocked) 次" : "，都沒問題")
            summary = summary.isEmpty ? p : summary + "；" + p
        }
    }
}

public enum WifiWatch {
    /// 多久沒掃描算「很久沒掃描」
    public static let staleAfter: TimeInterval = 24 * 3600
    /// last_seen 跟上次掃描差多少以內算「那次在線」（同一次掃描寫的是同一個時間，留一點餘裕）
    public static let onlineSlack: TimeInterval = 120

    /// 解析名冊（JSON：MAC → {first_seen, label, vendor, last_seen, last_ip, hostname?}，時間是本機時間、沒有時區）
    /// 與紀錄（`YYYY-MM-DD HH:MM:SS  NEW  <ip 或 (僅 IPv6)>  <MAC>  <廠商>`；# 開頭是人工註記）。
    /// 紀錄裡 NEW、名冊卻已經沒有的 MAC 不算（被 --forget 掉的，例如 09-22 IPv6 測試假警報）。
    public static func parse(devices: Data?, log: Data?, now: Date, timeZone: TimeZone = .current) -> GuardStatus {
        var s = GuardStatus()
        guard let devices, let db = (try? JSONSerialization.jsonObject(with: devices)) as? [String: [String: Any]] else {
            s.level = .notice; s.summary = "還沒掃描過 Wi-Fi"
            return s
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        s.hasData = true
        s.knownCount = db.count
        let seen = db.mapValues { ($0["last_seen"] as? String).flatMap(f.date) }
        s.lastScan = seen.values.compactMap { $0 }.max()
        func online(_ mac: String) -> Bool {
            guard let t = seen[mac] ?? nil, let last = s.lastScan else { return false }
            return last.timeIntervalSince(t) <= onlineSlack
        }
        s.onlineCount = db.keys.filter(online).count

        // 紀錄的 NEW 行：MAC → 第一次被報的時間
        var newAt: [String: Date] = [:]
        let lf = DateFormatter()
        lf.locale = Locale(identifier: "en_US_POSIX"); lf.timeZone = timeZone; lf.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for raw in (log ?? Data()).split(separator: 0x0A) {
            let line = String(decoding: raw, as: UTF8.self)
            guard !line.hasPrefix("#"), line.count > 19, let t = lf.date(from: String(line.prefix(19))) else { continue }
            let rest = line.dropFirst(19).split(separator: " ", omittingEmptySubsequences: true)
            guard rest.first == "NEW", let mac = rest.first(where: { isMAC($0) }).map({ $0.lowercased() }) else { continue }
            if newAt[mac] == nil { newAt[mac] = t }
        }

        for (mac, r) in db {
            let label = (r["label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let kind: GuardDevice.Kind
            if label.isEmpty { kind = newAt[mac] != nil ? .new : .unnamed }
            else if label.hasPrefix("★") { kind = .unconfirmed }
            else { kind = .named }
            var d = GuardDevice(mac: mac, ip: r["last_ip"] as? String, vendor: r["vendor"] as? String,
                                label: label.isEmpty ? nil : label, kind: kind, online: online(mac),
                                firstSeen: (r["first_seen"] as? String).flatMap(f.date) ?? newAt[mac])
            d.hostname = r["hostname"] as? String
            if d.online { s.onlineDevices.append(d) }
            if kind != .named { s.flagged.append(d) }
        }
        // IP 依數字排（.9 在 .10 前）；只有 IPv6 的排最後
        func ipKey(_ d: GuardDevice) -> [Int] { d.ip.map { $0.split(separator: ".").compactMap { Int($0) } } ?? [999] }
        s.onlineDevices.sort { ipKey($0) == ipKey($1) ? $0.mac < $1.mac : ipKey($0).lexicographicallyPrecedes(ipKey($1)) }
        s.flagged.sort { ($0.online ? 0 : 1, $0.ip ?? "~", $0.mac) < ($1.online ? 0 : 1, $1.ip ?? "~", $1.mac) }

        s.stale = s.lastScan.map { now.timeIntervalSince($0) > staleAfter } ?? true
        // 警示：沒命名的裝置上次掃描還在線上（有陌生人連著你的 Wi-Fi）。注意：很久沒掃描、或有待確認的裝置。
        if s.flagged.contains(where: { $0.online && $0.kind != .unconfirmed && !$0.privacyOnly }) { s.level = .alert }
        else if s.stale || !s.flagged.isEmpty { s.level = .notice }
        else { s.level = .normal }

        var parts: [String] = []
        if s.lastScan == nil { parts.append("還沒掃描過 Wi-Fi") }
        else if s.stale { parts.append("很久沒掃描了") }
        parts.append("上次在線 \(s.onlineCount) 台／名冊 \(s.knownCount) 台")
        let strangers = s.flagged.filter { $0.kind != .unconfirmed }.count
        let pending = s.flagged.count - strangers
        let privacy = s.flagged.filter { $0.kind != .unconfirmed && $0.privacyOnly }.count
        if strangers > 0 { parts.append("\(strangers) 台沒命名" + (privacy > 0 ? "（\(privacy) 台只有 IPv6 隨機位址）" : "")) }
        if pending > 0 { parts.append("\(pending) 台待確認") }
        s.summary = parts.joined(separator: "，")
        return s
    }

    /// MAC 第一個位元組的「本機管理」位元（0x02）：手機 Wi-Fi 隱私位址、虛擬網卡都會設
    public static func isLocallyAdministered(_ mac: String) -> Bool {
        guard let b = UInt8(mac.prefix(2), radix: 16) else { return false }
        return b & 0x02 != 0
    }

    static func isMAC(_ s: Substring) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        return p.count == 6 && p.allSatisfy { (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }
    }
}

/// 「立即掃描」：背景跑 wifiwatch.sh（不帶參數＝掃一次），同一時間只跑一個；結束後名冊檔變了，FSEvents 會叫看板重讀。
/// runner 可注入（測試不准真的掃網路）。
public final class GuardScanner: @unchecked Sendable {
    public typealias Runner = @Sendable (_ script: String) -> Int32
    /// 定時巡邏的間隔
    public static let patrolInterval: TimeInterval = 30 * 60

    public let script: String
    private let runner: Runner
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = false
    private var lastStart: Date?

    public init(script: String, queue: DispatchQueue = DispatchQueue(label: "orbit.guard"), runner: @escaping Runner) {
        self.script = script; self.queue = queue; self.runner = runner
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var lastStarted: Date? { lock.lock(); defer { lock.unlock() }; return lastStart }

    /// 開始掃一次；已經在跑就不重複開（回傳 false）。done 在背景佇列上被叫，帶回結束碼。
    @discardableResult
    public func scan(now: Date = Date(), done: (@Sendable (Int32) -> Void)? = nil) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true; lastStart = now
        lock.unlock()
        let script = self.script, runner = self.runner
        queue.async { [weak self] in
            let code = runner(script)
            self?.lock.lock(); self?.running = false; self?.lock.unlock()
            done?(code)
        }
        return true
    }

    /// 巡邏到時間了沒：開著、沒在跑、上次掃描（名冊時間）和上次自己開始的時間都超過間隔。
    /// 用「上次自己開始」擋住：掃描失敗、名冊時間沒更新時不會每 15 秒重掃一次。
    public static func patrolDue(enabled: Bool, running: Bool, lastScan: Date?, lastStarted: Date?, now: Date,
                                 interval: TimeInterval = patrolInterval) -> Bool {
        guard enabled, !running else { return false }
        if let t = lastScan, now.timeIntervalSince(t) < interval { return false }
        if let t = lastStarted, now.timeIntervalSince(t) < interval { return false }
        return true
    }
}

/// 設定（UserDefaults suite ai.okle42.orbit42.engine；11-26 從舊 suite 一次性複製過來，鍵名不變）
public struct AppPrefs {
    public static let suite = "ai.okle42.orbit42.engine"      // 不能跟 App 的 bundle id 同名（同名 suite 在 App 裡會是 nil）
    public static let guardPatrolKey = "office.guardPatrol"   // Bool，預設關
    public let store: UserDefaults
    public init(store: UserDefaults? = nil) { self.store = store ?? UserDefaults(suiteName: Self.suite) ?? .standard }
    public var guardPatrol: Bool {
        get { store.object(forKey: Self.guardPatrolKey) as? Bool ?? false }
        nonmutating set { store.set(newValue, forKey: Self.guardPatrolKey) }
    }
}
