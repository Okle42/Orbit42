import Foundation

/// 11-26 改名（第一階段 F）的相容層：舊名照收一段時間，正在跑的 AI 不中斷。
/// 這裡是 repo 裡唯一還寫著舊名的地方（加上遷移與轉接測試）；等 Keng 確認穩定（至少一次重開、沒人再用舊路徑）後另問才拿掉。
public enum Legacy {
    /// 舊資料夾（~/Library/Application Support/ShoWork42）：只給搬家、轉接、socket 連結用
    public static var supportDir: URL { TestEnv.home.appendingPathComponent("Library/Application Support/" + "ShoWork42", isDirectory: true) }
    /// 舊設定 suite
    public static let suite = "ai.okle42." + "showork"
    /// 舊 Peer from-name 字首（判斷語意不變：新舊都認）
    public static let fromNamePrefix = "AI工作戰情中心"
    /// 舊網頁 token 標頭（iPhone 重裝前還在送舊的）
    public static let tokenHeader = "X-" + "ShoWork" + "-Token"
    /// 舊環境變數字首
    public static let envPrefix = "SHO" + "WORK_"
    /// 舊指令檔名
    public static let cliName = "sho" + "work"
    /// 舊 LaunchAgent（Orbit42 已內建引擎；啟動時停掉、不再開回）
    public static let launchAgent = "ai.okle42." + "showork.agent"

    /// 舊名環境變數照讀：SHOWORK_X 有設、ORBIT_X 沒設 ⇒ 補上 ORBIT_X（程式只讀新名）。App 與 orbit 指令一開始就叫
    @discardableResult
    public static func adoptEnv() -> [String] {
        var done: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix(envPrefix) {
            let n = "ORBIT_" + k.dropFirst(envPrefix.count)
            if getenv(n) == nil { setenv(n, v, 0); done.append(n) }
        }
        return done
    }

    /// 舊 suite 的值一次性複製到新 suite（新的已有就不蓋）；複製完讀回比對，回傳複製的鍵。做過就記 migrated.fromLegacy
    @discardableResult
    public static func migrateDefaults(from old: UserDefaults? = UserDefaults(suiteName: Legacy.suite),
                                       to new: UserDefaults? = UserDefaults(suiteName: AppPrefs.suite), oldName: String = Legacy.suite) -> [String] {
        guard let new, new.object(forKey: "migrated.fromLegacy") == nil else { return [] }
        let src = old?.persistentDomain(forName: oldName) ?? [:]
        var copied: [String] = []
        for (k, v) in src where new.object(forKey: k) == nil { new.set(v, forKey: k); copied.append(k) }
        let ok = copied.allSatisfy { k in (new.object(forKey: k) as? NSObject)?.isEqual(src[k]) ?? false }
        if ok { new.set(Date(), forKey: "migrated.fromLegacy") }
        return copied.sorted()
    }

    /// 舊資料夾還在 ⇒ 舊 socket 位置改成符號連結指到新 socket（還在用舊路徑連的程式照樣連得到）。回傳有沒有做
    @discardableResult
    public static func linkSocket(_ new: URL, old: URL = Legacy.supportDir.appendingPathComponent("agent.sock")) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.deletingLastPathComponent().path) else { return false }
        if (try? fm.destinationOfSymbolicLink(atPath: old.path)) == new.path { return true }
        unlink(old.path)                                            // 舊 App 留下的 socket 檔（已經沒人在聽）
        return (try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: new.path)) != nil
    }

    /// 搬家（11-26）：舊資料夾的東西複製到新資料夾——新的已經有就不蓋（合併）。複製完逐檔比對大小與內容；
    /// 不搬：bin（新的 orbit 另外裝）、agent.sock／guard.sock（socket）、舊 App 包、舊紀錄檔。舊資料夾一律不刪
    public struct MigrateReport: Sendable { public var copied: [String] = []; public var skipped: [String] = []; public var mismatched: [String] = [] }
    public static let migrateSkip: Set<String> = ["bin", "agent.sock", "guard.sock", "ShoWork" + "Agent.app", "backup", ".DS_Store"]
    public static func migrate(from old: URL = Legacy.supportDir, to new: URL = Paths.supportDir, dryRun: Bool = false) -> MigrateReport {
        var r = MigrateReport()
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: old.path) else { return r }      // 給相對路徑（/var 與 /private/var 不用自己對）
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            let top = rel.split(separator: "/").first.map(String.init) ?? rel
            if migrateSkip.contains(top) || (rel as NSString).lastPathComponent == ".DS_Store" {
                if type == .typeDirectory { e.skipDescendants() }
                continue
            }
            let src = old.appendingPathComponent(rel), dst = new.appendingPathComponent(rel)
            if type == .typeDirectory {
                if !dryRun { try? fm.createDirectory(at: dst, withIntermediateDirectories: true) }
                continue
            }
            if type == .typeSocket { continue }
            if fm.fileExists(atPath: dst.path) || (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil { r.skipped.append(rel); continue }
            if dryRun { r.copied.append(rel); continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.copyItem(at: src, to: dst); r.copied.append(rel) } catch { r.mismatched.append(rel + "（複製失敗）") }
        }
        if !dryRun {
            for rel in r.copied where !same(old.appendingPathComponent(rel), new.appendingPathComponent(rel)) { r.mismatched.append(rel) }
        }
        return r
    }
    /// 兩個檔一樣嗎（符號連結比目標；一般檔比內容）
    public static func same(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        if let la = try? fm.destinationOfSymbolicLink(atPath: a.path) { return (try? fm.destinationOfSymbolicLink(atPath: b.path)) == la }
        guard let da = try? Data(contentsOf: a, options: .mappedIfSafe), let db = try? Data(contentsOf: b, options: .mappedIfSafe) else { return false }
        return da == db
    }

    /// from-name 是不是「Orbit42（使用者…）」或舊的「AI工作戰情中心（使用者…）」
    public static func isBoardUser(_ head: String) -> Bool {
        head.contains("from-name=\"Orbit42（使用者") || head.contains("from-name=\"\(fromNamePrefix)（使用者")
    }
}
