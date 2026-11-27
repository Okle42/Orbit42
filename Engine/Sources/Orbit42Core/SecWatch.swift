import Foundation

// 本機資安體檢第二階段（11-28 Keng：T1128034721）
//   第 10 項：開機自動啟動項目（LaunchAgents／LaunchDaemons）跟上次確認的比，有新增就紅燈
//   第 11 項：完全取用磁碟／螢幕錄影／輔助使用權限跟上次確認的比，有新增就紅燈（讀權限資料庫要「完全取用磁碟」，拿不到就只列 Orbit42 自己有的）
//   自動跑：每週一次＋換 Wi-Fi 時（App 端 SecSchedule），跟上次結果不同才通知
// 一樣只看不改；「這些是我裝的／我給的」只更新 Orbit42 自己的基準檔。

public extension SecCheck {
    // MARK: 第 10 項
    static var startupDirs: [String] {
        [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
    }
    /// 目前的開機項目：「資料夾簡稱/檔名」
    static func startupItems(dirs: [String] = startupDirs) -> [String] {
        var out: [String] = []
        for d in dirs {
            let tag = d.hasPrefix(NSHomeDirectory()) ? "使用者" : d.hasSuffix("Daemons") ? "系統常駐" : "所有使用者"
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".plist") {
                out.append("\(tag)/\(f.replacingOccurrences(of: ".plist", with: ""))")
            }
        }
        return out.sorted()
    }

    struct ListBaseline: Codable, Sendable { public var values: [String]; public var at: Date }
    static func loadList(_ name: String) -> ListBaseline? {
        try? BoardJSON.decoder.decode(ListBaseline.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }
    static func saveList(_ name: String, _ values: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(ListBaseline(values: values, at: Date())) { try? d.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }
    static let startupBaselineName = "startup-baseline.json"
    static let permBaselineName = "permissions-baseline.json"

    @Sendable static func startup() -> SecItem {
        let now = startupItems(), base = loadList(startupBaselineName)
        if base == nil { saveList(startupBaselineName, now) }
        return startupItem(now: now, base: base?.values)
    }
    static func startupItem(now: [String], base: [String]?) -> SecItem {
        let t = "開機自動啟動項目"
        let note = "（登入項目要管理員權限才讀得到，這裡只看 LaunchAgents／LaunchDaemons）"
        guard let base else { return SecItem(no: 10, title: t, level: .info, detail: "第一次體檢，記下目前 \(now.count) 個當基準\(note)") }
        let added = now.filter { !base.contains($0) }, gone = base.filter { !now.contains($0) }
        if !added.isEmpty {
            return SecItem(no: 10, title: t, level: .bad,
                           detail: "比上次多了 \(added.count) 個：\(added.prefix(8).joined(separator: "、"))" + (gone.isEmpty ? "" : "；少了 \(gone.count) 個"),
                           why: "多出來的開機項目每次開機都會自己跑，惡意程式常這樣常駐。是你剛裝的軟體就按「這些是我裝的」；不認得就先別動，跟 Keng 或 AI 確認後再刪。")
        }
        return SecItem(no: 10, title: t, level: .ok, detail: "跟上次一樣 \(now.count) 個" + (gone.isEmpty ? "" : "（少了 \(gone.count) 個：\(gone.prefix(5).joined(separator: "、"))）"))
    }
    static func acceptStartup() { saveList(startupBaselineName, startupItems()) }

    // MARK: 第 11 項
    static let permServices: [(String, String)] = [("kTCCServiceSystemPolicyAllFiles", "完全取用磁碟"), ("kTCCServiceScreenCapture", "螢幕錄影"), ("kTCCServiceAccessibility", "輔助使用")]
    /// 讀系統權限資料庫（要完全取用磁碟）；讀不到回 nil
    static func permissions() -> [String]? {
        let db = "/Library/Application Support/com.apple.TCC/TCC.db"
        let q = "select service, client from access where auth_value = 2 and service in (" + permServices.map { "'\($0.0)'" }.joined(separator: ",") + ")"
        let r = sh("/usr/bin/sqlite3", ["-readonly", "-separator", "|", db, q])
        guard r.status == 0 else { return nil }
        return parsePermissions(r.out)
    }
    static func parsePermissions(_ out: String) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: permServices)
        return out.split(separator: "\n").compactMap { l -> String? in
            let p = l.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2, let n = names[p[0]] else { return nil }
            return "\(n)：\(p[1])"
        }.sorted()
    }

    @Sendable static func permissionsCheck() -> SecItem {
        guard let now = permissions() else { return permissionsItem(now: nil, base: nil, own: ownPermissions()) }
        let base = loadList(permBaselineName)
        if base == nil { saveList(permBaselineName, now) }
        return permissionsItem(now: now, base: base?.values, own: [])
    }
    /// 讀不到資料庫時只能列 Orbit42 自己有的（App 端塞進來；終端機版不知道）
    nonisolated(unsafe) static var ownPermissions: @Sendable () -> [String] = { [] }

    static func permissionsItem(now: [String]?, base: [String]?, own: [String]) -> SecItem {
        let t = "App 敏感權限"
        guard let now else {
            return SecItem(no: 11, title: t, level: .info,
                           detail: "讀不到哪些 App 有完全取用磁碟、螢幕錄影、輔助使用權限（要給 Orbit42「完全取用磁碟」）" + (own.isEmpty ? "" : "；Orbit42 自己有：\(own.joined(separator: "、"))"),
                           why: "要比對哪些 App 新拿到權限，Orbit42 需要「完全取用磁碟」。要給的話到系統設定 → 隱私權與安全性 → 完全取用磁碟，打開 Orbit42。")
        }
        guard let base else { return SecItem(no: 11, title: t, level: .info, detail: "第一次體檢，記下目前 \(now.count) 個授權當基準") }
        let added = now.filter { !base.contains($0) }
        if !added.isEmpty {
            return SecItem(no: 11, title: t, level: .bad, detail: "比上次多了 \(added.count) 個：\(added.prefix(8).joined(separator: "、"))",
                           why: "這些權限能讀你所有檔案、錄你的螢幕、操控其他 App。是你剛給的就按「這些是我給的」；不認得就到系統設定 → 隱私權與安全性把它關掉。")
        }
        return SecItem(no: 11, title: t, level: .ok, detail: "跟上次一樣 \(now.count) 個授權")
    }
    static func acceptPermissions() { if let p = permissions() { saveList(permBaselineName, p) } }

    // MARK: 自動跑：跟上次不同才通知
    /// 結果的指紋：每項的燈號；第 10、11 項連內容一起（多一個開機項目就算不同）
    static func signature(_ r: SecReport) -> [String] {
        r.items.map { i in [10, 11].contains(i.no) && i.level == .bad ? "\(i.no)=\(i.level.rawValue):\(i.detail)" : "\(i.no)=\(i.level.rawValue)" }
    }
    /// 跟上次比：回傳變了哪幾項（白話）；檢查中的不算變化
    static func changes(old: [String]?, new r: SecReport) -> [String] {
        guard let old else { return [] }            // 第一次自動跑只記錄、不通知
        let sig = signature(r)
        let o = Dictionary(old.compactMap { s in s.split(separator: "=", maxSplits: 1).first.map { (String($0), s) } }, uniquingKeysWith: { a, _ in a })
        return r.items.compactMap { i in
            guard i.level != .pending, let s = sig.first(where: { $0.hasPrefix("\(i.no)=") }), o["\(i.no)"] != s,
                  o["\(i.no)"].map({ !$0.contains("=pending") }) ?? true else { return nil }
            return "\(i.no). \(i.title)：\(i.level.label)（\(i.detail)）"
        }
    }
    static var signatureFile: URL { dir.appendingPathComponent("last-auto.json") }
    struct AutoState: Codable, Sendable { public var signature: [String]; public var at: Date }
    static func lastAuto() -> AutoState? { try? BoardJSON.decoder.decode(AutoState.self, from: Data(contentsOf: signatureFile)) }
    static func saveAuto(_ r: SecReport) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(AutoState(signature: signature(r), at: Date())) { try? d.write(to: signatureFile, options: .atomic) }
    }
    static let weekly: TimeInterval = 7 * 24 * 3600
    /// 該不該自動跑：沒跑過、或超過一週
    static func weeklyDue(last: Date?, now: Date = Date()) -> Bool { last.map { now.timeIntervalSince($0) >= weekly } ?? true }
}
