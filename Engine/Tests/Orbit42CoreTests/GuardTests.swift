import Foundation
import Testing
@testable import Orbit42Core

// 保全（wifiwatch）、設定、cool42 狀態

@Suite("Guard")
struct GuardTests {
    let now = Date()
    let day: TimeInterval = 86400

    // MARK: 保全

    let tz = TimeZone(identifier: "Asia/Taipei")!
    func local(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)!
    }
    let devices = """
    {
      "02:00:00:00:10:01": {"first_seen": "2026-09-22T22:48:01", "label": "示範路由器", "vendor": "示範廠商A", "last_seen": "2026-09-23T12:04:16", "last_ip": "192.0.2.1"},
      "02:00:00:00:10:02": {"first_seen": "2026-09-22T22:48:01", "label": "示範掃地機", "vendor": "示範廠商B", "last_seen": "2026-09-22T23:19:02", "last_ip": "192.0.2.102"},
      "02:00:00:00:10:03": {"first_seen": "2026-09-22T22:48:01", "label": "★不在你清單上的裝置", "vendor": "示範廠商C", "last_seen": "2026-09-23T12:04:16", "last_ip": "192.0.2.202"},
      "02:00:00:00:10:04": {"first_seen": "2026-09-22T22:49:03", "label": "", "vendor": "示範廠商D", "last_seen": "2026-09-23T12:04:10", "last_ip": "192.0.2.101"},
      "aa:bb:cc:dd:ee:01": {"first_seen": "2026-09-22T22:48:01", "label": "", "vendor": "未知廠商", "last_seen": "2026-09-22T23:00:00", "last_ip": "192.0.2.150"}
    }
    """
    let log = """
    2026-09-22 22:48:01  BASELINE  建立名冊，收錄 13 台裝置
    2026-09-22 22:49:03  NEW  192.0.2.101  02:00:00:00:10:04  示範廠商D
    2026-09-22 22:58:33  NEW  (僅 IPv6)  02:00:00:00:10:99  （隨機 MAC・隱私位址）
    # 註記（人工補上）：上面那筆是測試用假警報，名冊已還原
    """

    @Test("wifiwatch：上次掃描＝最新 last_seen、在線＝跟它差 2 分鐘內；NEW＋沒命名＝新裝置；被 forget 的 NEW 不算")
    func guardParse() {
        let s = WifiWatch.parse(devices: Data(devices.utf8), log: Data(log.utf8), now: local("2026-09-23T13:00:00"), timeZone: tz)
        #expect(s.hasData && s.knownCount == 5)
        #expect(s.lastScan == local("2026-09-23T12:04:16"))
        #expect(s.onlineCount == 3)                                     // 路由器、Quectel、Epson（差 6 秒）
        #expect(!s.stale)
        #expect(s.flagged.map(\.mac) == ["02:00:00:00:10:04", "02:00:00:00:10:03", "aa:bb:cc:dd:ee:01"])   // 在線的在前
        #expect(s.flagged.map(\.kind) == [.new, .unconfirmed, .unnamed])
        #expect(s.flagged.map(\.online) == [true, true, false])
        #expect(!s.flagged.contains { $0.mac == "02:00:00:00:10:99" })
        #expect(s.level == .alert)                                      // 沒命名的 Epson 在線上
        #expect(s.summary.contains("上次在線 3 台／名冊 5 台"))
    }

    @Test("保全等級：都命名＋最近掃過＝正常；超過 24 小時＝注意；只有 ★ 待確認＝注意；沒有名冊＝注意")
    func guardLevels() {
        let ok = """
        {"a": {"label": "路由器", "last_seen": "2026-10-20T10:00:00"}, "b": {"label": "iPhone", "last_seen": "2026-10-20T09:00:00"}}
        """
        let fresh = WifiWatch.parse(devices: Data(ok.utf8), log: nil, now: local("2026-10-20T12:00:00"), timeZone: tz)
        #expect(fresh.level == .normal && fresh.onlineCount == 1 && fresh.flagged.isEmpty)
        let old = WifiWatch.parse(devices: Data(ok.utf8), log: nil, now: local("2026-10-21T10:00:01"), timeZone: tz)
        #expect(old.level == .notice && old.stale && old.summary.hasPrefix("很久沒掃描"))
        let star = """
        {"a": {"label": "★不在你清單上", "last_seen": "2026-10-20T10:00:00"}}
        """
        #expect(WifiWatch.parse(devices: Data(star.utf8), log: nil, now: local("2026-10-20T11:00:00"), timeZone: tz).level == .notice)
        let none = WifiWatch.parse(devices: nil, log: nil, now: now)
        #expect(!none.hasData && none.level == .notice && none.lastScan == nil)
        #expect(WifiWatch.parse(devices: Data("壞掉".utf8), log: nil, now: now).hasData == false)
        #expect(GuardLevel.normal < .notice && GuardLevel.notice < .alert)
    }

    @Test("保全：只有 IPv6 的隨機 MAC（手機隱私位址）在線只算注意；有 IPv4 的沒命名裝置在線才警示（10-20 審查）")
    func guardPrivacyMAC() {
        let v6 = """
        {"02:00:00:00:10:01": {"label": "路由器", "last_ip": "192.0.2.1", "last_seen": "2026-10-20T16:38:09"},
         "02:00:00:00:10:05": {"label": "", "vendor": "（隨機 MAC・隱私位址）", "last_ip": null, "last_seen": "2026-10-20T16:38:09"}}
        """
        let log6 = "2026-10-20 16:12:27  NEW  (僅 IPv6)  02:00:00:00:10:05  （隨機 MAC・隱私位址）"
        let s = WifiWatch.parse(devices: Data(v6.utf8), log: Data(log6.utf8), now: local("2026-10-20T17:00:00"), timeZone: tz)
        #expect(s.flagged.count == 1 && s.flagged[0].kind == .new && s.flagged[0].online && s.flagged[0].privacyOnly)
        #expect(s.level == .notice)
        #expect(s.summary.contains("1 台沒命名（1 台只有 IPv6 隨機位址）"))
        // 同一台如果拿到 IPv4 ⇒ 警示
        let v4 = v6.replacingOccurrences(of: "\"last_ip\": null", with: "\"last_ip\": \"192.0.2.77\"")
        #expect(WifiWatch.parse(devices: Data(v4.utf8), log: Data(log6.utf8), now: local("2026-10-20T17:00:00"), timeZone: tz).level == .alert)
        // 不是隨機 MAC（廠商 MAC）就算只有 IPv6 也警示
        let vendorMAC = v6.replacingOccurrences(of: "02:00:00:00:10:05", with: "00:00:5e:00:53:05")
        #expect(WifiWatch.parse(devices: Data(vendorMAC.utf8), log: nil, now: local("2026-10-20T17:00:00"), timeZone: tz).level == .alert)
        #expect(WifiWatch.isLocallyAdministered("02:00:00:00:10:06") && !WifiWatch.isLocallyAdministered("00:00:5e:00:53:01"))
    }

    @Test("立即掃描：背景跑、同時只跑一個、跑完可以再跑；測試用注入的 runner，不碰網路")
    func scannerSingleFlight() {
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        let sc = GuardScanner(script: "/假的/wifiwatch.sh") { script in
            calls.add(script); gate.wait(); return 0
        }
        let finished = DispatchSemaphore(value: 0)
        let started = sc.scan(now: now) { code in calls.add("code=\(code)"); finished.signal() }
        #expect(started)
        #expect(sc.isRunning)
        #expect(!sc.scan(now: now))                       // 第二次被擋
        #expect(sc.lastStarted == now)
        gate.signal()
        finished.wait()
        #expect(!sc.isRunning)
        let again = DispatchSemaphore(value: 0)
        let second = sc.scan { _ in again.signal() }
        #expect(second)
        gate.signal(); again.wait()
        #expect(calls.items.filter { $0 != "code=0" } == ["/假的/wifiwatch.sh", "/假的/wifiwatch.sh"])
        #expect(calls.items.contains("code=0"))
    }

    @Test("定時巡邏：關著不巡；名冊 30 分鐘內更新過、或 30 分鐘內自己開始過、或正在跑都不巡")
    func patrolDue() {
        let t = now
        #expect(!GuardScanner.patrolDue(enabled: false, running: false, lastScan: nil, lastStarted: nil, now: t))
        #expect(GuardScanner.patrolDue(enabled: true, running: false, lastScan: nil, lastStarted: nil, now: t))
        #expect(!GuardScanner.patrolDue(enabled: true, running: true, lastScan: nil, lastStarted: nil, now: t))
        #expect(!GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-29 * 60), lastStarted: nil, now: t))
        #expect(GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-31 * 60), lastStarted: nil, now: t))
        // 掃描失敗、名冊時間沒動：上次開始在 30 分鐘內就不重掃
        #expect(!GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-day), lastStarted: t.addingTimeInterval(-60), now: t))
    }

    @Test("設定：巡邏預設關；寫了讀得回來")
    func prefs() {
        let name = "prefs-\(UUID().uuidString)", ud = UserDefaults(suiteName: name)!
        defer { ud.removePersistentDomain(forName: name) }
        let p = AppPrefs(store: ud)
        #expect(!p.guardPatrol)
        p.guardPatrol = true
        #expect(AppPrefs(store: ud).guardPatrol && ud.bool(forKey: "office.guardPatrol"))
    }

    @Test("cool42：溫度、等級、過期、沒有檔")
    func cool42() {
        let at = ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z")!
        let j = Data(#"{"controlTemp":70.2,"cpuAvg":45,"level":"hot","time":"2026-11-25T10:00:00Z"}"#.utf8)
        let p = CoolParse.cool42(j, now: at)
        #expect(p.temp == 70.2 && p.level == "hot" && p.alert && !p.stale)
        #expect(CoolParse.cool42(j, now: at.addingTimeInterval(600)).stale)
        #expect(CoolParse.cool42(nil, now: at) == CoolState())
    }
}

/// 執行緒安全的小計數器（runner 在背景佇列被叫）
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

@Suite("Mood")
struct MoodTests {
    func card(_ col: BoardColumn, reason: String = "") -> BoardCard {
        BoardCard(id: "a", column: col, reason: reason, project: "P", title: "t", lastActivity: nil, pid: 1, sessionId: "a")
    }

    @Test("看板欄位對應狀態：進行中、等你回答、做完沒看、卡住、閒置、沒用過")
    func moods() {
        #expect(Mood.of(card(.active)) == .working)
        #expect(Mood.of(card(.review, reason: "等你回答")) == .waiting)
        #expect(Mood.of(card(.review, reason: "要你決定：要不要 push")) == .waiting)
        #expect(Mood.of(card(.review, reason: "做完了，你還沒看")) == .finished)
        #expect(Mood.of(card(.stuck)) == .stuck)
        #expect(Mood.of(card(.done)) == .idle)
        var fresh = card(.done); fresh.unused = true
        #expect(Mood.of(fresh) == .asleep)
    }
}

// 熱就停動畫（Heat.swift）：11-25 跟著 TowerTests 誤刪，原樣放回
@Suite("Heat")
struct HeatTests {
    @Test("cool42 warm 以上或系統 serious 以上算熱") func hot() {
        #expect(!HeatPolicy.hot(level: .ok, thermal: 1))
        #expect(HeatPolicy.hot(level: .warm, thermal: 0))
        #expect(HeatPolicy.hot(level: nil, thermal: 2))
        #expect(!HeatPolicy.hot(level: nil, thermal: 0))
    }
    @Test("退燒要穩定 60 秒才恢復") func debounce() {
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(HeatPolicy.paused(hotNow: true, wasPaused: false, coolSince: nil, now: t0))
        #expect(HeatPolicy.paused(hotNow: false, wasPaused: true, coolSince: t0, now: t0.addingTimeInterval(30)))
        #expect(!HeatPolicy.paused(hotNow: false, wasPaused: true, coolSince: t0, now: t0.addingTimeInterval(61)))
        #expect(!HeatPolicy.paused(hotNow: false, wasPaused: false, coolSince: nil, now: t0))
    }
    @Test("解析 cool42 state.json") func parse() {
        #expect(HeatPolicy.parseLevel(#"{"level":"hot","cpuAvg":70}"#.data(using: .utf8)) == .hot)
        #expect(HeatPolicy.parseLevel(Data("x".utf8)) == nil)
        #expect(HeatPolicy.parseLevel(nil) == nil)
    }
}
