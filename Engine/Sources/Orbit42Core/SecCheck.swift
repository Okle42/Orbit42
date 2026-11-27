import Foundation
import CoreWLAN

// 本機資安體檢（11-28 Keng 定規格：~/.claude/SPEC-orbit42-本機資安體檢-20261128.md，第一階段 1～9 項）。
// 只看不改、只用 macOS 內建指令與 CoreWLAN：不掃別人的網路、不抓封包、不碰 USB 網卡。
// App 的小視窗（Sources/Orbit42/SecCheckWindow.swift）和 `orbit seccheck` 用同一套。

public enum SecLevel: String, Codable, Sendable {
    case ok, warn, bad, info, pending
    public var label: String {
        switch self { case .ok: "正常"; case .warn: "注意"; case .bad: "危險"; case .info: "列出"; case .pending: "檢查中" }
    }
}

public struct SecItem: Codable, Sendable, Equatable {
    public var no: Int
    public var title: String
    public var level: SecLevel
    public var detail: String
    /// 黃／紅燈：一句白話「為什麼危險、怎麼修」；第 9 項（只列出）也放提醒
    public var why: String?
    public init(no: Int, title: String, level: SecLevel, detail: String, why: String? = nil) {
        self.no = no; self.title = title; self.level = level; self.detail = detail; self.why = why
    }
}

public struct SecReport: Codable, Sendable {
    public var items: [SecItem]
    public var at: Date
    public var seconds: Double
    public func count(_ l: SecLevel) -> Int { items.filter { $0.level == l }.count }
    /// 第 7 項還在等使用者確認基準值
    public var needsNetworkConfirm: Bool { items.contains { $0.no == 7 && $0.level != .ok } }

    /// 卡片用：綠燈只寫數量；黃紅燈附一句白話
    public var cardSummary: String {
        var s = ["本機資安體檢：綠燈 \(count(.ok)) 項"]
        for i in items where i.level == .bad { s.append("🔴\(i.no). \(i.title)：\(i.why ?? i.detail)") }
        for i in items where i.level == .warn { s.append("🟡\(i.no). \(i.title)：\(i.why ?? i.detail)") }
        for i in items where i.level == .pending { s.append("⏳\(i.no). \(i.title)：背景檢查中") }
        for i in items where i.level == .info { s.append("ℹ️\(i.no). \(i.title)：\(i.detail)") }
        return s.joined(separator: "；")
    }
    public var worst: SecLevel { items.contains { $0.level == .bad } ? .bad : items.contains { $0.level == .warn } ? .warn : .ok }
}

public enum SecCheck {
    public static var dir: URL { Paths.supportDir.appendingPathComponent("seccheck", isDirectory: true) }

    // MARK: 跑全部（並行；第 4 項另外在背景，不算進 10 秒）
    public static func run() -> SecReport {
        let t0 = Date()
        let (net, partial) = Listeners.current()
        let checks: [@Sendable () -> SecItem] = [
            fileVault, firewall, integrity, updates, { wifi() }, savedWifi, networkSettings,
            { ports(net, partial: partial) }, { remote(net) }, startup, permissionsCheck,
        ]
        let box = Box(count: checks.count)
        DispatchQueue.concurrentPerform(iterations: checks.count) { i in box.set(i, checks[i]()) }
        return SecReport(items: box.items, at: t0, seconds: Date().timeIntervalSince(t0))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var a: [SecItem?]
        init(count: Int) { a = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ v: SecItem) { lock.withLock { a[i] = v } }
        var items: [SecItem] { lock.withLock { a.compactMap { $0 } } }
    }

    // MARK: 1. FileVault
    @Sendable static func fileVault() -> SecItem {
        let out = sh("/usr/bin/fdesetup", ["status"]).out
        return fileVaultItem(out)
    }
    static func fileVaultItem(_ out: String) -> SecItem {
        let t = "硬碟加密（FileVault）"
        if out.contains("FileVault is On") {
            return SecItem(no: 1, title: t, level: out.contains("in progress") ? .warn : .ok,
                           detail: out.contains("in progress") ? "加密進行中" : "已開",
                           why: out.contains("in progress") ? "還在加密，完成前資料還沒完全受保護；接著電源讓它跑完就好。" : nil)
        }
        if out.contains("FileVault is Off") {
            return SecItem(no: 1, title: t, level: .bad, detail: "沒開",
                           why: "硬碟沒加密，電腦被偷或送修時資料能直接被讀走。修：系統設定 → 隱私權與安全性 → FileVault → 開啟。")
        }
        return SecItem(no: 1, title: t, level: .warn, detail: "查不到：\(out.firstLine)", why: "讀不到加密狀態；到系統設定 → 隱私權與安全性 → FileVault 自己看一下。")
    }

    // MARK: 2. 防火牆、隱身模式
    @Sendable static func firewall() -> SecItem {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        return firewallItem(global: sh(fw, ["--getglobalstate"]).out, stealth: sh(fw, ["--getstealthmode"]).out)
    }
    static func firewallItem(global: String, stealth: String) -> SecItem {
        let t = "防火牆、隱身模式"
        let st = stealth.contains("is on") ? "隱身模式開" : "隱身模式關"
        if global.contains("enabled") { return SecItem(no: 2, title: t, level: .ok, detail: "防火牆開、\(st)") }
        if global.contains("disabled") {
            return SecItem(no: 2, title: t, level: .bad, detail: "防火牆關、\(st)",
                           why: "防火牆沒開，同一個網路的人可以直接連你電腦上開著的服務。修：系統設定 → 網路 → 防火牆 → 開啟。")
        }
        return SecItem(no: 2, title: t, level: .warn, detail: "查不到：\(global.firstLine)", why: "讀不到防火牆狀態；到系統設定 → 網路 → 防火牆自己看一下。")
    }

    // MARK: 3. SIP、Gatekeeper
    @Sendable static func integrity() -> SecItem {
        integrityItem(sip: sh("/usr/bin/csrutil", ["status"]).out, gk: sh("/usr/sbin/spctl", ["--status"]).out)
    }
    static func integrityItem(sip: String, gk: String) -> SecItem {
        let sipOn = sip.contains("status: enabled"), gkOn = gk.contains("assessments enabled")
        let d = "系統完整性保護\(sipOn ? "開" : "關")、Gatekeeper \(gkOn ? "開" : "關")"
        if sipOn && gkOn { return SecItem(no: 3, title: "系統完整性保護（SIP）、Gatekeeper", level: .ok, detail: d) }
        var why: [String] = []
        if !sipOn { why.append("SIP 被關，惡意程式能改系統檔；修：用復原模式開機，終端機打 csrutil enable") }
        if !gkOn { why.append("Gatekeeper 被關，來路不明的 App 打開不會被擋；修：終端機打 sudo spctl --master-enable") }
        return SecItem(no: 3, title: "系統完整性保護（SIP）、Gatekeeper", level: .bad, detail: d, why: why.joined(separator: "。") + "。")
    }

    // MARK: 4. 待裝更新（要連 Apple，常超過 10 秒 ⇒ 背景跑、結果快取 24 小時）
    static var updatesFile: URL { dir.appendingPathComponent("updates.txt") }
    static var updatesLock: URL { dir.appendingPathComponent("updates.running") }
    public static let updatesMaxAge: TimeInterval = 24 * 3600

    @Sendable public static func updates() -> SecItem {
        let t = "待裝的安全更新"
        if let age = age(updatesFile), age < updatesMaxAge, let out = try? String(contentsOf: updatesFile, encoding: .utf8) {
            var i = updatesItem(out); i.detail += "（\(ageText(age))前查的）"; return i
        }
        kickUpdates()
        return SecItem(no: 4, title: t, level: .pending, detail: "背景檢查中（要連 Apple 主機，約 30 秒～幾分鐘）；查完會快取 24 小時")
    }
    static func updatesItem(_ out: String) -> SecItem {
        let t = "待裝的安全更新"
        if out.contains("No new software available") { return SecItem(no: 4, title: t, level: .ok, detail: "沒有待裝的更新") }
        let titles = out.split(separator: "\n").compactMap { l -> String? in
            guard let r = l.range(of: "Title: ") else { return nil }
            return String(l[r.upperBound...].split(separator: ",").first ?? "")
        }
        if !titles.isEmpty {
            return SecItem(no: 4, title: t, level: .bad, detail: "有 \(titles.count) 個沒裝：\(titles.joined(separator: "、"))",
                           why: "系統更新沒裝，已經公開的漏洞還沒補上。修：系統設定 → 一般 → 軟體更新 → 立即更新。")
        }
        return SecItem(no: 4, title: t, level: .warn, detail: "查不到：\(out.firstLine)", why: "連不到 Apple 更新主機；網路正常後到系統設定 → 一般 → 軟體更新看一下。")
    }
    /// 背景跑 softwareupdate -l（已經在跑就不重複；跑完寫進快取）
    public static func kickUpdates(force: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !force, let age = age(updatesFile), age < updatesMaxAge { return }
        if let s = try? String(contentsOf: updatesLock, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0, (age(updatesLock) ?? 0) < 15 * 60 { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", "-c", #"/usr/sbin/softwareupdate -l > "$1.tmp" 2>&1; mv -f "$1.tmp" "$1"; rm -f "$2""#, "sh", updatesFile.path, updatesLock.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run(); try? "\(p.processIdentifier)".write(to: updatesLock, atomically: true, encoding: .utf8) } catch {}
    }
    /// 等背景更新檢查跑完（給 `orbit seccheck --wait`）
    public static func waitUpdates(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let age = age(updatesFile), age < updatesMaxAge { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // MARK: 5. 目前 Wi-Fi 加密方式（CoreWLAN）＋路由器位址提醒
    static func wifi() -> SecItem {
        let t = "目前 Wi-Fi 加密方式"
        let gw = gateway()
        let router = gw.map { "；路由器 \($0)（管理密碼、韌體要你自己進去看）" } ?? ""
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else {
            return SecItem(no: 5, title: t, level: .info, detail: "Wi-Fi 沒開" + router)
        }
        var item = wifiItem(rawSecurity: i.security().rawValue)
        item.detail += router
        return item
    }
    /// 依 CWSecurity 的數值判燈（0 沒加密、1 WEP、6 動態 WEP ⇒ 紅；2、3 舊 WPA ⇒ 黃；Int.max＝沒連線）
    public static func wifiItem(rawSecurity r: Int) -> SecItem {
        let t = "目前 Wi-Fi 加密方式"
        let name = securityName(r)
        switch r {
        case 0: return SecItem(no: 5, title: t, level: .bad, detail: "現在連的 Wi-Fi 沒加密",
                               why: "沒加密的 Wi-Fi，同一個網路的人看得到你傳的東西，也可能是別人架的同名假熱點。修：換到有密碼的網路或開手機熱點；非連不可就只用 HTTPS、開 Tailscale。")
        case 1, 6: return SecItem(no: 5, title: t, level: .bad, detail: "現在連的 Wi-Fi 是 \(name)",
                                  why: "WEP 幾分鐘就能被破解，等於沒加密。修：換網路；是自己的路由器就改成 WPA2 或 WPA3。")
        case 2, 3, 7, 8: return SecItem(no: 5, title: t, level: .warn, detail: "現在連的 Wi-Fi 是 \(name)",
                                        why: "舊版 WPA 已有公開的攻擊方式。修：是自己的路由器就改成 WPA2 或 WPA3；外面的網路就少傳敏感資料。")
        case Int.max: return SecItem(no: 5, title: t, level: .info, detail: "沒有連 Wi-Fi")
        default: return SecItem(no: 5, title: t, level: .ok, detail: "現在連的 Wi-Fi 是 \(name)")
        }
    }
    public static func securityName(_ r: Int) -> String {
        switch r {
        case 0: "沒加密"; case 1: "WEP"; case 2: "WPA 個人"; case 3: "WPA／WPA2 個人混合"; case 4: "WPA2 個人"; case 5: "WPA2／WPA3 個人"
        case 6: "動態 WEP"; case 7: "WPA 企業"; case 8: "WPA／WPA2 企業混合"; case 9: "WPA2 企業"; case 10: "企業"
        case 11: "WPA3 個人"; case 12: "WPA3 企業"; case 13: "WPA2／WPA3 過渡"; case 14: "OWE 加密開放"; case 15: "OWE 過渡"
        default: "未知"
        }
    }
    static func gateway() -> String? {
        let out = sh("/sbin/route", ["-n", "get", "default"]).out
        return out.split(separator: "\n").first { $0.contains("gateway:") }.map { $0.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 6. 存過的 Wi-Fi 有沒有沒加密的
    @Sendable static func savedWifi() -> SecItem {
        guard let cfg = CWWiFiClient.shared().interface()?.configuration() else {
            return SecItem(no: 6, title: "存過的 Wi-Fi", level: .info, detail: "讀不到已知網路清單（Wi-Fi 沒開）")
        }
        let ps = (cfg.networkProfiles.array as? [CWNetworkProfile] ?? []).map { ($0.ssid ?? "（沒名字）", $0.security.rawValue) }
        return savedWifiItem(ps)
    }
    public static func savedWifiItem(_ profiles: [(String, Int)]) -> SecItem {
        let t = "存過的 Wi-Fi"
        let open = profiles.filter { [0, 1, 6].contains($0.1) }.map(\.0)
        if open.isEmpty { return SecItem(no: 6, title: t, level: .ok, detail: "存了 \(profiles.count) 個，都有加密") }
        return SecItem(no: 6, title: t, level: .bad, detail: "存了 \(profiles.count) 個，\(open.count) 個沒加密或 WEP：\(open.prefix(8).joined(separator: "、"))\(open.count > 8 ? "⋯" : "")",
                       why: "Mac 會自動連存過的網路；有人在附近架同名假熱點就會連上去，流量可能被看光。修：系統設定 → Wi-Fi → 已知網路，把這幾個刪掉。")
    }

    // MARK: 7. DNS、代理設定（第一次存成基準、請使用者確認；之後跟基準不同才紅）
    public struct NetBaseline: Codable, Sendable { public var values: [String]; public var accepted: Bool; public var at: Date }
    static var baselineFile: URL { dir.appendingPathComponent("network-baseline.json") }

    /// 手動設的 DNS（每個網路服務）＋系統代理設定；DHCP 給的 DNS 換 Wi-Fi 就會變，不算
    static func networkSnapshot() -> [String] {
        var v: [String] = []
        for s in services() {
            let d = sh("/usr/sbin/networksetup", ["-getdnsservers", s]).out
            if !d.contains("aren't any") { v.append("DNS[\(s)]=" + d.split(separator: "\n").joined(separator: ",")) }
        }
        v += proxyValues(sh("/usr/sbin/scutil", ["--proxy"]).out)
        return v.sorted()
    }
    /// 啟用中的網路服務（Wi-Fi、Ethernet⋯；停用的前面有 *）
    static func services() -> [String] {
        sh("/usr/sbin/networksetup", ["-listallnetworkservices"]).out.split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }
    public static func proxyValues(_ out: String) -> [String] {
        var kv: [String: String] = [:]
        for l in out.split(separator: "\n") {
            let p = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        var v: [String] = []
        for k in ["HTTP", "HTTPS", "SOCKS", "FTP", "RTSP", "Gopher"] where kv[k + "Enable"] == "1" {
            v.append("代理[\(k)]=\(kv[k + "Proxy"] ?? "?"):\(kv[k + "Port"] ?? "?")")
        }
        if kv["ProxyAutoConfigEnable"] == "1" { v.append("代理[自動設定]=\(kv["ProxyAutoConfigURLString"] ?? "?")") }
        if kv["ProxyAutoDiscoveryEnable"] == "1" { v.append("代理[自動探索]=開") }
        return v
    }
    static func resolvers() -> [String] {
        var seen: [String] = []
        for l in sh("/usr/sbin/scutil", ["--dns"]).out.split(separator: "\n") where l.contains("nameserver[") {
            if let v = l.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !seen.contains(v) { seen.append(v) }
        }
        return seen
    }

    @Sendable static func networkSettings() -> SecItem {
        let now = networkSnapshot()
        let base = try? BoardJSON.decoder.decode(NetBaseline.self, from: Data(contentsOf: baselineFile))
        if base == nil { saveBaseline(NetBaseline(values: now, accepted: false, at: Date())) }
        let r = resolvers()
        var i = networkItem(now: now, base: base)
        if !r.isEmpty { i.detail += "；現在實際用的 DNS：\(r.prefix(5).joined(separator: "、"))" }
        return i
    }
    public static func networkItem(now: [String], base: NetBaseline?) -> SecItem {
        let t = "DNS、代理設定"
        let shown = now.isEmpty ? "沒有手動設 DNS、沒有代理" : now.joined(separator: "、")
        guard let base else {
            return SecItem(no: 7, title: t, level: .warn, detail: "第一次體檢，已把目前設定記成基準：\(shown)",
                           why: "請確認這是你自己設的；是的話按「DNS／代理是我設的」，之後被改才會亮紅燈。不認得的就到系統設定 → 網路 → 詳細資訊 → DNS／代理伺服器刪掉。")
        }
        if base.values != now {
            let added = now.filter { !base.values.contains($0) }, gone = base.values.filter { !now.contains($0) }
            let diff = (added.map { "多了 \($0)" } + gone.map { "少了 \($0)" }).joined(separator: "、")
            return SecItem(no: 7, title: t, level: .bad, detail: "跟基準不一樣：\(diff)",
                           why: "DNS 或代理被改，上網可能被導到假網站或被側錄。修：不是你改的就到系統設定 → 網路 → 詳細資訊 → DNS／代理伺服器改回來；是你改的就按「DNS／代理是我設的」更新基準。")
        }
        if !base.accepted {
            return SecItem(no: 7, title: t, level: .warn, detail: "基準還沒確認：\(shown)",
                           why: "請確認這是你自己設的；是的話按「DNS／代理是我設的」，之後被改才會亮紅燈。")
        }
        return SecItem(no: 7, title: t, level: .ok, detail: "跟基準一樣（\(shown)）")
    }
    /// 使用者按「DNS／代理是我設的」：把目前值存成已確認的基準
    public static func acceptNetworkBaseline() {
        saveBaseline(NetBaseline(values: networkSnapshot(), accepted: true, at: Date()))
    }
    static func saveBaseline(_ b: NetBaseline) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(b) { try? d.write(to: baselineFile, options: .atomic) }
    }

    // MARK: 8. 對外開著的連接埠
    public struct Listener: Sendable, Equatable { public var proc: String; public var addr: String; public var port: Int }
    public enum Listeners {
        /// netstat 看得到全部帳號的程式；有些執行環境（11-28 實測：從 Orbit42 跑）netstat 會整個空白 ⇒ 改用 lsof，只看得到自己帳號的程式（partial）
        public static func current() -> (list: [Listener], partial: Bool) {
            let n = parse(sh("/usr/sbin/netstat", ["-anv", "-p", "tcp"]).out)
            if !n.isEmpty { return (n, false) }
            return (parseLsof(sh("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"]).out), true)
        }
        /// lsof：COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME，NAME 像「*:7000 (LISTEN)」「127.0.0.1:8761 (LISTEN)」「[::1]:631 (LISTEN)」
        public static func parseLsof(_ out: String) -> [Listener] {
            var r: [Listener] = []
            for l in out.split(separator: "\n") where l.hasSuffix("(LISTEN)") {
                let f = l.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 10, let colon = f[f.count - 2].lastIndex(of: ":") else { continue }
                let name = f[f.count - 2]
                guard let port = Int(name[name.index(after: colon)...]) else { continue }
                var addr = String(name[..<colon]); if addr == "*" { addr = "*" }
                addr = addr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let x = Listener(proc: String(f[0]).replacingOccurrences(of: "\\x20", with: " "), addr: addr, port: port)
                if !r.contains(x) { r.append(x) }
            }
            return r
        }
        public static func parse(_ out: String) -> [Listener] {
            var r: [Listener] = []
            let re = try! NSRegularExpression(pattern: #":\d+\s+[0-9a-f]{5}\s"#)
            for l in out.split(separator: "\n") where l.contains("LISTEN") {
                let s = String(l), f = s.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count > 4, let dot = f[3].lastIndex(of: "."), let port = Int(f[3][f[3].index(after: dot)...]) else { continue }
                let addr = String(f[3][..<dot])
                var proc = "?"
                // 程式名稱在第 10 欄（shiwat）之後、「:pid」之前，名字裡可能有空白（Discord Helper (）
                if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let pr = Range(m.range, in: s) {
                    let name = s[..<pr.lowerBound].split(separator: " ", omittingEmptySubsequences: true).dropFirst(10).joined(separator: " ")
                    if !name.isEmpty { proc = name }
                }
                let x = Listener(proc: proc, addr: addr, port: port)
                if !r.contains(x) { r.append(x) }
            }
            return r
        }
        /// 對外：綁全部介面或區網位址；本機（127／::1）和 Tailscale（100.64/10、fd7a:115c:a1e0）不算
        public static func external(_ l: Listener) -> Bool {
            let a = l.addr
            if a.hasPrefix("127.") || a == "::1" || a.hasPrefix("fd7a:115c:a1e0") { return false }
            if a.hasPrefix("100."), let o = Int(a.split(separator: ".").dropFirst().first ?? ""), (64...127).contains(o) { return false }
            return true
        }
    }
    /// Apple 系統自己的（AirPlay 接收器、接力、Kerberos⋯）：列出但不算第三方
    static let appleProcs: Set<String> = ["rapportd", "ControlCenter", "kdc", "launchd", "sharingd", "mDNSResponder", "AirPlayXPCHelper", "screensharingd", "sshd"]

    static func ports(_ net: [Listener], partial: Bool) -> SecItem {
        let fwOff = sh("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).out.contains("disabled")
        var i = portsItem(net, firewallOff: fwOff)
        if partial { i.detail += "（這次只看得到你自己帳號的程式，系統服務另見第 9 項）" }
        if net.isEmpty && partial { i.level = .warn; i.detail = "讀不到連接埠清單"; i.why = "這次讀不到哪些程式開著連接埠；終端機跑 orbit seccheck 再看一次。" }
        return i
    }
    public static func portsItem(_ net: [Listener], firewallOff: Bool) -> SecItem {
        let t = "對外開著的連接埠"
        let ext = net.filter(Listeners.external)
        func group(_ ls: [Listener]) -> String {
            var order: [String] = [], ports: [String: [Int]] = [:]
            for l in ls {
                if ports[l.proc] == nil { order.append(l.proc); ports[l.proc] = [] }
                if ports[l.proc]?.contains(l.port) == false { ports[l.proc]?.append(l.port) }
            }
            return order.map { "\($0)（\((ports[$0] ?? []).sorted().map(String.init).joined(separator: ","))）" }.joined(separator: "、")
        }
        let third = ext.filter { !appleProcs.contains($0.proc) }, apple = ext.filter { appleProcs.contains($0.proc) }
        let local = net.count - ext.count
        if ext.isEmpty { return SecItem(no: 8, title: t, level: .ok, detail: "沒有對外開的；只給本機或 Tailscale 的 \(local) 個") }
        if firewallOff {
            return SecItem(no: 8, title: t, level: .bad, detail: "防火牆關著，對外開著：\(group(ext))",
                           why: "防火牆沒開，這些程式同一個網路的人都連得到。修：先把防火牆打開（系統設定 → 網路 → 防火牆），用不到的服務關掉。")
        }
        if !third.isEmpty {
            return SecItem(no: 8, title: t, level: .warn,
                           detail: "第三方程式對外開著：\(group(third))" + (apple.isEmpty ? "" : "；Apple 系統的：\(group(apple))") + "；只給本機或 Tailscale 的 \(local) 個",
                           why: "這些程式在所有網路上開著門，同一個 Wi-Fi 的人連得到（防火牆有開會先擋沒允許的）。修：用不到就關掉那個程式的伺服器／分享功能，或在防火牆選項裡設成「阻擋」。")
        }
        return SecItem(no: 8, title: t, level: .ok, detail: "只有 Apple 系統的：\(group(apple))；只給本機或 Tailscale 的 \(local) 個")
    }

    // MARK: 9. 遠端存取（只列出，使用者決定）
    static func remote(_ net: [Listener]) -> SecItem {
        let anydeskRun = sh("/usr/bin/pgrep", ["-x", "AnyDesk"]).status == 0
        let anydeskApp = FileManager.default.fileExists(atPath: "/Applications/AnyDesk.app")
        let tsRun = sh("/usr/bin/pgrep", ["-f", "io.tailscale.ipn|tailscaled"]).status == 0
        let tsApp = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        let ssh = sh("/bin/launchctl", ["print", "system/com.openssh.sshd"]).status == 0
        let screen = sh("/bin/launchctl", ["print", "system/com.apple.screensharing"]).status == 0
        return remoteItem(net, ssh: ssh, screen: screen, anydesk: anydeskRun ? "執行中" : anydeskApp ? "已安裝、沒在跑" : nil,
                          tailscale: tsRun ? "執行中" : tsApp ? "已安裝、沒在跑" : nil)
    }
    public static func remoteItem(_ net: [Listener], ssh: Bool = false, screen: Bool = false, anydesk: String?, tailscale: String?) -> SecItem {
        var on: [String] = []
        if ssh || net.contains(where: { $0.port == 22 }) { on.append("SSH 遠端登入") }
        if screen || net.contains(where: { $0.port == 5900 }) { on.append("螢幕共享") }
        if let anydesk { on.append("AnyDesk（\(anydesk)）") }
        if let tailscale { on.append("Tailscale（\(tailscale)）") }
        return SecItem(no: 9, title: "遠端存取", level: .info, detail: on.isEmpty ? "都沒開" : on.joined(separator: "、"),
                       why: on.isEmpty ? nil : "這些能讓人從遠端登入或看你的螢幕；確定都是你在用的就好。用不到的到系統設定 → 一般 → 共享關掉，或把 App 結束。")
    }

    // MARK: 工具
    struct Out { var out: String; var status: Int32 }
    /// 跑內建指令（最多 5 秒，逾時就砍掉）
    static func sh(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> Out {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Out(out: "", status: -1) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); timer.cancel()
        return Out(out: String(decoding: d, as: UTF8.self), status: p.terminationStatus)
    }
    static func age(_ u: URL) -> TimeInterval? { FileStat.lstat(u.path).map { Date().timeIntervalSince($0.date) } }
    static func ageText(_ s: TimeInterval) -> String { s < 3600 ? "\(max(1, Int(s / 60))) 分鐘" : "\(Int(s / 3600)) 小時" }
}

extension String {
    var firstLine: String { split(separator: "\n").first.map(String.init) ?? "（沒有輸出）" }
}

